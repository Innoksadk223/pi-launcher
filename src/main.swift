// PI 项目启动器 — 原生外壳
// 界面用 WebKit 渲染（ui/），这里负责：窗口、读写项目列表、选文件夹、
// 在 Ghostty 中启动 PI。
//
// v3.1：窗口在，App 在；关窗口就退出。没有菜单栏图标和全局快捷键。

import Cocoa
import WebKit

// ══════════════════════════════════════════════════════
// 界面 ↔ 原生 桥接
// ══════════════════════════════════════════════════════

/// 底栏状态的相：start 常驻等下一相覆盖，done 几秒后自己消失，error 留到下一次操作。
/// 界面拿到 statusPhase 决定收尾；没拿到时按 statusTone 推断（error → error，其余 → done）。
enum StatusPhase: String {
    case start, done, error
}

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var onQuit: (() -> Void)?
    /// 界面当前的主题，用来同步窗口底色（见 windowBaseDay / windowBaseNight）
    var onTheme: ((Bool) -> Void)?
    /// 当前终端标签变化后申请一次标题栏让位测量（初始与缩放由窗口侧负责）
    var onPush: (() -> Void)?

    private var favorites: [String] = []
    private var recents: [String] = []
    /// 每个项目的会话摘要，异步算好后随 push 一起发；算不出来的项目不出现在这里
    private var meta: [String: (count: Int, last: Date?)] = [:]
    /// 本机检测到的终端（已安装的，含未适配的），随 push 发给标题栏菜单
    private var terminals: [Terminal.Kind] = []
    /// 这次要往哪个终端里开
    private var selectedTerminal: Terminal.Kind?

    /// 摘要协调器：只刷新请求的项目，过期轮次由它取消。
    private let summaryCoordinator = SummaryCoordinator()
    private var metaGeneration = 0
    private var metaReady = false
    /// 首屏三路准备：后台项目、主线程终端、页面加载完成。
    private var storeLoaded = false
    private var terminalsLoaded = false
    private var pageReady = false
    private var bootstrapped = false
    private let pendingActions = ProcessProbe.ActionQueue()
    private var fallbackNotice: String?
    /// 纯数据与状态事件分开指纹：无状态的数据刷新不能借旧状态重复发送。
    private var lastDataFingerprint: String?
    private var lastStatusFingerprint: String?
    private var lastPushedTerminalID: String?
    private struct LastStatus {
        let text: String
        let tone: String?
        let phase: StatusPhase?
        let scope: StatusScope
        let project: String?
        let mode: String?
        let requestId: String?
        /// "panel" 表示这是原生选目录后补发的、界面事先不知道的新请求。
        let origin: String?
    }
    private var lastStatus: LastStatus?

    /// 请求建立时固定在 requestId 里的页面代际与递增序号，不是投递时间。
    private struct LaunchIdentity: Equatable {
        let pageID: String
        let seq: Int
    }
    private struct ActiveLaunch {
        let project: String
        let mode: String
        let displayRequestId: String
    }
    /// 当前页面代际；页面 ready 时更新。旧页面的投递由 JS 按 pageID 丢弃。
    private var currentPageID: String?
    private var pendingSnapshot = false
    /// 只保留当前可显示的活跃请求，用于页面重载时的一次快照导入。
    private var activeLaunches: [String: ActiveLaunch] = [:]
    /// 每个当前项目最近一次可显示的意图；只用于旧 panel 的展示新旧判断。
    private var latestIntentByPath: [String: LaunchIdentity] = [:]
    /// 本轮尚未交付的摘要目标与 replace-all 标记。
    private var metaRequested = Set<String>()
    private var metaReplaceAllPending = false
    private var metaRequestVersion = 0
    /// 退出后拦截仍可能落到主线程的后台回调/动作。
    private let lifecycle = ProcessProbe.LifecycleGuard()
    /// 新会话共享一次 PID 快照监测。
    private let processMonitor = ProcessProbe.Monitor()
    /// 每个项目最新一次启动请求；旧请求的终态不覆盖新请求。
    private var latestLaunchRequest: [String: String] = [:]
    private var launchTokens: [String: Launcher.CancelToken] = [:]

    /// 兜底用的终端：真选不到时也要能给出一条像样的错误提示
    private var launchTerminal: Terminal.Kind {
        selectedTerminal ?? Terminal.kind(id: "ghostty") ?? Terminal.known[0]
    }

    /// 页面开始加载后调用：Store 在后台读，终端检测留在主线程。
    /// 三路都到齐再应用一致快照；在此之前依赖项目/终端的动作排队。
    func startPreparation() {
        assert(Thread.isMainThread)
        guard lifecycle.isActive else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = Store.load()
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isActive else { return }
                self.favorites = loaded.favorites
                self.recents = loaded.recents
                self.storeLoaded = true
                self.maybeBootstrap()
            }
        }

        let picked = resolveTerminal()
        if picked.fellBack, let kind = picked.kind {
            let saved = Terminal.savedSelection()
            let savedName = saved.flatMap { Terminal.kind(id: $0)?.name } ?? saved ?? "之前选的终端"
            let installed = terminals.contains { $0.id == saved }
            let why = installed ? "\(savedName) 还不支持自动启动" : "没找到 \(savedName)"
            fallbackNotice = "\(why)，已用 \(kind.name)"
        }
        // 不预置 lastPushedTerminalID：首推若晚于页面加载，仍要按终端标签变化重测。
        terminalsLoaded = true
        maybeBootstrap()
    }

    /// 当前页面脚本就绪：绑定这个页面的 pageID，导入一次活跃请求/最近状态快照。
    /// 旧页面的普通投递随后都会带旧 pageID，被新页面忽略。
    func pageBecameReady(_ pageID: String) {
        assert(Thread.isMainThread)
        guard lifecycle.isActive, !pageID.isEmpty else { return }
        let newGeneration: Bool
        if let oldPageID = currentPageID { newGeneration = oldPageID != pageID } else { newGeneration = true }
        // 同页重复 ready 不能重新授予快照或清空待发资格；只保留首次页面代际导入。
        guard newGeneration else { return }
        currentPageID = pageID
        pageReady = true
        lastDataFingerprint = nil
        lastStatusFingerprint = nil
        latestIntentByPath.removeAll()
        pendingSnapshot = true
        if bootstrapped {
            sendSnapshot()
        } else {
            maybeBootstrap()
        }
    }

    private func sendSnapshot() {
        let snapshot = pendingSnapshot
        pendingSnapshot = false
        if let lastStatus {
            push(status: lastStatus.text, tone: lastStatus.tone,
                 phase: lastStatus.phase, scope: lastStatus.scope,
                 project: lastStatus.project, mode: lastStatus.mode,
                 requestId: lastStatus.requestId, origin: lastStatus.origin,
                 snapshot: snapshot, replay: true)
        } else if let fallbackNotice {
            push(status: fallbackNotice, phase: .done, snapshot: snapshot)
        } else {
            push(snapshot: snapshot)
        }
    }

    private func maybeBootstrap() {
        guard lifecycle.isActive,
              !bootstrapped, storeLoaded, terminalsLoaded, pageReady else { return }
        bootstrapped = true
        sendSnapshot()
        refreshMeta()
        let queued = pendingActions.takeAll()
        queued.forEach { $0() }
    }

    /// 准备完成前需要项目/终端快照的动作在这里排队；主题和退出不排队。
    private func whenReady(_ action: @escaping () -> Void) {
        guard lifecycle.isActive else { return }
        if bootstrapped { action() } else { pendingActions.enqueue(action) }
    }

    /// 读偏好 + 检测已装终端，算出这次真正用的那个。
    /// 存的终端没装 / 未适配时回落到第一可用，并把回落的那个存下来（下次不再提示）。
    @discardableResult
    private func resolveTerminal() -> (kind: Terminal.Kind?, fellBack: Bool) {
        let saved = Terminal.savedSelection()
        terminals = Terminal.installed()
        let picked = Terminal.resolve(selected: saved, available: terminals)
        // 不覆写偏好：用户选的那款只是暂时用不了（没装 / 未适配），
        // 装回来就还是它。运行时用回落结果，底栏会把原因说清楚。
        selectedTerminal = picked.kind
        return picked
    }

    /// 只请求受影响的项目；首轮或 meta 尚未建立时请求全部。
    /// 合并所有已请求目标：快照里缺失的目标要移除旧 meta；空集合取消旧工作。
    private func refreshMeta(projects requested: [String]? = nil) {
        guard lifecycle.isActive else { return }
        // 首轮全量请求已经发出时，后续增量只并入它，不再额外触发一次全量；
        // 真正尚未发起首轮（metaReady=false 且没有已请求目标）才提升为全量。
        let replaceAll = requested == nil || (!metaReady && metaRequested.isEmpty)
        let targets = replaceAll ? (favorites + recents) : (requested ?? [])
        if targets.isEmpty {
            metaRequestVersion += 1
            summaryCoordinator.cancelAll()
            meta.removeAll()
            metaRequested.removeAll()
            metaReplaceAllPending = false
            metaReady = true
            push()
            return
        }
        metaRequestVersion += 1
        let version = metaRequestVersion
        metaRequested.formUnion(targets)
        if replaceAll { metaReplaceAllPending = true }
        summaryCoordinator.request(projects: targets) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isActive else { return }
                // 更新请求已经发出时，旧快照不得吃掉新一轮的 pending 目标。
                guard version == self.metaRequestVersion else { return }
                guard snapshot.generation > self.metaGeneration else { return }
                self.metaGeneration = snapshot.generation
                let applied = self.metaRequested
                self.metaRequested.removeAll()
                let replace = self.metaReplaceAllPending
                self.metaReplaceAllPending = false
                // 快照缺失（nil）移除；合并多个增量覆盖所有已请求目标；过滤当前项目。
                let current = Set((self.favorites + self.recents).map { self.normalize($0) })
                var updated = self.meta
                ProcessProbe.RuntimeProjection.apply(
                    to: &updated, requested: applied,
                    snapshot: snapshot.summaries, replaceAll: replace,
                    current: current, normalize: { self.normalize($0) })
                self.meta = updated
                self.metaReady = true
                self.push()
            }
        }
    }

    // ── 界面 → 原生 ────────────────────────────────────
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "open", "continue", "new":
            // JS 发的是 { action: "open", mode: "new" | "continue", requestId }；
            // 早期版本直接把 mode 当 action 发，所以两种都认。
            if let id = body["id"] as? String {
                let mode = body["mode"] as? String ?? action
                let requestId = requestID(from: body)
                whenReady { [weak self] in self?.open(id, mode: mode, requestId: requestId) }
            }
        case "history":
            if let id = body["id"] as? String {
                let ticket = body["ticket"] as? Int
                whenReady { [weak self] in self?.loadHistory(id, ticket: ticket) }
            }
        case "resume":
            if let id = body["id"] as? String, let session = body["session"] as? String {
                let requestId = requestID(from: body)
                whenReady { [weak self] in self?.resume(id, session: session, requestId: requestId) }
            }
        case "toggleFavorite":
            if let id = body["id"] as? String {
                whenReady { [weak self] in self?.toggleFavorite(id) }
            }
        case "remove":
            if let id = body["id"] as? String {
                whenReady { [weak self] in self?.removeRecent(id) }
            }
        case "ready":
            // 页面脚本就绪：立即绑定 pageID，不等 Store/终端准备。
            if let pageID = body["pageID"] as? String {
                pageBecameReady(pageID)
            }
        case "pickFolder":
            let then = body["then"] as? String ?? "open"
            let requestId = requestID(from: body)
            whenReady { [weak self] in
                self?.pickFolder(then: then, requestId: requestId)
            }
        case "setTerminal":
            if let id = body["id"] as? String {
                whenReady { [weak self] in self?.chooseTerminal(id) }
            }
        case "detectTerminals":
            whenReady { [weak self] in self?.detectTerminals() }
        case "theme":
            // "night" / "day"：只影响窗口自己的底色，页面自己画满
            onTheme?(body["value"] as? String == "night")
        case "quit":
            onQuit?()
        default:
            break
        }
    }

    // ── 原生 → 界面 ────────────────────────────────────
    /// 这条状态属于谁：启动流程的终态才能撤掉卡片 loading，其它操作不行
    private enum StatusScope: String {
        case launch
        case operation
    }

    private func requestID(from body: [String: Any]) -> String? {
        guard let raw = body["requestId"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 请求 ID 是 launch-<pageID>-<intentSeq>；页内序号才是新旧依据。
    private func launchIdentity(_ requestId: String?) -> LaunchIdentity? {
        guard let requestId else { return nil }
        let parts = requestId.split(separator: "-")
        guard parts.count == 3, parts[0] == "launch",
              parts[1].hasPrefix("p"), let seq = Int(parts[2]) else { return nil }
        return LaunchIdentity(pageID: String(parts[1]), seq: seq)
    }

    /// 只影响展示资格；不取消真实开窗。旧页/旧 panel 序号返回 false。
    private func shouldDisplay(_ path: String, _ requestId: String?) -> Bool {
        guard let requestId else { return true }
        guard let identity = launchIdentity(requestId) else { return true }
        guard let currentPageID, identity.pageID == currentPageID else { return false }
        if let latest = latestIntentByPath[path],
           latest.pageID == identity.pageID, identity.seq < latest.seq {
            return false
        }
        return true
    }

    /// 展示资格被否的旧请求：只让界面回收自己的挂起态，不影响真实开窗。
    private func releaseDisplay(_ path: String, _ requestId: String?) {
        guard let requestId, !shouldDisplay(path, requestId) else { return }
        evaluate("window.__intentReleased", requestId)
    }

    private func activeRequestsPayload() -> [[String: Any]] {
        activeLaunches.keys.sorted().compactMap { key -> [String: Any]? in
            guard let active = activeLaunches[key] else { return nil }
            let item: [String: Any] = ["requestId": active.displayRequestId,
                                       "project": active.project, "mode": active.mode]
            return item
        }
    }

    private func removeActiveLaunches(for path: String) {
        var kept: [String: ActiveLaunch] = [:]
        for (key, active) in activeLaunches where active.project != path {
            kept[key] = active
        }
        activeLaunches = kept
    }

    /// 展示记录只跟随当前项目列表和在途请求；自动淘汰/失败/完成后也要收敛。
    private func reconcileDisplayState() {
        let current = Set((favorites + recents).map { normalize($0) })
        var inFlight = Set(latestLaunchRequest.keys.map { normalize($0) })
        for active in activeLaunches.values { inFlight.insert(normalize(active.project)) }
        var keptIntent: [String: LaunchIdentity] = [:]
        for (path, identity) in latestIntentByPath {
            let key = normalize(path)
            if current.contains(key) || inFlight.contains(key) { keptIntent[path] = identity }
        }
        latestIntentByPath = keptIntent
    }

    private func forgetProjectDisplay(_ path: String) {
        latestIntentByPath[path] = nil
        latestLaunchRequest[path] = nil
        removeActiveLaunches(for: path)
        reconcileDisplayState()
    }

    private func push(status: String? = nil, tone: String? = nil, phase: StatusPhase? = nil,
                      scope: StatusScope = .operation, project: String? = nil,
                      mode: String? = nil, requestId: String? = nil,
                      origin: String? = nil, snapshot: Bool = false, replay: Bool = false) {
        guard lifecycle.isActive else { return }
        reconcileDisplayState()
        guard let pageID = currentPageID else { return }
        var projects: [[String: Any]] = []

        func add(_ path: String, favorite: Bool) {
            var item: [String: Any] = [
                "id": path, "path": path,
                "favorite": favorite, "missing": !Store.isDirectory(path)
            ]
            if let summary = summaryFor(path) {
                item["sessionCount"] = summary.count
                if let last = summary.last { item["lastActivity"] = last.timeIntervalSince1970 * 1000 }
            }
            projects.append(item)
        }

        for path in favorites { add(path, favorite: true) }
        // 已置顶的常用项不再在最近里重复出现（用标准化路径比较，兼容尾斜杠差异）
        let favoriteKeys = Set(favorites.map { normalize($0) })
        for path in recents where !favoriteKeys.contains(normalize(path)) {
            add(path, favorite: false)
        }

        var payload: [String: Any] = [
            "pageID": pageID,
            "projects": projects,
            "home": FileManager.default.homeDirectoryForCurrentUser.path,
            "terminals": terminals.map { kind in
                ["id": kind.id, "name": kind.name, "note": kind.note,
                 "supported": kind.supported, "selected": kind.id == selectedTerminal?.id]
            }
        ]
        if let status { payload["status"] = status }
        if let tone { payload["statusTone"] = tone }
        if let phase { payload["statusPhase"] = phase.rawValue }
        if status != nil { payload["statusScope"] = scope.rawValue }
        if let project { payload["statusProject"] = project }
        if let mode { payload["statusMode"] = mode }
        if let requestId { payload["statusRequestID"] = requestId }
        if let origin { payload["statusOrigin"] = origin }
        if replay { payload["statusReplay"] = true }
        if snapshot {
            payload["snapshot"] = true
            payload["activeRequests"] = activeRequestsPayload()
        }

        if let status {
            lastStatus = LastStatus(text: status, tone: tone, phase: phase,
                                    scope: scope, project: project, mode: mode,
                                    requestId: requestId, origin: origin)
        }

        let terminalID = selectedTerminal?.id ?? ""
        let terminalChanged = terminalID != lastPushedTerminalID
        lastPushedTerminalID = terminalID

        // 纯数据签名不含状态；状态用独立签名，避免状态推送后的无状态刷新重复跨桥。
        var dataPayload = payload
        for key in ["status", "statusTone", "statusPhase", "statusScope",
                    "statusProject", "statusMode", "statusRequestID", "statusOrigin",
                    "statusReplay", "pageID", "snapshot", "activeRequests"] {
            dataPayload.removeValue(forKey: key)
        }
        let dataFingerprint = Bridge.jsonFingerprint(dataPayload) ?? UUID().uuidString
        let statusFingerprint = [
            status ?? "", tone ?? "", phase?.rawValue ?? "",
            status != nil ? scope.rawValue : "", project ?? "", mode ?? "",
            requestId ?? "", origin ?? "", replay ? "1" : "0"
        ].joined(separator: "\u{1F}")
        let hasStatus = status != nil
        let dataChanged = lastDataFingerprint.map { $0 != dataFingerprint } ?? true
        let statusChanged = lastStatusFingerprint.map { $0 != statusFingerprint } ?? true
        if !dataChanged && (!hasStatus || !statusChanged) { return }
        lastDataFingerprint = dataFingerprint
        lastStatusFingerprint = statusFingerprint

        evaluate("window.__render", payload)
        // 只在当前终端标签变化时重量标题栏；缩放由 windowDidResize 单独合并。
        if terminalChanged { onPush?() }
    }

    private static func jsonFingerprint(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func toast(_ message: String) {
        evaluate("window.__toast", message)
    }

    private func evaluate(_ fn: String, _ argument: Any) {
        guard lifecycle.isActive,
              let data = try? JSONSerialization.data(withJSONObject: [argument]),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "\(fn)(\(json)[0]);"
        if Thread.isMainThread {
            webView?.evaluateJavaScript(script)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.isActive else { return }
                self.webView?.evaluateJavaScript(script)
            }
        }
    }

    /// 历史页数据：只回传会话元数据（标题／时间／条数／路径），不含聊天正文。
    /// ticket 原样回传用于丢弃迟到响应。
    private func pushHistory(project: String, sessions: [[String: Any]], error: String? = nil, ticket: Int? = nil) {
        guard lifecycle.isActive else { return }
        var payload: [String: Any] = ["project": project, "sessions": sessions]
        if let error { payload["error"] = error }
        if let ticket { payload["ticket"] = ticket }
        evaluate("window.__history", payload)
    }

    // ── 动作 ───────────────────────────────────────────

    /// mode: "new" = 一定新开会话；"continue"/"open" = 有旧会话就继续最近一条。
    /// announced：界面已经自己写过 start 状态（点卡片 / 历史页），不要再推一条同相的；
    /// 面板选目录这条路界面不知道选了哪个文件夹，由原生补一条。
    /// 决策在后台队列做（要读会话目录），完成后回主线程启动。
    private func open(_ path: String, mode: String, requestId: String?, announced: Bool = false) {
        guard lifecycle.isActive else { return }
        // 旧界面可能不带 requestId：内部用唯一键隔离，但不回传，保留按项目收尾的旧语义。
        let launchKey = requestId ?? UUID().uuidString
        let display = shouldDisplay(path, requestId)
        guard Store.isDirectory(path) else {
            if display {
                toast("这个文件夹已不存在，请重新选择。")
                // 界面可能正在等这次启动：必须给一个终态，否则卡片 loading 要等到 30 秒超时
                push(status: "打开失败：文件夹不在了", tone: "error", phase: .error,
                     scope: .launch, project: path, requestId: requestId)
            } else if let requestId {
                evaluate("window.__intentReleased", requestId)
            }
            return
        }
        if display {
            if let identity = launchIdentity(requestId) {
                latestIntentByPath[path] = identity
            }
            latestLaunchRequest[path] = launchKey
            if let requestId, launchIdentity(requestId) != nil {
                removeActiveLaunches(for: path)
                activeLaunches[launchKey] = ActiveLaunch(project: path, mode: mode,
                                                         displayRequestId: requestId)
            }
        } else if let requestId {
            // 旧 panel/旧页只压展示，不取消实际开窗。
            evaluate("window.__intentReleased", requestId)
        }
        if announced && display {
            push(status: "正在打开 \(URL(fileURLWithPath: path).lastPathComponent)…", phase: .start,
                 scope: .launch, project: path, mode: mode, requestId: requestId,
                 origin: "panel")
        }
        // 先定下这次用哪个终端：启动过程中切换终端不影响手里这次。
        let terminal = launchTerminal

        if mode == "new" {
            launch(path, session: nil, intent: .new, terminal: terminal,
                   requestId: launchKey, echoRequestId: requestId)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let session = SessionHistory.latest(project: path)?.path
            DispatchQueue.main.async {
                self?.continueLaunch(path, session: session, terminal: terminal,
                                     requestId: launchKey, echoRequestId: requestId)
            }
        }
    }

    /// 继续/打开：先查已有 Ghostty 窗口；查询失败与明确没找到分开处理。
    private func continueLaunch(_ path: String, session: String?, terminal: Terminal.Kind,
                                requestId: String, echoRequestId: String?) {
        guard lifecycle.isActive else { return }
        guard terminal.supportsRefocus else {
            launch(path, session: session, intent: session == nil ? .new : .latest,
                   terminal: terminal, requestId: requestId, echoRequestId: echoRequestId)
            return
        }
        switch Launcher.existingTerminalResult(for: path) {
        case .failure(let error):
            failLaunch(path, error: error, requestId: requestId, echoRequestId: echoRequestId)
        case .none:
            launch(path, session: session, intent: session == nil ? .new : .latest,
                   terminal: terminal, requestId: requestId, echoRequestId: echoRequestId)
        case .found(let existing):
            switch Launcher.focusOutcome(terminalID: existing, for: path) {
            case .focused:
                completeLaunch(path, status: "已切到该项目的已有窗口",
                               requestId: requestId, echoRequestId: echoRequestId)
            case .notFound:
                launch(path, session: session, intent: session == nil ? .new : .latest,
                       terminal: terminal, requestId: requestId, echoRequestId: echoRequestId)
            case .failure(let error):
                failLaunch(path, error: error, requestId: requestId, echoRequestId: echoRequestId)
            }
        }
    }

    /// 这次启动是为了什么：决定成功后的说法，也决定要不要等 pi 把会话文件写出来。
    private enum LaunchIntent {
        case new        // 新会话
        case latest     // 继续这一项最近的一条
        case specific   // 历史页里指定的那一条
    }

    /// 真正开窗。session 为 nil 就是新会话；terminal 与 session 在这次调用内固定。
    private func launch(_ path: String, session: String?, intent: LaunchIntent,
                        terminal: Terminal.Kind, requestId: String, echoRequestId: String?) {
        guard lifecycle.isActive else { return }
        let startedAt = Date()
        let token = Launcher.CancelToken()
        launchTokens[requestId] = token
        Launcher.openStepwise(projectPath: path, sessionPath: session,
                              terminal: terminal, token: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isActive else { return }
                // 旧完成不能清掉同键的新 token（无 requestID 的兼容路径按项目复用键）。
                if let current = self.launchTokens[requestId], current === token {
                    self.launchTokens[requestId] = nil
                }
                switch result {
                case .failure(let error):
                    self.failLaunch(path, error: error, requestId: requestId,
                                    echoRequestId: echoRequestId)
                case .success(_):
                    switch intent {
                    case .new:
                        self.awaitNewSession(project: path, since: startedAt,
                                             terminal: terminal, requestId: requestId,
                                             echoRequestId: echoRequestId)
                    case .latest:
                        self.completeLaunch(path, status: "已继续上次会话",
                                            requestId: requestId, echoRequestId: echoRequestId)
                    case .specific:
                        self.completeLaunch(path, status: "已继续这个会话",
                                            requestId: requestId, echoRequestId: echoRequestId)
                    }
                }
            }
        }
    }

    /// 新会话：窗口建好不等于 pi 起来了。先记最近、亮一条「等 pi 起来」，
    /// 再由共享监测器立即首检，12 秒从终端调用返回后算。
    private func awaitNewSession(project path: String, since startedAt: Date,
                                 terminal: Terminal.Kind, requestId: String,
                                 echoRequestId: String?) {
        guard lifecycle.isActive else { return }
        // 12 秒从终端调用返回（进入本函数）算，不受记最近/保存耗时影响。
        let deadline = Date().addingTimeInterval(12)
        noteRecent(path)
        guard isCurrentLaunch(path, requestId) else {
            releaseDisplay(path, echoRequestId)
            return
        }
        push(status: "已在 \(terminal.name) 开窗口，等 pi 起来…", phase: .start,
             scope: .launch, project: path, requestId: echoRequestId)
        processMonitor.add(id: requestId, projectPath: path, since: startedAt,
                           expectedCommand: Launcher.piCommand,
                           deadline: deadline) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isActive else { return }
                switch result {
                case .running:
                    self.completeLaunch(path, status: "已开好新会话", requestId: requestId,
                                        echoRequestId: echoRequestId)
                case .timedOut:
                    guard self.isCurrentLaunch(path, requestId) else {
                        self.releaseDisplay(path, echoRequestId)
                        return
                    }
                    // 不谎报成功，也不谎报失败：窗口确实开了，只是没等到 pi
                    self.push(status: "已开窗口，但没等到 pi", phase: .done,
                              scope: .launch, project: path, requestId: echoRequestId)
                    self.clearLaunchRequest(path, requestId)
                }
            }
        }
    }

    private func failLaunch(_ path: String, error: Error, requestId: String,
                            echoRequestId: String?) {
        guard lifecycle.isActive else { return }
        guard isCurrentLaunch(path, requestId) else {
            releaseDisplay(path, echoRequestId)
            return
        }
        toast(error.localizedDescription)
        push(status: "打开失败", tone: "error", phase: .error,
             scope: .launch, project: path, requestId: echoRequestId)
        clearLaunchRequest(path, requestId)
    }

    private func isCurrentLaunch(_ path: String, _ requestId: String) -> Bool {
        latestLaunchRequest[path] == requestId
    }

    /// 终态后回收身份记录；只清自己，不碰同项目的新请求。
    private func clearLaunchRequest(_ path: String, _ requestId: String) {
        if latestLaunchRequest[path] == requestId { latestLaunchRequest[path] = nil }
        activeLaunches[requestId] = nil
        reconcileDisplayState()
    }

    /// 启动成功后的收尾：记最近、刷新该项目摘要、推终态。
    private func completeLaunch(_ path: String, status: String, requestId: String,
                                echoRequestId: String?, phase: StatusPhase = .done,
                                tone: String? = "ok") {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycle.isActive else { return }
            self.noteRecent(path)
            // 继续/复用已知项目也要检查本次项目是否写入新消息；只刷新这一项。
            // 即使这次已被同项目的新请求取代，已完成的开窗/聚焦仍影响该项目摘要。
            self.refreshMeta(projects: [path])
            guard self.isCurrentLaunch(path, requestId) else {
                self.releaseDisplay(path, echoRequestId)
                return
            }
            self.push(status: status, tone: tone, phase: phase,
                      scope: .launch, project: path, requestId: echoRequestId)
            self.clearLaunchRequest(path, requestId)
        }
    }

    /// 记到「最近」并落盘。新会话要等 pi 写文件才算开好，但列表不能等到那时才更新。
    private func noteRecent(_ path: String) {
        guard lifecycle.isActive else { return }
        recents = Store.pushRecent(path, into: recents)
        reconcileDisplayState()
        if !Store.save(favorites: favorites, recents: recents) {
            toast("已打开，但项目列表保存失败（下次可能不记录）。")
        }
    }

    /// 点「历史」时现读当前项目的会话目录（启动时不预扫全部会话）。
    private func loadHistory(_ path: String, ticket: Int?) {
        guard lifecycle.isActive else { return }
        guard Store.isDirectory(path) else {
            pushHistory(project: path, sessions: [], error: "这个文件夹已不存在。", ticket: ticket)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, self.lifecycle.isActive else { return }
            do {
                let items = try SessionHistory.list(project: path)
                self.pushHistory(project: path, sessions: items.map { $0.payload }, ticket: ticket)
            } catch {
                self.pushHistory(project: path, sessions: [], error: "读取会话列表失败。", ticket: ticket)
            }
        }
    }

    /// 继续旧会话。界面传回的路径不可信，必须先重新核验它属于这个项目；
    /// 终端与请求 ID 在收到消息时固定，核验后贯穿本次启动。
    private func resume(_ path: String, session: String, requestId: String?) {
        guard lifecycle.isActive else { return }
        let launchKey = requestId ?? UUID().uuidString
        let display = shouldDisplay(path, requestId)
        guard Store.isDirectory(path) else {
            if display {
                toast("这个文件夹已不存在，请重新选择。")
                push(status: "打开失败：文件夹不在了", tone: "error", phase: .error,
                     scope: .launch, project: path, requestId: requestId)
            } else if let requestId {
                evaluate("window.__intentReleased", requestId)
            }
            return
        }
        if display {
            if let identity = launchIdentity(requestId) {
                latestIntentByPath[path] = identity
            }
            latestLaunchRequest[path] = launchKey
            if let requestId, launchIdentity(requestId) != nil {
                removeActiveLaunches(for: path)
                activeLaunches[launchKey] = ActiveLaunch(project: path, mode: "continue",
                                                         displayRequestId: requestId)
            }
        } else if let requestId {
            evaluate("window.__intentReleased", requestId)
        }
        let terminal = launchTerminal
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let verified = SessionHistory.validated(session, project: path)
            DispatchQueue.main.async {
                guard let self, self.lifecycle.isActive else { return }
                guard let verified else {
                    guard self.isCurrentLaunch(path, launchKey) else {
                        self.releaseDisplay(path, requestId)
                        return
                    }
                    self.toast("这个会话已不可用，请返回历史列表重选。")
                    // 界面把这一行标成了「启动中」，不给终态它就会一直挂着
                    self.push(status: "这个会话已不可用", tone: "error", phase: .error,
                              scope: .launch, project: path, requestId: requestId)
                    self.clearLaunchRequest(path, launchKey)
                    return
                }
                self.launch(path, session: verified, intent: .specific,
                            terminal: terminal, requestId: launchKey, echoRequestId: requestId)
            }
        }
    }

    /// 界面选了终端。只认已安装且已适配的；写盘失败不谎报切换成功。
    private func chooseTerminal(_ id: String) {
        guard lifecycle.isActive else { return }
        guard let kind = Terminal.kind(id: id) else { return }
        guard kind.supported else {
            toast("\(kind.name) 还不支持自动启动。")
            push()
            return
        }
        guard Terminal.isInstalled(kind) else {
            toast("没找到 \(kind.name)。")
            push()
            return
        }
        guard Terminal.saveSelection(kind.id) else {
            toast("保存失败，终端没有切换。")
            push()
            return
        }
        selectedTerminal = kind
        push(status: "已切换到 \(kind.name)", tone: "ok", phase: .done)
    }

    /// 重新检测已装终端并推给界面。菜单打开时调一次：运行期间装了 / 卸了终端要跟着变。
    private func detectTerminals() {
        guard lifecycle.isActive else { return }
        let installed = Terminal.installed()
        terminals = installed
        // 之前选的终端被卸了：回落到能用的那款，并如实说明
        if let current = selectedTerminal, !installed.contains(where: { $0.id == current.id }) {
            let picked = resolveTerminal()
            if let kind = picked.kind {
                push(status: "没找到 \(current.name)，已用 \(kind.name)", phase: .done)
                return
            }
        }
        push()
    }

    /// 选文件夹。then = "favorite" 时只把选中的文件夹固定到常用区（不启动 PI）；
    /// 其余（"open"）在该目录启动 PI。
    private func pickFolder(then intent: String, requestId: String?) {
        guard lifecycle.isActive else { return }
        // 选文件夹会抢焦点，先让面板成为前台
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = intent == "favorite" ? "添加" : "打开"
        panel.message = intent == "favorite"
            ? "选择要固定到常用区的项目文件夹"
            : "选择要用 PI 打开的项目文件夹"

        guard panel.runModal() == .OK, let url = panel.url else {
            // 取消选目录：释放面板前登记、尚未绑定项目的意图；不启动 30 秒计时。
            if let requestId { evaluate("window.__intentReleased", requestId) }
            webView?.window?.makeFirstResponder(webView)
            return
        }

        if intent == "favorite" {
            if let requestId { evaluate("window.__intentReleased", requestId) }
            addFavorite(url.path)
        } else {
            // 选目录返回只补项目，沿用界面登记时冻结的 requestId，不生成新号。
            open(url.path, mode: "continue",
                 requestId: requestId ?? UUID().uuidString, announced: true)
        }
    }

    /// 仅加入常用区：不启动 PI，不写最近列表。
    private func addFavorite(_ path: String) {
        guard lifecycle.isActive else { return }
        guard Store.isDirectory(path) else {
            toast("这个文件夹已不存在，无法加入常用。")
            return
        }
        let previouslyRecorded = (favorites + recents).contains {
            normalize($0) == normalize(path)
        }
        let result = Store.addingFavorite(path, favorites: favorites, recents: recents)
        guard result.added else {
            push(status: "这个项目已经在常用里了", tone: "ok")
            return
        }

        let previousFavorites = favorites
        let previousRecents = recents
        favorites = result.favorites
        recents = result.recents

        guard Store.save(favorites: favorites, recents: recents) else {
            favorites = previousFavorites
            recents = previousRecents
            toast("保存失败，没有加入常用。")
            push()
            return
        }
        push(status: "已加入常用项目", tone: "ok")
        // 从未记录的项目第一次加入常用时只刷新这一项；已有星标/重排不重读。
        if !previouslyRecorded { refreshMeta(projects: [path]) }
    }

    /// 从「最近」移除。常用项不能这样移除（取消星标即可，会降级到最近）。
    private func removeRecent(_ path: String) {
        guard lifecycle.isActive else { return }
        guard !favorites.contains(path) else {
            push(status: "常用项目请先取消星标", tone: "ok")
            return
        }
        let previous = recents
        let result = Store.removingRecent(path, favorites: favorites, recents: recents)
        recents = result.recents

        guard Store.save(favorites: favorites, recents: recents) else {
            recents = previous
            toast("保存失败，没有移除。")
            push()
            return
        }
        meta[path] = nil
        summaryCoordinator.remove(project: path)
        forgetProjectDisplay(path)
        push(status: "已从最近项目里移除", tone: "ok")
        if favorites.isEmpty && recents.isEmpty {
            // 没有任何当前项目时取消仍在跑的摘要工作。
            refreshMeta(projects: [])
        }
    }

    /// 切换常用。取消常用时项目降级到「最近」，不会从列表消失（逻辑见 Store.togglingFavorite）。
    private func toggleFavorite(_ path: String) {
        guard lifecycle.isActive else { return }
        guard favorites.contains(path) || Store.isDirectory(path) else {
            toast("这个文件夹已不存在，无法设为常用。")
            return
        }

        let result = Store.togglingFavorite(path, favorites: favorites, recents: recents)
        let previousFavorites = favorites
        let previousRecents = recents
        favorites = result.favorites
        recents = result.recents

        guard Store.save(favorites: favorites, recents: recents) else {
            favorites = previousFavorites
            recents = previousRecents
            toast("保存失败，改动未生效。")
            push()
            return
        }
        // 星标只改分组/顺序，历史摘要没有变化，不重读。
        push(status: result.madeFavorite ? "已设为常用" : "已取消常用，保留在最近项目中", tone: "ok")
    }

    /// 退出：停摘要协调器、共享 PID 监测和尚未提交的 Ghostty 等待。
    func shutdown() {
        guard lifecycle.isActive else { return }
        // 先关门：已在主线程排队的后台回调看到 inactive 后不再启动/写最近。
        lifecycle.shutdown()
        pendingActions.close()
        metaRequestVersion += 1
        metaRequested.removeAll()
        metaReplaceAllPending = false
        latestLaunchRequest.removeAll()
        latestIntentByPath.removeAll()
        activeLaunches.removeAll()
        currentPageID = nil
        pendingSnapshot = false
        fallbackNotice = nil
        meta.removeAll()
        summaryCoordinator.shutdown()
        processMonitor.shutdown()
        for token in launchTokens.values { token.cancel() }
        launchTokens.removeAll()
    }

    /// 词法等价的别名键也可能保存着同一项目的摘要；保留项目 ID，不改成规范路径。
    private func summaryFor(_ path: String) -> SessionHistory.Summary? {
        if let exact = meta[path] { return exact }
        let key = normalize(path)
        return meta.first { normalize($0.key) == key }?.value
    }

    /// 与协调器一致：只做词法标准化并去掉尾部斜杠，不按 realpath 合并项目。
    private func normalize(_ path: String) -> String {
        var key = URL(fileURLWithPath: path).standardizedFileURL.path
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }
}

// ══════════════════════════════════════════════════════
// 应用
// ══════════════════════════════════════════════════════

/// 网页标题栏（ui/app.css 的 `.bar`）高度，与下面的透明拖动层共用，改一处要一起改
private let titlebarHeight: CGFloat = 40
/// 标题栏右侧给控件让出的宽度。页面加载后由 JS 实测回报（window.__titlebarReserved），
/// 不再手抄 CSS 内距——既往前这里写 88、CSS 写 20，两边已经对不上。
/// 这个值只在页面还没回话时顶一下，宁可多让：右边是终端选择与昼夜开关。
private let defaultTitlebarRightReserved: CGFloat = 220
/// 窗口底色。网页自己画满，这个值只在缩放/抖动、或页面还没绘制时露出来，
/// 所以必须跟着昼夜主题走，否则暗色下拖窗口边缘会闪一道白边。
/// 窗口底色只用于加载/缩放时露出的那几帧和圆角处，取纸卡主题的画布色
private let windowBaseDay = NSColor(srgbRed: 0.933, green: 0.910, blue: 0.855, alpha: 1)
private let windowBaseNight = NSColor(srgbRed: 0.071, green: 0.067, blue: 0.047, alpha: 1)

/// 标题栏拖动条：WKWebView 会吞掉铺满窗口的鼠标事件，
/// 不在它上面盖一层，fullSizeContentView 的窗口就没有任何可拖动的落点。
final class TitlebarDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 网页的菜单收不到这里的按下事件（被这层挡了），转一手让页面先收起菜单
        (superview?.subviews.first { $0 is WKWebView } as? WKWebView)?
            .evaluateJavaScript("window.__dismissMenus && window.__dismissMenus()")
        window?.performDrag(with: event)
    }

    // 纯透明层，不画任何东西，底下的网页标题照常可见
    override var isOpaque: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var dragBar: TitlebarDragView!
    /// 页面实测出来的左右让位宽度（左边红绿灯、右边终端选择与昼夜开关）
    private var titlebarLeftInset: CGFloat = 84
    private var titlebarRightReserved = defaultTitlebarRightReserved
    private var measureWorkItem: DispatchWorkItem?
    private let bridge = Bridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "launcher")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "PI 项目启动器"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = windowBaseDay
        window.minSize = NSSize(width: 520, height: 460)
        window.setFrameAutosaveName("PILauncherWindow")
        window.delegate = self

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        window.contentView!.addSubview(webView)

        // WebView 铺满整个窗口，会把鼠标事件全吞掉，fullSizeContentView 的窗口
        // 于是没有任何可拖动的落点。盖一条与网页标题栏等高（.bar = 40px）的透明层，
        // 把点击交还给窗口自己拖动；它不绘制，标题文字照常从下层透出来。
        // 右侧要停在哪由页面实测（终端选择在左边，昼夜开关在右边），参见 layoutDragBar。
        dragBar = TitlebarDragView(frame: .zero)
        dragBar.autoresizingMask = [.minXMargin, .minYMargin]
        window.contentView!.addSubview(dragBar)
        layoutDragBar()

        bridge.webView = webView
        bridge.onQuit = { [weak self] in
            self?.bridge.shutdown()
            NSApp.terminate(nil)
        }
        bridge.onTheme = { [weak self] night in
            self?.window.backgroundColor = night ? windowBaseNight : windowBaseDay
        }
        bridge.onPush = { [weak self] in self?.scheduleTitlebarMeasure() }

        loadUI()

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 窗口先出现；下一轮主循环再开始 Store/终端准备，与页面加载并行。
        DispatchQueue.main.async { [weak self] in self?.bridge.startPreparation() }
    }

    // 最后一个窗口关闭就退出；点 X、⌘W 都走这里
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
    }

    // ── 菜单 ───────────────────────────────────────────

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 PI 项目启动器", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 PI 项目启动器", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其它", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PI 项目启动器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单：没有它，搜索框里的 ⌘C / ⌘V / ⌘A 全都不起作用
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "PI 项目启动器"
        alert.informativeText = """
        点卡片＝在这个项目里开新会话；⌘↵ 继续上次。
        关窗口即退出。
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    // ── 界面加载 ───────────────────────────────────────

    private func loadUI() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("ui") else {
            fail("找不到界面文件（ui 目录）。")
            return
        }
        let index = dir.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else {
            fail("找不到界面文件：\(index.path)")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: dir)
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "PI 项目启动器无法启动"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    // ── 拖动层让位 ───────────────────────────────────

    /// 拖动层只盖标题栏的空白段：左边让出红绿灯，右边让出终端选择与昼夜开关。
    /// 两侧都来自页面实测（window.__titlebarInsets），不再手抄 CSS 内距。
    private func layoutDragBar() {
        guard let content = window?.contentView, let dragBar else { return }
        let bounds = content.bounds
        let left = titlebarLeftInset
        dragBar.frame = NSRect(
            x: left,
            y: bounds.height - titlebarHeight,
            width: max(0, bounds.width - left - titlebarRightReserved),
            height: titlebarHeight
        )
    }

    /// 量页面标题栏两侧要留多宽。拿不到（页面还没加载完、或 JS 出错）就保持旧值。
    /// 推送与缩放停下都量一次：窄窗断点、终端名变长都会改这两个数。
    private func measureTitlebarInsets() {
        // push 会从后台队列触发这里，而 evaluateJavaScript 与 NSView 布局都只能在主线程
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.measureTitlebarInsets() }
            return
        }
        webView?.evaluateJavaScript("window.__titlebarInsets ? window.__titlebarInsets() : null") { [weak self] value, _ in
            guard let self, let dict = value as? [String: Any],
                  let leftNumber = dict["left"] as? NSNumber,
                  let rightNumber = dict["right"] as? NSNumber else { return }
            let left = CGFloat(truncating: leftNumber)
            let right = CGFloat(truncating: rightNumber)
            // 量错了会吞掉整个标题栏的拖动区：宁可不用
            guard left >= 40, left <= 200, right >= 40,
                  left + right <= self.window.frame.width else { return }
            guard abs(left - self.titlebarLeftInset) >= 0.5
                    || abs(right - self.titlebarRightReserved) >= 0.5 else { return }
            self.titlebarLeftInset = left
            self.titlebarRightReserved = right
            self.layoutDragBar()
        }
    }

    /// 同轮终端标签变化合并成一次测量；缩放仍走 windowDidResize 的 0.25 秒。
    private func scheduleTitlebarMeasure() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleTitlebarMeasure() }
            return
        }
        measureWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.measureTitlebarInsets() }
        measureWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    func windowDidResize(_ notification: Notification) {
        layoutDragBar()
        // 缩放停下再量：连续拖拽时每帧都去问页面没有意义
        measureWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.measureTitlebarInsets() }
        measureWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}

// 导航完成后推数据
extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 页面数据由 JS 的 ready 消息按 pageID 绑定；这里只做标题栏测量。
        scheduleTitlebarMeasure()
    }
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
