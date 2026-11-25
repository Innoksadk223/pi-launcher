// 启动终端：以目标目录为工作目录开新窗口并运行 PI。
//
// 两款终端的差别都在这里：
//   ghostty   Ghostty 会再解析一次 command，所以路径不拼进命令，改用环境变量传递。
//   terminal  Terminal.app 没有 env 接口，路径只能进命令行，靠 Terminal.shellQuote 加引号。
//
// 两条路径：
//   open(...)        开新窗口（新会话或 --session 继续）
//   focus(...)       该项目已经在 Ghostty 里开着时，直接跳到那个窗口（只有 Ghostty 能查工作目录）
//
// NSAppleScript 按 Apple 文档必须在主线程创建、执行并读取结果。
// 生产路径使用 openStepwise：Ghostty 的 10 秒等待拆成主线程分步调度，
// 开窗脚本只提交一次。同步 open 仅保留给既有自检/端到端工具。

import Cocoa

enum Launcher {
    /// PI 可执行文件；测试时可替换为记录脚本
    static var piCommand = "pi"

    enum LaunchError: LocalizedError {
        case terminalMissing(String)
        case unsupported(String)
        case appleScript(String)
        case denied
        case timeout(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .terminalMissing(let name): return "没找到 \(name)，请在标题栏换一个终端。"
            case .unsupported(let name): return "\(name) 还不支持自动启动，请换一个终端。"
            case .appleScript(let m): return "无法在终端中打开窗口：\(m)"
            case .denied: return "系统未允许本应用控制终端。请到「系统设置 → 隐私与安全性 → 自动化」中勾选。"
            case .timeout(let m): return m
            case .cancelled: return "已取消打开终端。"
            }
        }
    }

    /// 主线程分步等待的取消标志；只影响尚未提交的开窗脚本。
    final class CancelToken {
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

    enum ExistingTerminal {
        case found(String)
        case none
        case failure(LaunchError)
    }

    enum FocusOutcome {
        case focused
        case notFound
        case failure(LaunchError)
    }

    /// sessionPath 为 nil 时开新会话；terminal 决定往哪个终端里开。
    /// 同步版本只供既有自检/端到端工具使用；生产路径用 openStepwise。
    @available(*, deprecated, message: "生产路径请用 openStepwise（主线程分步、可取消）")
    static func open(projectPath: String, sessionPath: String? = nil, terminal: Terminal.Kind) throws {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        guard Store.isDirectory(projectPath) else {
            throw LaunchError.appleScript("目标文件夹不存在。")
        }
        guard terminal.supported else { throw LaunchError.unsupported(terminal.name) }
        guard Terminal.isInstalled(terminal) else { throw LaunchError.terminalMissing(terminal.name) }

        switch terminal.id {
        case "ghostty":
            // sessionPath 为 nil 时命令与既有实现逐字一致（打开新会话）
            try run(appleScript(projectPath: projectPath, sessionPath: sessionPath))
        case "terminal":
            try run(terminalScript(projectPath: projectPath, sessionPath: sessionPath))
        default:
            // 标了 supported 却没写分支：宁可报错，也不能拿 Ghostty 的脚本去开别的终端
            throw LaunchError.unsupported(terminal.name)
        }
    }

    /// 生产路径：校验在主线程完成；Ghostty 未运行时分步等待，可取消，
    /// 只有确认 running 后才提交一次开窗脚本。Terminal 只提交一次 do script。
    static func openStepwise(projectPath: String, sessionPath: String? = nil,
                             terminal: Terminal.Kind, token: CancelToken,
                             completion: @escaping (Result<Void, LaunchError>) -> Void) {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        guard Store.isDirectory(projectPath) else {
            completion(.failure(.appleScript("目标文件夹不存在。")))
            return
        }
        guard terminal.supported else {
            completion(.failure(.unsupported(terminal.name)))
            return
        }
        guard Terminal.isInstalled(terminal) else {
            completion(.failure(.terminalMissing(terminal.name)))
            return
        }
        switch terminal.id {
        case "ghostty":
            openGhosttyStepwise(projectPath: projectPath, sessionPath: sessionPath,
                                token: token, completion: completion)
        case "terminal":
            do {
                try run(terminalScript(projectPath: projectPath, sessionPath: sessionPath))
                completion(.success(()))
            } catch let error as LaunchError {
                completion(.failure(error))
            } catch {
                completion(.failure(.appleScript(error.localizedDescription)))
            }
        default:
            completion(.failure(.unsupported(terminal.name)))
        }
    }

    /// 该项目是否已经有一个 Ghostty 终端停在它上面。
    /// 明确查不到与查询失败分开：失败（拒绝/超时/未知）由调用方报告，不拿它当“没找到”去盲目开窗。
    static func existingTerminalResult(for projectPath: String) -> ExistingTerminal {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        let script = """
        if not (application "Ghostty" is running) then return ""
        tell application "Ghostty"
            set out to ""
            set failedCount to 0
            repeat with t in terminals
                try
                    set wid to id of t
                    set wdir to working directory of t
                    if wid is missing value or wdir is missing value then error "missing window field"
                    set out to out & "T\\t" & wid & "\\t" & wdir & "\\n"
                on error
                    set failedCount to failedCount + 1
                end try
            end repeat
            if failedCount > 0 then set out to out & "E\\t" & failedCount & "\\n"
            return out
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.appleScript("无法创建 AppleScript"))
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -600 { return .none }   // Ghostty 没运行：明确没有窗口
            return .failure(launchError(from: info))
        }
        // stringValue 可能为 nil（结果不是字符串）或格式无法解析；这属于查询失败，
        // 不能当成“明确没有窗口”去触发回落开窗。
        guard let text = result.stringValue else {
            return .failure(.appleScript("无法读取终端窗口列表"))
        }
        return classifyExistingTerminalOutput(text, target: projectPath)
    }

    /// 纯解析：T 行是可靠的窗口记录，E 行表示至少一个终端字段读取失败，
    /// 其它非空行表示畸形。找到可靠匹配仍返回 found；无匹配但有未知/畸形项则失败。
    static func classifyExistingTerminalOutput(_ text: String, target projectPath: String)
        -> ExistingTerminal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .none }
        // 与 ProcessProbe 用同一套规范化：Ghostty 报的是物理路径，standardized 解不开 /tmp 这类顶层链接
        let target = ProcessProbe.canonical(projectPath)
        var hasUnknown = false
        var hasMalformed = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "T" {
                guard !parts[1].isEmpty, parts[2].hasPrefix("/") else {
                    hasMalformed = true
                    continue
                }
                let dirText = String(parts[2]).trimmingCharacters(in: .newlines)
                let dir = ProcessProbe.canonical(dirText)
                if dir == target { return .found(String(parts[1])) }
            } else if parts.count == 2, parts[0] == "E" {
                hasUnknown = true
            } else {
                hasMalformed = true
            }
        }
        if hasUnknown || hasMalformed {
            return .failure(.appleScript("部分终端窗口信息无法读取，未确认是否已有窗口。"))
        }
        // 非空且只有完整 T 行但没有匹配：明确没有该项目的窗口。
        return .none
    }

    /// 旧调用兼容：查询失败仍返回 nil（生产路径改用 existingTerminalResult）。
    @available(*, deprecated, message: "生产路径请用 existingTerminalResult 保留失败分类")
    static func existingTerminal(for projectPath: String) -> String? {
        if case .found(let id) = existingTerminalResult(for: projectPath) { return id }
        return nil
    }

    /// 切到已经开着的那个窗口。明确没找到与查询失败分开：后者不触发回落开窗。
    static func focusOutcome(terminalID: String, for projectPath: String) -> FocusOutcome {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        let script = """
        tell application "Ghostty"
            repeat with t in terminals
                if (id of t) is "\(terminalID)" then
                    focus t
                    activate
                    return "ok"
                end if
            end repeat
            return ""
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.appleScript("无法创建 AppleScript"))
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if number == -600 { return .notFound }
            return .failure(launchError(from: info))
        }
        guard let value = result.stringValue else {
            return .failure(.appleScript("无法读取聚焦结果"))
        }
        if value == "ok" { return .focused }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .notFound }
        return .failure(.appleScript("聚焦返回了意外结果：\(value)"))
    }

    /// 旧调用兼容：找不到时抛错，未知失败也抛错。
    @available(*, deprecated, message: "生产路径请用 focusOutcome 保留失败分类")
    static func focus(terminalID: String, for projectPath: String) throws {
        switch focusOutcome(terminalID: terminalID, for: projectPath) {
        case .focused: return
        case .notFound: throw LaunchError.appleScript("那个窗口已经不在了")
        case .failure(let error): throw error
        }
    }

    // ── 内部 ──────────────────────────────────────────

    private static func run(_ source: String) throws {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        guard let appleScript = NSAppleScript(source: source) else {
            throw LaunchError.appleScript("无法创建 AppleScript")
        }
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        if let info = errorInfo { throw launchError(from: info) }
    }

    private static func launchError(from info: NSDictionary) -> LaunchError {
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "未知错误"
        // -1743：用户未授权自动化；-1712：AppleEvent 超时；-600：应用没运行
        if number == -1743 { return .denied }
        if number == -1712 { return .timeout("终端响应超时：\(message)") }
        return .appleScript("\(message)（\(number)）")
    }

    private static func ghosttyRunning() -> Result<Bool, LaunchError> {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        // 不用 tell 查询，避免仅仅检测就把 Ghostty 启动起来。
        let script = """
        return (application "Ghostty" is running)
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(.appleScript("无法创建 AppleScript"))
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let info = errorInfo { return .failure(launchError(from: info)) }
        // booleanValue 是非可选 Bool；不要对它用 optional binding。
        return .success(result.booleanValue)
    }

    private static func launchGhostty() -> Result<Void, LaunchError> {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        do {
            try run("tell application \"Ghostty\" to launch")
            return .success(())
        } catch let error as LaunchError {
            return .failure(error)
        } catch {
            return .failure(.appleScript(error.localizedDescription))
        }
    }

    private static func openGhosttyStepwise(projectPath: String, sessionPath: String?,
                                            token: CancelToken,
                                            completion: @escaping (Result<Void, LaunchError>) -> Void) {
        switch ghosttyRunning() {
        case .failure(let error):
            completion(.failure(error))
        case .success(true):
            guard !token.isCancelled else {
                completion(.failure(.cancelled))
                return
            }
            submitGhostty(projectPath: projectPath, sessionPath: sessionPath,
                          completion: completion)
        case .success(false):
            switch launchGhostty() {
            case .failure(let error):
                completion(.failure(error))
            case .success(_):
                // launch 只提交一次；之后只查 running，不再重复提交开窗/命令。
                waitForGhostty(projectPath: projectPath, sessionPath: sessionPath,
                               token: token, attempt: 0, deadline: Date().addingTimeInterval(10),
                               completion: completion)
            }
        }
    }

    private static func waitForGhostty(projectPath: String, sessionPath: String?,
                                       token: CancelToken, attempt: Int, deadline: Date,
                                       completion: @escaping (Result<Void, LaunchError>) -> Void) {
        if token.isCancelled {
            completion(.failure(.cancelled))
            return
        }
        if attempt >= 40 || Date() >= deadline {
            completion(.failure(.timeout("Ghostty 在 10 秒内没有启动，未开窗。")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if token.isCancelled {
                completion(.failure(.cancelled))
                return
            }
            switch ghosttyRunning() {
            case .failure(let error):
                completion(.failure(error))
            case .success(true):
                guard !token.isCancelled else {
                    completion(.failure(.cancelled))
                    return
                }
                submitGhostty(projectPath: projectPath, sessionPath: sessionPath,
                              completion: completion)
            case .success(false):
                waitForGhostty(projectPath: projectPath, sessionPath: sessionPath,
                               token: token, attempt: attempt + 1, deadline: deadline,
                               completion: completion)
            }
        }
    }

    private static func submitGhostty(projectPath: String, sessionPath: String?,
                                      completion: @escaping (Result<Void, LaunchError>) -> Void) {
        assert(Thread.isMainThread, "NSAppleScript 只能在主线程执行")
        do {
            try run(ghosttySubmitScript(projectPath: projectPath, sessionPath: sessionPath))
            completion(.success(()))
        } catch let error as LaunchError {
            completion(.failure(error))
        } catch {
            completion(.failure(.appleScript(error.localizedDescription)))
        }
    }

    /// 确认 Ghostty 已运行后才执行；不含固定 40×0.25 等待，因此不会卡主线程 10 秒。
    /// 开窗与命令各只出现一次。
    private static func ghosttySubmitScript(projectPath: String, sessionPath: String? = nil) -> String {
        var variables = "{\"PI_PROJECT_DIR=\" & \(asLiteral(projectPath)), \"PI_BIN=\" & \(asLiteral(piCommand))}"
        var command = #""/bin/zsh -lc 'cd \"$PI_PROJECT_DIR\" || exit 1; exec \"$PI_BIN\"'""#
        if let sessionPath {
            variables = "{\"PI_PROJECT_DIR=\" & \(asLiteral(projectPath)), \"PI_BIN=\" & \(asLiteral(piCommand)), \"PI_SESSION=\" & \(asLiteral(sessionPath))}"
            command = #""/bin/zsh -lc 'cd \"$PI_PROJECT_DIR\" || exit 1; exec \"$PI_BIN\" --session \"$PI_SESSION\"'""#
        }
        return """
        tell application "Ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to \(asLiteral(projectPath))
            set environment variables of cfg to \(variables)
            set command of cfg to \(command)
            set wait after command of cfg to true
            new window with configuration cfg
            activate
        end tell
        """
    }

    /// Terminal.app 版本：没有环境变量接口，路径只能进命令行。
    /// 命令还是经 /bin/zsh -lc 起来，和 Ghostty 那条一样拿到登录 shell 的 PATH。
    static func terminalScript(projectPath: String, sessionPath: String? = nil) -> String {
        let line = "/bin/zsh -lc " + Terminal.shellQuote(
            Terminal.command(projectPath: projectPath, sessionPath: sessionPath, piCommand: piCommand)
        )
        return """
        tell application "Terminal"
            do script \(asLiteral(line))
            activate
        end tell
        """
    }

    /// 生成 Ghostty 用的 AppleScript。command 里只出现环境变量引用，路径一律经 environment variables 传递。
    /// command 已是 AppleScript 字面量（内含 \"），必须原样注入，不能再转义一次。
    static func appleScript(projectPath: String, sessionPath: String? = nil) -> String {
        var variables = "{\"PI_PROJECT_DIR=\" & \(asLiteral(projectPath)), \"PI_BIN=\" & \(asLiteral(piCommand))}"
        var command = #""/bin/zsh -lc 'cd \"$PI_PROJECT_DIR\" || exit 1; exec \"$PI_BIN\"'""#
        if let sessionPath {
            variables = "{\"PI_PROJECT_DIR=\" & \(asLiteral(projectPath)), \"PI_BIN=\" & \(asLiteral(piCommand)), \"PI_SESSION=\" & \(asLiteral(sessionPath))}"
            command = #""/bin/zsh -lc 'cd \"$PI_PROJECT_DIR\" || exit 1; exec \"$PI_BIN\" --session \"$PI_SESSION\"'""#
        }

        return """
        tell application "Ghostty"
            if not running then launch
            repeat 40 times
                if running then exit repeat
                delay 0.25
            end repeat
            set cfg to new surface configuration
            set initial working directory of cfg to \(asLiteral(projectPath))
            set environment variables of cfg to \(variables)
            set command of cfg to \(command)
            set wait after command of cfg to true
            new window with configuration cfg
            activate
        end tell
        """
    }

    /// 转成 AppleScript 字符串字面量
    static func asLiteral(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            // AppleScript 的字符串字面量里换行会把语句截断，路径里真有也按字面拼回去
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\n")
        return "\"\(escaped)\""
    }
}
