// 只在用户点开某个项目的「历史」、或界面需要显示「上次活动」时，读取该项目的会话元数据。
// 只解析恢复列表所需的最小信息：标题、最后活动时间、消息数、文件路径。
// 不缓存聊天正文，不写日志。
//
// 性能基线（实测于本机 .pi 项目，104 个会话 / 317MB）：
//   旧的全文解析：40 个文件 1145 ms
//   现在：标题走「增量读到首条提问就停」约 20 ms；计数走 mmap + memchr 约 18 ms/10 文件；
//         时间读文件尾部 64KB 约 4 ms。
// 三个关键约束（都有实测依据，改代码时别破坏）：
//   1. 行缓冲必须 ≥256KB —— 首条提问行实测最大 41947 字节，8KB 会静默漏掉会话。
//   2. 不能用文件 mtime 当「最后活动时间」—— 实测最多偏晚 7 小时。
//   3. 不能用 contentsOfDirectory(at:) 的 URL 做路径比较 —— 它会把 /var 解析成 /private/var。
//
// 进程内缓存（有容量上限）只保存元数据与消息条数：
//   * 键 = 请求项目（只做词法标准化）+ 会话目录 + 文件名。会话目录编码可能碰撞
//     （`/a-b` 与 `/a/b` 编成同一个名字），所以不能只按目录缓存；也不按 realpath 合并项目。
//   * 失效 = 文件标识（装置号 + inode）、大小、mtime、ctime 任一变化；目录成员变化清空该目录；
//     读取过程中发现属性变化则不写缓存。
// `latest()` 与 `validated()` 只做选择／核验，不读消息条数。

import Foundation
import Dispatch

enum SessionHistory {
    struct Item {
        let path: String
        let title: String
        let modified: Date
        let messageCount: Int

        /// 传给界面的载荷（时间用毫秒，由界面负责本地化显示）
        var payload: [String: Any] {
            ["path": path,
             "title": title,
             "modified": modified.timeIntervalSince1970 * 1000,
             "messageCount": messageCount]
        }
    }

    /// 卡片摘要：会话文件数 + 最近活动时间
    typealias Summary = (count: Int, last: Date?)

    /// 历史页列出的条数上限
    static let maxItems = 10
    /// 单个 JSON 行的字节上限。首条提问行实测最大 41947，取 256KB 有 6 倍余量。
    private static let maxLineBytes = 256 * 1024
    /// 只在文件头部找标题，读到第 maxScanLines 行仍未找到就放弃（避免读取超大文件）。
    /// 开场前切换模型/思考等级（thinking_level_change / model_change / custom）会连续写多行，
    /// 实测首个 system/user 消息可落在第 18–19 行以后；同时扫描中只解析可能提供头信息、
    /// 会话名或首条消息的行，并在拿到标题后立刻收尾，128 行既有足够余量也不会多做解析。
    private static let maxScanLines = 128
    /// 读文件尾部找最后活动时间
    private static let tailBytes = 64 * 1024
    /// 深解析前的候选上限。mtime 只是近似的活动顺序：目录很大或 mtime 与真实活动错序时，
    /// 真正最新的会话可能落在前 40 个之外（批准计划已确认这一边界）。这里保持既有的
    /// 40 候选规则，不宣称不会漏掉。
    private static let maxCandidates = 40
    /// 「继续上次」的旧候选数常量。当前 latest 复用 list 的两阶段候选与排序，
    /// 不再单独按它截断，也不以 mtime 预选宣称能覆盖真实最新会话。
    private static let latestCandidates = 5

    static var defaultAgentDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
    }

    /// 会话目录名：与 PI 的 getDefaultSessionDirPath 一致（绝对路径去首个斜杠，`/ \ :` 换成 `-`）。
    /// 先按词法路径（PI 用的 path.resolve）找；若项目路径含符号链接，PI 也可能按物理路径编码，
    /// 因此把解析后的路径作为第二个候选，避免把「有历史」误判成「没有」。
    static func directory(for project: String, agentDir: URL = defaultAgentDir) -> URL {
        let candidates = directories(for: project, agentDir: agentDir)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    private static func directories(for project: String, agentDir: URL) -> [URL] {
        var forms: [String] = []
        for form in [standardize(project), resolvingSymlinks(standardize(project))] where !forms.contains(form) {
            forms.append(form)
        }
        return forms.map {
            agentDir.appendingPathComponent("sessions").appendingPathComponent(encode($0))
        }
    }

    private static func encode(_ path: String) -> String {
        "--" + path.dropFirst()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-") + "--"
    }

    /// 该项目的旧会话：最近活动的在前，最多 maxItems 条。目录不存在是正常情况（返回空）。
    static func list(project: String, agentDir: URL = defaultAgentDir) throws -> [Item] {
        try rankedItems(project: project, agentDir: agentDir, withCounts: true)
    }

    /// 列表与「继续上次」共用的选择流程。两阶段（先按 mtime 取候选、再按真实活动时间排序）
    /// 与候选上限保持原样；区别只是 metadata 与计数可命中缓存，且 `withCounts == false`
    /// 时完全不进入计数路径。
    private static func rankedItems(project: String, agentDir: URL, withCounts: Bool) throws -> [Item] {
        let projectKey = standardize(project)
        let dir = directory(for: project, agentDir: agentDir)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            invalidateDirectory(dir.path)
            return []
        }
        // 用文件名重建路径：contentsOfDirectory(at:) 会把 /var 解析成 /private/var，导致前缀比较失败
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        noteDirectoryListing()
        // 每轮只做一次属性快照；排序比较器只读快照里的时间，不再访问文件系统。
        let files = snapshotFiles(dir, names: names, followSymlinks: false)
        let candidates = files
            .sorted { $0.modified > $1.modified }
            .prefix(maxCandidates)
            .compactMap { inspect($0, project: project, projectKey: projectKey, directory: dir.path) }
            .sorted { $0.item.modified > $1.item.modified }
            .prefix(maxItems)
        guard withCounts else { return candidates.map(\.item) }
        return candidates.map { candidate in
            Item(path: candidate.item.path,
                 title: candidate.item.title,
                 modified: candidate.item.modified,
                 messageCount: messageCount(for: candidate, projectKey: projectKey, directory: dir.path))
        }
    }

    /// 轻量摘要：只回答「这个项目有多少旧会话、最近一次是什么时候」。
    /// 不解析标题正文，供项目卡片显示元信息用；单个项目通常 < 5 ms。
    ///
    /// `isCancelled` 让协调器能在文件边界停止已过期的扫描；被取消时返回 nil，
    /// 协调器会丢弃整轮结果，不把它当成「没有历史」。
    static func summary(project: String, agentDir: URL = defaultAgentDir,
                        isCancelled: () -> Bool = { false }) -> Summary? {
        let projectKey = standardize(project)
        let dir = directory(for: project, agentDir: agentDir)
        if isCancelled() { return nil }
        guard FileManager.default.fileExists(atPath: dir.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            invalidateDirectory(dir.path)
            return nil
        }
        noteDirectoryListing()
        let jsonl = names.filter { $0.hasSuffix(".jsonl") }
        guard !jsonl.isEmpty else {
            removeSummary(key: summaryKey(projectKey: projectKey, directory: dir.path))
            return nil
        }

        // 一轮属性快照。沿用原语义：统计目录里所有 .jsonl（包括内容不合格的），
        // 排序与初值用链接自身的 lstat mtime（不是目标 stat mtime，已由独立样本核对），
        // 真实活动时间再读尾部修正。
        var entries: [(path: String, modified: Date, identity: FileIdentity?)] = []
        entries.reserveCapacity(jsonl.count)
        for name in jsonl {
            if isCancelled() { return nil }
            let path = dir.appendingPathComponent(name).path
            let identity = snapshotIdentity(path, followSymlinks: false)
            entries.append((path: path, modified: identity?.modified ?? .distantPast, identity: identity))
        }
        let membershipValue = noteMembership(directory: dir.path, names: jsonl)
        entries.sort { $0.modified > $1.modified }
        let top = Array(entries.prefix(3))
        let key = summaryKey(projectKey: projectKey, directory: dir.path)
        let topIdentities = top.map { $0.identity }

        if let cached = cachedSummary(key: key, projectKey: projectKey,
                                      membership: membershipValue, top: topIdentities) {
            return cached
        }

        var last: Date? = entries.first?.modified
        for entry in top {
            if isCancelled() { return nil }
            guard let precise = lastActivity(URL(fileURLWithPath: entry.path)) else { continue }
            if let current = last, precise > current { last = precise }
        }
        if isCancelled() { return nil }
        let value: Summary = (jsonl.count, last)

        // 缓存边界：
        //   * 候选里有链接／非普通文件就不缓存——链接自身 lstat 不随目标变化，缓存会陈旧；
        //   * 读中属性有变化也不缓存；否则下一轮可能拿旧结果冒充稳定快照。
        let cacheable = entries.allSatisfy { $0.identity?.isRegularFile == true }
        if !isCancelled(), cacheable, topIdentities.allSatisfy({ $0 != nil }) {
            let stable = top.allSatisfy { entry in
                guard let identity = entry.identity else { return false }
                return stabilityIdentity(entry.path, followSymlinks: false) == identity
            }
            if stable {
                storeSummary(SummaryCacheEntry(directory: dir.path, projectKey: projectKey,
                                               membership: membershipValue,
                                               top: topIdentities, value: value), key: key)
            }
        }
        return value
    }

    /// 该项目最近活动的一条会话（用于「点卡片＝继续上次」）。
    ///
    /// 与 `list` 共用同一套候选与排序，选择结果必须一致；只取第一条所以不读消息条数
    /// （返回的 `messageCount` 固定为 0，调用方只用 `path`）。
    static func latest(project: String, agentDir: URL = defaultAgentDir) -> Item? {
        (try? rankedItems(project: project, agentDir: agentDir, withCounts: false))?.first
    }

    /// 界面回传的路径必须重新核验：不接受项目会话目录之外的任何文件。
    /// 核验只判断归属与可解析性，不触发消息计数。
    static func validated(_ path: String, project: String, agentDir: URL = defaultAgentDir) -> String? {
        let projectKey = standardize(project)
        let dir = directory(for: project, agentDir: agentDir)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == dir.path,
              url.pathExtension == "jsonl",
              let identity = snapshotIdentity(url.path, followSymlinks: false) else { return nil }
        let snapshot = FileSnapshot(name: url.lastPathComponent, path: url.path, identity: identity)
        return inspect(snapshot, project: project, projectKey: projectKey, directory: dir.path)?.item.path
    }

    /// 与 PI 的 path.resolve 一致：只做词法标准化，不解析符号链接
    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolvingSymlinks(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// 头部记录的 cwd 与本项目是否指向同一位置（兼容符号链接写法）
    private static func sameProject(_ stored: String, _ project: String) -> Bool {
        let a = standardize(stored)
        let b = standardize(project)
        return a == b || resolvingSymlinks(a) == resolvingSymlinks(b)
    }

    // ── 文件属性快照与缓存 ────────────────────────────

    /// 用一次 lstat/stat 得到失效所需的全部属性。ctime 不能省：同名文件被删掉重建时
    /// mtime 可能被复原成同一个值，只有 inode / ctime 能证明它换了一个文件。
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedNanos: Int64
        let changedNanos: Int64
        let mode: UInt16

        /// 与 FileManager 的 isRegularFile / isSymbolicLink 等价
        var isRegularFile: Bool { (mode & 0o170000) == 0o100000 }
        var isSymbolicLink: Bool { (mode & 0o170000) == 0o120000 }
        var modified: Date { Date(timeIntervalSince1970: Double(modifiedNanos) / 1_000_000_000) }
    }

    private struct FileSnapshot {
        let name: String
        let path: String
        let identity: FileIdentity

        var modified: Date { identity.modified }
    }

    private struct Candidate {
        let item: Item
        let name: String
        let identity: FileIdentity
    }

    private enum MetadataOutcome {
        /// storedCwd 保留头部原始 cwd；命中时用它重新核对当前 sameProject。
        case usable(title: String, headerTime: Date?, storedCwd: String)
        /// 头部本身有效，但当时与本项目不属于同一位置；链接重指向后可能改变结论。
        case projectMismatch(storedCwd: String)
        /// 文件结构不可用，与项目归属无关。
        case unusable
    }

    private struct CacheEntry {
        let directory: String
        let projectKey: String
        let identity: FileIdentity
        let outcome: MetadataOutcome
        let activity: Date?
        var count: Int?
    }

    private struct SummaryCacheEntry {
        let directory: String
        let projectKey: String
        let membership: Membership
        let top: [FileIdentity?]
        let value: Summary
    }

    /// 目录成员签名：数量 + 名字的次序无关哈希。只需判断「这一轮和上一轮是否同一批名字」。
    private struct Membership: Equatable {
        let count: Int
        let hash: UInt64
    }

    /// 采样／自检用的计数器。只统计真实发生的读取，不参与选择结果。
    struct Statistics {
        var directoryListings = 0
        var attributeReads = 0
        var stabilityAttributeReads = 0
        var headScans = 0
        var activityReads = 0
        var messageCountReads = 0
        var metadataHits = 0
        var metadataMisses = 0
        var countHits = 0
        var summaryHits = 0
        var cacheStores = 0
        var cachedEntries = 0
        var cachedDirectories = 0
        var cachedSummaries = 0
        var largestDirectoryEntryCount = 0
    }

    private static let cacheLock = NSLock()
    private static var counters = Statistics()
    /// key = 项目键 + 分隔符 + 目录 + 分隔符 + 文件名
    private static var entryCache: [String: CacheEntry] = [:]
    private static var entryOrder: [String] = []
    private static var summaryCache: [String: SummaryCacheEntry] = [:]
    private static var summaryOrder: [String] = []
    private static var directoryMembership: [String: Membership] = [:]
    private static var directoryOrder: [String] = []

    private static let maxCachedEntries = 256
    private static let maxCachedEntriesPerDirectory = 64
    private static let maxCachedDirectories = 64
    private static let maxCachedSummaries = 128

    /// 仅自检使用：在头部读取完成、最终属性核验之前调用，用来模拟「读取过程中文件被改动」。
    /// 产品代码从不设置；它只影响是否写缓存，不改变本次返回的结果。
    static var readMutationHook: (() -> Void)?

    private static func identity(_ path: String, followSymlinks: Bool) -> FileIdentity? {
        var info = stat()
        let status: Int32
        if followSymlinks {
            status = stat(path, &info)
        } else {
            status = lstat(path, &info)
        }
        guard status == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev),
                            inode: UInt64(info.st_ino),
                            size: Int64(info.st_size),
                            modifiedNanos: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                                + Int64(info.st_mtimespec.tv_nsec),
                            changedNanos: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000
                                + Int64(info.st_ctimespec.tv_nsec),
                            mode: UInt16(info.st_mode))
    }

    /// 一轮目录快照的属性读取
    private static func snapshotIdentity(_ path: String, followSymlinks: Bool) -> FileIdentity? {
        let value = identity(path, followSymlinks: followSymlinks)
        cacheLock.lock()
        counters.attributeReads += 1
        cacheLock.unlock()
        return value
    }

    /// 读取结束后复核同一文件是否仍是同一版本
    private static func stabilityIdentity(_ path: String, followSymlinks: Bool) -> FileIdentity? {
        let value = identity(path, followSymlinks: followSymlinks)
        cacheLock.lock()
        counters.stabilityAttributeReads += 1
        cacheLock.unlock()
        return value
    }

    private static func snapshotFiles(_ dir: URL, names: [String], followSymlinks: Bool) -> [FileSnapshot] {
        let jsonl = names.filter { $0.hasSuffix(".jsonl") }
        noteMembership(directory: dir.path, names: jsonl)
        var files: [FileSnapshot] = []
        files.reserveCapacity(jsonl.count)
        for name in jsonl {
            let path = dir.appendingPathComponent(name).path
            guard let identity = snapshotIdentity(path, followSymlinks: followSymlinks) else { continue }
            files.append(FileSnapshot(name: name, path: path, identity: identity))
        }
        return files
    }

    // 组件分隔符用 NUL：POSIX 路径和文件名都不能含 NUL，因此键不会因分隔符歧义相撞。
    private static func cacheKey(projectKey: String, directory: String, name: String) -> String {
        projectKey + "\u{0}" + directory + "\u{0}" + name
    }

    private static func summaryKey(projectKey: String, directory: String) -> String {
        projectKey + "\u{0}" + directory
    }

    private static func membership(of names: [String]) -> Membership {
        var hash: UInt64 = 0
        for name in names {
            var item: UInt64 = 0xcbf29ce484222325
            for byte in name.utf8 {
                item = (item ^ UInt64(byte)) &* 0x100000001b3
            }
            hash = hash &+ item &* 0x9e3779b97f4a7c15
        }
        return Membership(count: names.count, hash: hash)
    }

    @discardableResult
    private static func noteMembership(directory: String, names: [String]) -> Membership {
        let current = membership(of: names)
        cacheLock.lock()
        if let previous = directoryMembership[directory], previous != current {
            purge(directory: directory)
        }
        directoryMembership[directory] = current
        directoryOrder.removeAll { $0 == directory }
        directoryOrder.append(directory)
        while directoryOrder.count > maxCachedDirectories {
            let evicted = directoryOrder.removeFirst()
            directoryMembership[evicted] = nil
            purge(directory: evicted)
        }
        cacheLock.unlock()
        return current
    }

    /// 调用方必须持有 cacheLock
    private static func purge(directory: String) {
        entryCache = entryCache.filter { $0.value.directory != directory }
        entryOrder.removeAll { entryCache[$0] == nil }
        summaryCache = summaryCache.filter { $0.value.directory != directory }
        summaryOrder.removeAll { summaryCache[$0] == nil }
    }

    private static func invalidateDirectory(_ directory: String) {
        cacheLock.lock()
        directoryMembership[directory] = nil
        directoryOrder.removeAll { $0 == directory }
        purge(directory: directory)
        cacheLock.unlock()
    }

    private static func touchEntryLocked(_ key: String) {
        entryOrder.removeAll { $0 == key }
        entryOrder.append(key)
    }

    private static func cachedEntry(key: String, projectKey: String, identity: FileIdentity) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = entryCache[key],
              entry.identity == identity,
              entry.projectKey == projectKey else {
            counters.metadataMisses += 1
            return nil
        }
        counters.metadataHits += 1
        touchEntryLocked(key)
        return entry
    }

    private static func storeEntry(_ entry: CacheEntry, key: String) {
        cacheLock.lock()
        entryCache[key] = entry
        touchEntryLocked(key)
        var sameDirectory = entryOrder.filter { entryCache[$0]?.directory == entry.directory }
        while sameDirectory.count > maxCachedEntriesPerDirectory {
            let evicted = sameDirectory.removeFirst()
            entryCache[evicted] = nil
            entryOrder.removeAll { $0 == evicted }
        }
        while entryOrder.count > maxCachedEntries {
            let evicted = entryOrder.removeFirst()
            entryCache[evicted] = nil
        }
        counters.cacheStores += 1
        cacheLock.unlock()
    }

    private static func cachedCount(key: String, projectKey: String, identity: FileIdentity) -> Int? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = entryCache[key],
              entry.identity == identity,
              entry.projectKey == projectKey,
              let count = entry.count else { return nil }
        counters.countHits += 1
        touchEntryLocked(key)
        return count
    }

    private static func storeCount(_ count: Int, key: String, projectKey: String, identity: FileIdentity) {
        cacheLock.lock()
        if var entry = entryCache[key],
           entry.identity == identity,
           entry.projectKey == projectKey {
            entry.count = count
            entryCache[key] = entry
            counters.cacheStores += 1
        }
        cacheLock.unlock()
    }

    private static func cachedSummary(key: String, projectKey: String,
                                      membership: Membership, top: [FileIdentity?]) -> Summary? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = summaryCache[key],
              entry.projectKey == projectKey,
              entry.membership == membership,
              entry.top == top else { return nil }
        counters.summaryHits += 1
        summaryOrder.removeAll { $0 == key }
        summaryOrder.append(key)
        return entry.value
    }

    private static func storeSummary(_ entry: SummaryCacheEntry, key: String) {
        cacheLock.lock()
        summaryCache[key] = entry
        summaryOrder.removeAll { $0 == key }
        summaryOrder.append(key)
        while summaryOrder.count > maxCachedSummaries {
            let evicted = summaryOrder.removeFirst()
            summaryCache[evicted] = nil
        }
        counters.cacheStores += 1
        cacheLock.unlock()
    }

    private static func removeSummary(key: String) {
        cacheLock.lock()
        summaryCache[key] = nil
        summaryOrder.removeAll { $0 == key }
        cacheLock.unlock()
    }

    private static func noteDirectoryListing() {
        cacheLock.lock()
        counters.directoryListings += 1
        cacheLock.unlock()
    }

    /// 计数与尾部读取的调用次数也计入统计，供自检与采样工具核对「latest/validated 不计数」。
    private static func noteHeadScan() {
        cacheLock.lock()
        counters.headScans += 1
        cacheLock.unlock()
    }

    private static func noteActivityRead() {
        cacheLock.lock()
        counters.activityReads += 1
        cacheLock.unlock()
    }

    private static func noteMessageCountRead() {
        cacheLock.lock()
        counters.messageCountReads += 1
        cacheLock.unlock()
    }

    // ── 缓存维护 API（供主线程／协调器在项目移除后调用）────────────

    /// 移除某个项目的全部缓存条目（项目被删除、目录失效时调用）。
    static func invalidate(project: String, agentDir: URL = defaultAgentDir) {
        let projectKey = standardize(project)
        let dirs = directories(for: project, agentDir: agentDir).map { $0.path }
        cacheLock.lock()
        for directory in dirs {
            directoryMembership[directory] = nil
            directoryOrder.removeAll { $0 == directory }
            purge(directory: directory)
        }
        // 目录本身可能已经不在了，拿不到候选路径；再按项目键扫一遍兜底。
        entryCache = entryCache.filter { $0.value.projectKey != projectKey }
        entryOrder.removeAll { entryCache[$0] == nil }
        summaryCache = summaryCache.filter { $0.value.projectKey != projectKey }
        summaryOrder.removeAll { summaryCache[$0] == nil }
        cacheLock.unlock()
    }

    /// 清空全部缓存（自检与采样工具用来重放冷路径）。
    static func invalidateAll() {
        cacheLock.lock()
        entryCache.removeAll()
        entryOrder.removeAll()
        summaryCache.removeAll()
        summaryOrder.removeAll()
        directoryMembership.removeAll()
        directoryOrder.removeAll()
        cacheLock.unlock()
    }

    static func statistics() -> Statistics {
        cacheLock.lock()
        var value = counters
        value.cachedEntries = entryCache.count
        value.cachedDirectories = directoryMembership.count
        value.cachedSummaries = summaryCache.count
        var perDirectory: [String: Int] = [:]
        for entry in entryCache.values {
            perDirectory[entry.directory, default: 0] += 1
        }
        value.largestDirectoryEntryCount = perDirectory.values.max() ?? 0
        cacheLock.unlock()
        return value
    }

    /// 只清零计数器，不动缓存内容。
    static func resetStatistics() {
        cacheLock.lock()
        counters = Statistics()
        cacheLock.unlock()
    }

    // ── 单个会话的读取 ────────────────────────────────

    private static func makeItem(path: String, title: String, modified: Date) -> Item {
        Item(path: path,
             title: title.isEmpty ? "未命名会话" : title,
             modified: modified,
             messageCount: 0)
    }

    private static func inspect(_ snapshot: FileSnapshot, project: String,
                                projectKey: String, directory: String) -> Candidate? {
        let url = URL(fileURLWithPath: snapshot.path)
        guard url.pathExtension == "jsonl",
              url.deletingLastPathComponent().path == directory,
              snapshot.identity.isRegularFile,
              !snapshot.identity.isSymbolicLink else { return nil }

        let key = cacheKey(projectKey: projectKey, directory: directory, name: snapshot.name)
        // 缓存键包含项目键；命中时还要按当前文件系统重新核对头部 cwd 与项目归属。
        // 会话文件与词法目录都没变、但项目或头部 cwd 的符号链接重指向时，正/负缓存都会在这里失效。
        if let entry = cachedEntry(key: key, projectKey: projectKey, identity: snapshot.identity) {
            switch entry.outcome {
            case let .usable(title, headerTime, storedCwd):
                if sameProject(storedCwd, project) {
                    let modified = entry.activity ?? headerTime ?? snapshot.identity.modified
                    return Candidate(item: makeItem(path: snapshot.path, title: title, modified: modified),
                                     name: snapshot.name, identity: snapshot.identity)
                }
            case let .projectMismatch(storedCwd):
                if !sameProject(storedCwd, project) {
                    return nil
                }
            case .unusable:
                return nil
            }
        }

        let read = scanHead(url, project: project)
        let activity: Date?
        switch read {
        case .accepted(_):
            activity = lastActivity(url)
        case .projectMismatch(_), .unusable:
            activity = nil
        }
        readMutationHook?()
        let stable = stabilityIdentity(snapshot.path, followSymlinks: false) == snapshot.identity
        switch read {
        case let .accepted(scan):
            let modified = activity ?? scan.headerTime ?? snapshot.identity.modified
            if stable {
                storeEntry(CacheEntry(directory: directory, projectKey: projectKey,
                                      identity: snapshot.identity,
                                      outcome: .usable(title: scan.title,
                                                       headerTime: scan.headerTime,
                                                       storedCwd: scan.storedCwd),
                                      activity: activity, count: nil), key: key)
            }
            return Candidate(item: makeItem(path: snapshot.path, title: scan.title, modified: modified),
                             name: snapshot.name, identity: snapshot.identity)
        case let .projectMismatch(storedCwd):
            if stable {
                storeEntry(CacheEntry(directory: directory, projectKey: projectKey,
                                      identity: snapshot.identity,
                                      outcome: .projectMismatch(storedCwd: storedCwd),
                                      activity: nil, count: nil), key: key)
            }
            return nil
        case .unusable:
            if stable {
                storeEntry(CacheEntry(directory: directory, projectKey: projectKey,
                                      identity: snapshot.identity, outcome: .unusable,
                                      activity: nil, count: nil), key: key)
            }
            return nil
        }
    }

    /// 只给最终展示的条目计数。命中缓存时不再读文件。
    private static func messageCount(for candidate: Candidate, projectKey: String, directory: String) -> Int {
        let key = cacheKey(projectKey: projectKey, directory: directory, name: candidate.name)
        if let cached = cachedCount(key: key, projectKey: projectKey, identity: candidate.identity) {
            return cached
        }
        let before = stabilityIdentity(candidate.item.path, followSymlinks: false)
        let count = countMessages(URL(fileURLWithPath: candidate.item.path))
        let after = stabilityIdentity(candidate.item.path, followSymlinks: false)
        if before == candidate.identity, after == candidate.identity {
            storeCount(count, key: key, projectKey: projectKey, identity: candidate.identity)
        }
        return count
    }

    private struct HeadScan {
        let title: String
        let headerTime: Date?
        let storedCwd: String
    }

    /// 头部读取结果：必须把“项目不匹配”和“文件不可用”分开，
    /// 前者会随项目/头部 cwd 的符号链接重指向而改变，后者不会。
    private enum HeadRead {
        case accepted(HeadScan)
        case projectMismatch(storedCwd: String)
        case unusable
    }

    /// 只读文件头部，逐行解析，找到第一条用户提问就停。
    /// 不把整份会话读进内存；超过 maxLineBytes 的行整行丢弃。
    /// 第一个可解析的条目必须是属于本项目的 session 头，否则整份文件不可用。
    ///
    /// 实现用 memchr 在 mmap 里按行切，而不是 Swift 逐字节循环——
    /// 实测 40 个 400KB 文件：逐字节 129 ms，memchr 4 ms。
    private static func scanHead(_ url: URL, project: String) -> HeadRead {
        noteHeadScan()
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return .unusable }
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0,
              let base = mmap(nil, Int(size), PROT_READ, MAP_PRIVATE, fd, 0),
              base != MAP_FAILED else { return .unusable }
        defer { munmap(base, Int(size)) }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let total = Int(size)
        var seenHeader = false
        var sawMessage = false
        var headerTime: Date?
        var acceptedCwd: String?
        var mismatchCwd: String?
        var name = ""
        var firstQuestion = ""
        var lines = 0
        var pos = 0
        /// 找到首条用户提问后，最多再往后看几行（覆盖紧跟其后的 session_info），
        /// 不必为等待不存在的 session_info 把剩余头部额度全扫完。
        var linesAfterFirstQuestion = 0
        let tailSessionInfoLines = 4

        let typeKeyPrefix = Array(#"{"type":""#.utf8)
        let sessionInfoPrefix = Array(#"{"type":"session_info""#.utf8)
        let messagePrefix = Array(#"{"type":"message""#.utf8)

        func hasPrefix(_ line: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8]) -> Bool {
            guard line.count >= prefix.count, let baseAddress = line.baseAddress else { return false }
            return memcmp(baseAddress, prefix, prefix.count) == 0
        }

        /// 返回 false 表示整份文件不可用，立即停止
        func parse(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
            guard line.count > 1, line[0] == UInt8(ascii: "{") else { return true }
            // 已经确认过 session 头之后，像 model_change / thinking_level_change / custom
            // 这类不提供标题或消息的行，如果标准前缀明显不匹配就跳过 JSON 解析。
            // 注意：JSON 键序可能不以 "type" 打头（例如测试或第三方生成的行），
            // 仅对标准 PI 前缀 `{"type":"` 做快速白名单过滤，其余仍交 JSONSerialization。
            if seenHeader {
                if hasPrefix(line, typeKeyPrefix),
                   !hasPrefix(line, sessionInfoPrefix),
                   !hasPrefix(line, messagePrefix) {
                    return true
                }
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any],
                  let type = entry["type"] as? String else { return true }

            if !seenHeader {
                guard type == "session", entry["id"] is String,
                      let stored = entry["cwd"] as? String else {
                    return false
                }
                guard sameProject(stored, project) else {
                    mismatchCwd = stored
                    return false
                }
                seenHeader = true
                acceptedCwd = stored
                headerTime = timestamp(entry["timestamp"])
                return true
            }

            if type == "session_info" {
                name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return true
            }
            guard type == "message", let message = entry["message"] as? [String: Any] else { return true }
            sawMessage = true
            guard let role = message["role"] as? String, role == "user" else { return true }
            if firstQuestion.isEmpty {
                firstQuestion = text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return true
        }

        while pos < total, lines < maxScanLines {
            let end: Int
            if let newline = memchr(bytes + pos, Int32(UInt8(ascii: "\n")), total - pos) {
                end = Int(bitPattern: newline) - Int(bitPattern: base)
            } else {
                end = total          // 最后一行没有换行
            }
            let length = end - pos
            if length > 0 {
                lines += 1
                let hadQuestion = !firstQuestion.isEmpty
                // 超长行整行丢弃：不解析，也不当作坏文件
                if length <= maxLineBytes,
                   !parse(UnsafeBufferPointer(start: bytes + pos, count: length)) {
                    if let mismatchCwd = mismatchCwd {
                        return .projectMismatch(storedCwd: mismatchCwd)
                    }
                    return .unusable
                }
                // 会话名和首问都拿到就没必要再读下去
                if !name.isEmpty, !firstQuestion.isEmpty { break }
                // 首问已经拿到但一直没有 session_info：只多看几行即停，避免扫进后面大段工具结果
                if hadQuestion {
                    linesAfterFirstQuestion += 1
                    if linesAfterFirstQuestion >= tailSessionInfoLines { break }
                }
            }
            pos = end + 1
        }

        if let mismatchCwd = mismatchCwd {
            return .projectMismatch(storedCwd: mismatchCwd)
        }
        // 判据：必须有 session 头；会话名或首问至少要有一个，否则无法在列表里区分
        guard seenHeader, sawMessage || !name.isEmpty, let acceptedCwd = acceptedCwd else {
            return .unusable
        }
        let chosen = name.isEmpty ? firstQuestion : name
        let title = chosen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return .accepted(HeadScan(title: String(title.prefix(200)),
                                  headerTime: headerTime,
                                  storedCwd: acceptedCwd))
    }

    // ── 计数与最后活动时间 ────────────────────────────

    /// 消息条数：mmap + memchr 逐行首比对，不构造任何 JSON 对象。
    /// 实测比逐个 JSON 解析快 35 倍（10 个文件 634ms → 18ms），且不会漏掉超长行。
    private static func countMessages(_ url: URL) -> Int {
        noteMessageCountRead()
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0, let base = mmap(nil, Int(size), PROT_READ, MAP_PRIVATE, fd, 0),
              base != MAP_FAILED else { return 0 }
        defer { munmap(base, Int(size)) }

        let needle = Array(#"{"type":"message""#.utf8)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let newline = Int32(UInt8(ascii: "\n"))
        var count = 0
        var pos = 0
        while pos < Int(size) {
            let remaining = Int(size) - pos
            // 末尾不足 needle 长度时不能 memcmp：文件恰好是页大小整数倍时会读到未映射页。
            if remaining >= needle.count, memcmp(bytes + pos, needle, needle.count) == 0 {
                count += 1
            }
            guard let hit = memchr(bytes + pos, newline, remaining) else { break }
            pos = Int(bitPattern: hit) - Int(bitPattern: base) + 1
        }
        return count
    }

    /// 最后活动时间：读文件尾部 64KB，取最后一条 message 的 timestamp。
    /// 不能用 mtime —— 实测最多比真实活动时间晚 7 小时。
    private static func lastActivity(_ url: URL) -> Date? {
        noteActivityRead()
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? file.seek(toOffset: start)
        guard let data = try? file.readToEnd() else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.first == UInt8(ascii: "{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any] else { continue }
            if let ms = message["timestamp"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
            if let iso = timestamp(object["timestamp"]) { return iso }
        }
        return nil
    }

    /// PI 写入的时间戳是 ISO8601（可能带毫秒）
    private static func timestamp(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: " ")
    }
}

/// 摘要协调器：Foundation-only，不依赖 AppKit，可独立编译与测试。
///
/// 接入方式（供后续任务把 `main.swift` 的 `refreshMeta()` 接到这里）：
/// ```
/// let coordinator = SummaryCoordinator()          // 默认 ~/.pi/agent，由主线程持有
/// coordinator.request(projects: favorites + recents) { snapshot in
///     // 回调在协调器队列上；切回主线程后与自己的 generation 比较，再 push
/// }
/// coordinator.remove(project: path)               // 移除项目时清缓存
/// coordinator.cancelAll() / coordinator.shutdown() // 窗口关闭 / 应用退出
/// ```
/// `snapshot.generation` 由协调器自增，主线程只比较自己收到的最新一代；
/// 后台不需要也不应该读 UI 层的 `metaToken`。
///
/// 约定：
///   * 项目列表先做**词法**稳定去重（保留第一次出现的原项目键），不按 realpath 合并；
///   * 同一时间最多一轮活动扫描；运行中收到任何刷新请求（同集合、子集或新项目）都把
///     「运行中项目 + 待办 + 新请求」合并成下一轮，并让当前轮在文件／项目边界停下。
///     不采用「只替换回调」的快路径：已扫完的项目可能在扫描其它项目时发生变化，
///     必须安排一次有效重扫，否则新刷新会拿到旧结果；
///   * 同一代只保留最后一次请求的回调：被合并的请求由下一轮的统一回调交付；
///   * 移除的项目只在仍有旧工作可能扫描/回填/交付时保留标记：本轮收尾、cancelAll、
///     shutdown 与旧代际提前返回都会清理迟到缓存并回收标记；显式重新请求可恢复；
///   * 交付提交点：扫描结束后在锁内最终核对 stopped、本轮 token、runningGeneration 与
///     nextGeneration，全部未变才交付。提交前到达的 cancelAll/shutdown/新请求会丢弃本次
///     回调；提交后开始的操作不会撤回已开始的回调，只影响后续交付。回调在协调器队列上
///     执行；回调内可同步调用 request/remove/cancelAll/shutdown（它们不等待队列），但应
///     尽快返回，避免阻塞后续轮次；
///   * 协调器自己维护 generation，后台从不读取 UI 层的 token；过期结果不回调。
final class SummaryCoordinator {
    struct Snapshot {
        let generation: Int
        let summaries: [String: SessionHistory.Summary]
    }

    typealias Scanner = (String, () -> Bool) -> SessionHistory.Summary?
    typealias Completion = (Snapshot) -> Void

    private let queue: DispatchQueue
    private let agentDir: URL
    private let scan: Scanner
    private let lock = NSLock()

    private var pending: [String] = []
    private var runningProjects: [String] = []
    private var runningGeneration = 0
    private var isRunning = false
    private var nextGeneration = 0
    private var waiting: [Int: Completion] = [:]
    private var carry: Completion?
    private var token = CancellationToken()
    private var stopped = false
    /// 已派发但尚未收尾的 worker 数（串行队列上通常为 0 或 1）。
    /// 没有 worker 时 cancelAll/shutdown 立即清除移除记录；有 worker 时先清一次缓存，
    /// 记录留到 worker 收尾时再清一次，覆盖扫描/回填的迟到写入。
    private var workerInFlight = 0
    /// 已结束扫描、但回调尚未提交的一轮项目；用于覆盖“扫描结束到交付之间”的 remove。
    private var deliveryProjects: [String] = []
    /// 移除后仍可能有旧工作扫描/回填/交付的项目：词法项目键 → 原项目字符串。
    private var suppressed: [String: String] = [:]
    /// 移除发生时可能正在写缓存的项目；由本轮收尾统一清理。
    private var pendingInvalidations: [String: String] = [:]

    /// 仅自检使用：在最终交付提交检查之前调用，用来把门闩放在“扫描结束、交付未提交”之间。
    var testHookBeforeDelivery: (() -> Void)?
    /// 仅自检使用：本轮收尾（清理迟到缓存、回收移除记录）之后调用。
    var testHookAfterCleanup: (() -> Void)?

    /// 仅自检使用：当前仍保留的移除跟踪记录数。空闲 remove 不应累积。
    var retainedRemovalRecordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return suppressed.count + pendingInvalidations.count
    }

    /// `scan` 可注入，便于自检和采样工具统计真实扫描次数；
    /// 默认直接复用 `SessionHistory.summary`，并把取消标志传到文件边界。
    init(label: String = "local.pi.project-launcher.summary",
         agentDir: URL = SessionHistory.defaultAgentDir, scan: Scanner? = nil) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.agentDir = agentDir
        self.scan = scan ?? { (project: String, isCancelled: () -> Bool) -> SessionHistory.Summary? in
            SessionHistory.summary(project: project, agentDir: agentDir, isCancelled: isCancelled)
        }
    }

    /// 请求刷新这些项目。重复路径（同一词法路径）只扫一次，结果字典仍用原字符串做键。
    /// `completion` 在该轮全部扫描结束后、于协调器队列上调用；被更新请求合并时，
    /// 只有最后一次请求的 `completion` 会收到合并后的完整结果。
    func request(projects: [String], completion: @escaping Completion) {
        let incoming = SummaryCoordinator.dedupe(projects)
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        // 显式重新请求会解除移除抑制（项目被重新加回列表），旧移除记录不再需要。
        for project in incoming {
            let key = SummaryCoordinator.pathKey(project)
            suppressed[key] = nil
            pendingInvalidations[key] = nil
        }
        if isRunning {
            if incoming.isEmpty {
                // 没有目标：取消当前轮结果，让本轮在边界结束；收尾时安排一轮空扫描，
                // 由它交付空快照（同时仍会清掉移除项目的迟到缓存）。
                token.cancel()
                pending = []
                waiting.removeAll()
                carry = completion
                lock.unlock()
                return
            }
            // 任何非空请求都合并成下一轮：当前轮在边界停下，下一轮重扫并集。
            // 只替换回调会让「已扫完的项目后来发生变化」的新刷新丢失。
            pending = SummaryCoordinator.dedupe(runningProjects + pending + incoming)
            waiting[runningGeneration] = nil
            carry = completion
            token.cancel()
            lock.unlock()
            return
        }
        let jobs = SummaryCoordinator.dedupe(pending + incoming)
        pending = []
        nextGeneration += 1
        let generation = nextGeneration
        let roundToken = CancellationToken()
        runningProjects = jobs
        runningGeneration = generation
        isRunning = true
        token = roundToken
        waiting[generation] = completion
        workerInFlight += 1
        lock.unlock()
        start(generation: generation, jobs: jobs, token: roundToken)
    }

    /// 取消当前轮与待办（例如窗口关闭），协调器之后仍可继续接收请求。
    /// 有 worker 在跑时，移除记录留给它收尾（覆盖迟到写入）；没有 worker 时立即清理并回收。
    func cancelAll() {
        lock.lock()
        resetLocked()
        let invalidations = Array(pendingInvalidations.values)
        if workerInFlight == 0 {
            pendingInvalidations.removeAll()
            suppressed.removeAll()
        }
        lock.unlock()
        applyInvalidations(invalidations)
    }

    /// 永久停止：退出应用时调用。之后的新请求不会再启动扫描。
    /// 与 cancelAll 相同，迟到写入由仍在跑的 worker 收尾；没有 worker 时立即清理。
    func shutdown() {
        lock.lock()
        stopped = true
        resetLocked()
        let invalidations = Array(pendingInvalidations.values)
        if workerInFlight == 0 {
            pendingInvalidations.removeAll()
            suppressed.removeAll()
        }
        lock.unlock()
        applyInvalidations(invalidations)
    }

    /// 项目被移除时：立即清缓存、从待办摘掉。
    /// 只有仍有旧工作可能扫描/回填/交付它时才保留移除标记（运行中的项目、下一轮待办、
    /// 已扫描完但回调尚未提交的一轮）；标记在本轮收尾时回收。
    func remove(project: String) {
        let key = SummaryCoordinator.pathKey(project)
        lock.lock()
        let live = Set(runningProjects.map { SummaryCoordinator.pathKey($0) })
            .union(pending.map { SummaryCoordinator.pathKey($0) })
            .union(deliveryProjects.map { SummaryCoordinator.pathKey($0) })
        // workerInFlight > 0 时 runningProjects 可能已被 cancelAll 清空，无法从状态判断
        // 它手里是否正在扫这个项目；保守保留到本轮收尾，收尾后再回收。
        if live.contains(key) || workerInFlight > 0 {
            suppressed[key] = project
            pendingInvalidations[key] = project
            pending.removeAll { SummaryCoordinator.pathKey($0) == key }
        } else {
            // 没有活动 worker：没有旧工作可回填，立即清缓存即可，不保留历史记录。
            suppressed[key] = nil
            pendingInvalidations[key] = nil
        }
        lock.unlock()
        SessionHistory.invalidate(project: project, agentDir: agentDir)
    }

    // ── 内部 ──────────────────────────────────────────

    private func resetLocked() {
        pending = []
        runningProjects = []
        deliveryProjects = []
        waiting.removeAll()
        carry = nil
        token.cancel()
        isRunning = false
    }

    private func start(generation: Int, jobs: [String], token: CancellationToken) {
        queue.async { [weak self] in
            self?.run(generation: generation, jobs: jobs, token: token)
        }
    }

    private func run(generation: Int, jobs: [String], token: CancellationToken) {
        var summaries: [String: SessionHistory.Summary] = [:]
        for project in jobs {
            if token.isCancelled { break }
            lock.lock()
            let skip = suppressed[SummaryCoordinator.pathKey(project)] != nil
            lock.unlock()
            if skip { continue }
            if let value = scan(project, { token.isCancelled }) {
                summaries[project] = value
            }
        }
        finalizeRound(generation: generation, jobs: jobs, token: token, summaries: summaries)
    }

    /// 每轮唯一的收尾点：正常完成、取消、停止、旧代际提前返回都走这里。
    /// 顺序固定为：清理迟到缓存 → 回收移除记录 → 交付提交（仅正常轮）→ 启动下一轮。
    private func finalizeRound(generation: Int, jobs: [String],
                               token: CancellationToken,
                               summaries roundSummaries: [String: SessionHistory.Summary]) {
        var summaries = roundSummaries
        lock.lock()
        if workerInFlight > 0 { workerInFlight -= 1 }
        let invalidations = Array(pendingInvalidations.values)
        pendingInvalidations.removeAll()
        guard isRunning, runningGeneration == generation else {
            // 旧代际/已取消：不交付、不启动下一轮，但仍要清迟到缓存并回收记录。
            reclaimLocked()
            lock.unlock()
            applyInvalidations(invalidations)
            testHookAfterCleanup?()
            return
        }
        let wasCancelled = token.isCancelled
        isRunning = false
        runningProjects = []
        // 移除边界：被抑制项目的结果不交付。
        if !suppressed.isEmpty {
            summaries = summaries.filter { suppressed[SummaryCoordinator.pathKey($0.key)] == nil }
        }
        var completion: Completion?
        var nextRound: (generation: Int, jobs: [String], token: CancellationToken)?
        if !wasCancelled {
            completion = waiting[generation]
            waiting[generation] = nil
        }
        // 回调尚未提交的一轮继续参与 remove 的“仍有旧工作”判断。
        deliveryProjects = completion == nil ? [] : jobs
        if !pending.isEmpty || carry != nil {
            nextGeneration += 1
            let next = nextGeneration
            let roundToken = CancellationToken()
            let round = pending
            pending = []
            runningGeneration = next
            runningProjects = round
            isRunning = true
            self.token = roundToken
            waiting[next] = carry
            carry = nil
            nextRound = (next, round, roundToken)
            workerInFlight += 1
        }
        reclaimLocked()
        lock.unlock()

        // 先清掉迟到的缓存写入，再交付结果；下一轮在清理之后启动。
        applyInvalidations(invalidations)

        if let completion = completion {
            testHookBeforeDelivery?()
            var delivered: [String: SessionHistory.Summary] = [:]
            var committed = false
            lock.lock()
            // 最终交付提交点：提交前取消、停止或代际推进都会丢弃本次回调；
            // 通过后即视为已提交，之后开始的操作不会撤回已开始的回调。
            if !stopped, !token.isCancelled,
               runningGeneration == generation, nextGeneration == generation {
                delivered = summaries
                if !suppressed.isEmpty {
                    delivered = delivered.filter {
                        suppressed[SummaryCoordinator.pathKey($0.key)] == nil
                    }
                }
                committed = true
            }
            lock.unlock()
            if committed {
                completion(Snapshot(generation: generation, summaries: delivered))
            }
            // 交付/丢弃之后回收本轮交付记录，以及门闩期间新增的移除记录。
            var lateInvalidations: [String] = []
            lock.lock()
            deliveryProjects = []
            lateInvalidations = Array(pendingInvalidations.values)
            pendingInvalidations.removeAll()
            reclaimLocked()
            lock.unlock()
            applyInvalidations(lateInvalidations)
        }
        if let nextRound = nextRound {
            start(generation: nextRound.generation, jobs: nextRound.jobs, token: nextRound.token)
        }
        testHookAfterCleanup?()
    }

    /// 只保留仍被活动轮次/待办/未提交交付引用的移除标记。
    private func reclaimLocked() {
        let live = Set(runningProjects.map { SummaryCoordinator.pathKey($0) })
            .union(pending.map { SummaryCoordinator.pathKey($0) })
            .union(deliveryProjects.map { SummaryCoordinator.pathKey($0) })
        suppressed = suppressed.filter { live.contains($0.key) }
    }

    private func applyInvalidations(_ projects: [String]) {
        for project in projects {
            SessionHistory.invalidate(project: project, agentDir: agentDir)
        }
    }

    /// 词法稳定去重：保留第一次出现的原项目键；不解析符号链接，避免把不同项目合并。
    static func dedupe(_ projects: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for project in projects {
            let key = pathKey(project)
            if seen.insert(key).inserted {
                result.append(project)
            }
        }
        return result
    }

    /// 只做词法标准化并去掉尾部斜杠（根目录除外）；不解析符号链接。
    private static func pathKey(_ path: String) -> String {
        var key = URL(fileURLWithPath: path).standardizedFileURL.path
        while key.count > 1, key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }
}

/// 线程安全的取消标志：后台只在边界读，回调与主线程不共享 UI 状态。
private final class CancellationToken {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
