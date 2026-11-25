// 判断「这个项目里真的有东西跑起来了」。
//
// 为什么需要它：启动器把 pi 丢进终端后，AppleScript 返回只证明「窗口建好了」。
// 会话文件靠不住——实测 pi 启动后只建会话目录，`.jsonl` 要等你发第一条消息才落地，
// 拿它当信号会每次都等到超时。所以看进程：谁以这个项目目录为工作目录、且是在这次点击
// 之后才起来的。
//
// pi 是由 node 起的（comm 是 node，不是 pi），所以不能按进程名找。

import Foundation

enum ProcessProbe {
    /// 进程当前的 cwd。内核给的是解析过符号链接的真实路径（/tmp → /private/tmp）。
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// 进程启动时间
    static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    /// 该项目目录里是否已经有「moment 之后才起来、而且真的是 pi」的进程。
    /// 同一条路径的两种写法都认：/tmp/x 与 /private/tmp/x。
    /// 注意不能用 URL.resolvingSymlinksInPath()：它把 /var、/tmp 这些顶层链接放着不管，
    /// 实测 /var/folders/… 原样返回，而内核给的 cwd 是 /private/var/…，两边永远对不上。
    ///
    /// 身份也一并看：`exec pi` 失败时包装的 zsh 仍会在项目目录里活几百毫秒，
    /// 只看「目录里有新进程」会把它当成 pi，于是谎报「已开好新会话」。
    static func running(in projectPath: String, since moment: Date, expectedCommand: String? = nil) -> Bool {
        let targets: Set<String> = [projectPath, canonical(projectPath)]
        return allPIDs().contains { pid in
            guard pid > 0, let dir = cwd(of: pid), targets.contains(dir) else { return false }
            guard matches(command: expectedCommand, pid: pid) else { return false }
            guard let started = startTime(of: pid) else { return false }
            return started >= moment.addingTimeInterval(-1)
        }
    }

    /// 进程是不是期待的那个可执行文件。expectedCommand 为空时不筛（自检用）。
    ///
    /// 三处都看，因为本机实测 pi 的进程三处写法并不一致：
    ///   comm=node  exe=…/node/bin/node  argv[0]=pi
    /// （pi 是 #!/usr/bin/env node 的脚本，映像名是 node，只有 argv 认得出它）
    /// 只比 exe 文件名会让每个新会话都等到超时——这一版就是因为只比 exe 才要改。
    static func matches(command: String?, pid: pid_t) -> Bool {
        guard let command, !command.isEmpty else { return true }
        let expected = (command as NSString).lastPathComponent
        let argv = arguments(of: pid)
        if let first = argv.first, (first as NSString).lastPathComponent == expected { return true }
        // node /path/to/pi 这种写法：脚本在第 2 个参数上
        if argv.count > 1, (argv[1] as NSString).lastPathComponent == expected { return true }
        if let exe = executablePath(of: pid), (exe as NSString).lastPathComponent == expected { return true }
        return commandName(of: pid) == expected
    }

    /// 进程 self-reported 的名字（pi 会把自己命名成 pi）
    static func commandName(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return name.isEmpty ? nil : name
    }

    /// 进程的 argv（KERN_PROCARGS2）。格式：argc + exec 路径 + 若干 NUL + argv[]
    /// 读不到（权限或进程刚退出）时返回空数组。
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<MemoryLayout<Int32>.size]))
            }
        }
        var index = MemoryLayout<Int32>.size
        // 跳过 exec 路径
        while index < Int(buffer.count), buffer[index] != 0 { index += 1 }
        while index < Int(buffer.count), buffer[index] == 0 { index += 1 }

        var result: [String] = []
        while index < Int(buffer.count), result.count < Int(max(argc, 0)) {
            let start = index
            while index < Int(buffer.count), buffer[index] != 0 { index += 1 }
            if index > start { result.append(String(decoding: buffer[start..<index], as: UTF8.self)) }
            index += 1
        }
        return result
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// realpath(3)：把所有符号链接都解开，与内核报的 cwd 同一写法
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.stride + 64)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer,
                                  Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.stride))
    }
}


// MARK: - 运行生命周期

extension ProcessProbe {
    /// 极轻量的退出门：后台回调进入主线程后先问它，退出后不再启动动作或写最近。
    /// 只在主线程使用；shutdown 之后不可恢复。
    final class LifecycleGuard {
        private let lock = NSLock()
        private var active = true

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func shutdown() {
            lock.lock()
            active = false
            lock.unlock()
        }

        /// 返回是否执行；自检可独立验证退出后的拒绝路径。
        @discardableResult
        func performIfActive(_ action: () -> Void) -> Bool {
            lock.lock()
            let allowed = active
            lock.unlock()
            guard allowed else { return false }
            action()
            return true
        }
    }
}

// MARK: - 准备期动作队列

extension ProcessProbe {
    /// 首屏三路准备完成前只入队，不执行；一次取走全部，关闭后不再接收。
    /// 只在主线程使用，不需要额外同步。
    final class ActionQueue {
        private var actions: [() -> Void] = []
        private var open = true

        func enqueue(_ action: @escaping () -> Void) {
            guard open else { return }
            actions.append(action)
        }

        func takeAll() -> [() -> Void] {
            let result = actions
            actions.removeAll()
            return result
        }

        func close() {
            open = false
            actions.removeAll()
        }
    }
}

// MARK: - 接入层投影

extension ProcessProbe {
    /// 纯函数：把一轮已请求目标的快照投影到本地字典。
    /// 快照缺失的 key 必须移除；replaceAll 先清空；最后只保留当前列表项目。
    enum RuntimeProjection {
        /// 快照的键保留项目原字符串；查找按词法键（normalize）匹配，兼容协调器
        /// 在等价路径中只保留第一个原键的情况。真实 nil 会清掉同一词法键的旧值，
        /// 不按 realpath 合并项目。
        static func apply<T>(to meta: inout [String: T],
                             requested: Set<String>,
                             snapshot: [String: T],
                             replaceAll: Bool,
                             current: Set<String>,
                             normalize: (String) -> String = { $0 }) {
            if replaceAll { meta.removeAll() }
            var snapshotByKey: [String: T] = [:]
            for (key, value) in snapshot {
                snapshotByKey[normalize(key)] = value
            }
            for key in requested {
                let normalized = normalize(key)
                if let value = snapshotByKey[normalized] {
                    // 更新已有别名键的值，同时保留这些项目 ID。
                    for existing in Array(meta.keys) where normalize(existing) == normalized {
                        meta[existing] = value
                    }
                    meta[key] = value
                } else {
                    meta = meta.filter { normalize($0.key) != normalized }
                }
            }
            meta = meta.filter { current.contains(normalize($0.key)) }
        }
    }
}

// MARK: - 共享启动监测器

extension ProcessProbe {
    enum MonitorResult: Equatable {
        case running
        case timedOut
    }

    /// 多个启动请求共用一次 PID 快照；只在监测队列上持有请求，不缓存跨轮 PID 身份。
    /// 每轮顺序固定为：枚举一次 PID → 读启动时间 → 读 cwd → 按请求匹配身份。
    final class Monitor {
        typealias PIDLister = () -> [pid_t]
        typealias StartTimeReader = (pid_t) -> Date?
        typealias CWDReader = (pid_t) -> String?
        typealias Matcher = (String?, pid_t) -> Bool

        private struct Request {
            let id: String
            let targets: Set<String>
            let since: Date
            let expectedCommand: String?
            let deadline: Date
            let completion: (MonitorResult) -> Void
        }

        private let queue = DispatchQueue(label: "local.pi.project-launcher.process-monitor")
        private let interval: TimeInterval
        private let lister: PIDLister
        private let startTime: StartTimeReader
        private let cwd: CWDReader
        private let matches: Matcher

        private var requests: [String: Request] = [:]
        private var timer: DispatchSourceTimer?
        private var stopped = false

        init(interval: TimeInterval = 0.4,
             lister: @escaping PIDLister = { ProcessProbe.allPIDs() },
             startTime: @escaping StartTimeReader = { ProcessProbe.startTime(of: $0) },
             cwd: @escaping CWDReader = { ProcessProbe.cwd(of: $0) },
             matches: @escaping Matcher = { ProcessProbe.matches(command: $0, pid: $1) }) {
            self.interval = max(0.01, interval)
            self.lister = lister
            self.startTime = startTime
            self.cwd = cwd
            self.matches = matches
        }

        /// 立即做首检；未完成才按 interval 重试，直到完成、取消或超时。
        func add(id: String, projectPath: String, since: Date,
                 expectedCommand: String?, deadline: Date,
                 completion: @escaping (MonitorResult) -> Void) {
            let targets: Set<String> = [projectPath, ProcessProbe.canonical(projectPath)]
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.requests[id] = Request(id: id, targets: targets, since: since,
                                            expectedCommand: expectedCommand,
                                            deadline: deadline, completion: completion)
                self.tickLocked()
                self.scheduleLocked()
            }
        }

        func cancel(id: String) {
            queue.async { [weak self] in
                guard let self else { return }
                self.requests[id] = nil
                if self.requests.isEmpty { self.stopTimerLocked() }
            }
        }

        func shutdown() {
            queue.async { [weak self] in
                guard let self else { return }
                self.stopped = true
                self.requests.removeAll()
                self.stopTimerLocked()
            }
        }

        private func scheduleLocked() {
            guard !stopped, !requests.isEmpty else {
                stopTimerLocked()
                return
            }
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            let step = DispatchTimeInterval.milliseconds(max(10, Int(interval * 1000)))
            source.schedule(deadline: .now() + step, repeating: step,
                            leeway: .milliseconds(20))
            source.setEventHandler { [weak self] in self?.tickLocked() }
            timer = source
            source.resume()
        }

        private func stopTimerLocked() {
            timer?.cancel()
            timer = nil
        }

        private func tickLocked() {
            guard !stopped, !requests.isEmpty else {
                stopTimerLocked()
                return
            }

            let now = Date()
            let earliest = requests.values
                .map { $0.since.addingTimeInterval(-1) }
                .min() ?? now
            let pids = lister()

            var finished: [(String, MonitorResult)] = []
            var done = Set<String>()

            for pid in pids {
                guard let started = startTime(pid), started >= earliest else { continue }
                guard let dir = cwd(pid) else { continue }
                var identities: [String: Bool] = [:]
                for request in requests.values where !done.contains(request.id) {
                    guard started >= request.since.addingTimeInterval(-1) else { continue }
                    guard request.targets.contains(dir) else { continue }
                    if let expected = request.expectedCommand {
                        let matched: Bool
                        if let cached = identities[expected] {
                            matched = cached
                        } else {
                            matched = matches(expected, pid)
                            identities[expected] = matched
                        }
                        guard matched else { continue }
                    }
                    done.insert(request.id)
                    finished.append((request.id, .running))
                }
            }

            // 先让本轮快照里的命中完成，再处理超时：边界时刻出现的进程仍算成功。
            for (id, _) in finished {
                guard let request = requests.removeValue(forKey: id) else { continue }
                request.completion(.running)
            }
            let expired = requests.filter { now >= $0.value.deadline }.map { $0.key }
            for id in expired {
                guard let request = requests.removeValue(forKey: id) else { continue }
                request.completion(.timedOut)
            }

            if requests.isEmpty { stopTimerLocked() }
        }
    }
}
