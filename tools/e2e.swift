// 端到端验证：调用应用内 Launcher，确认终端执行了固定目录/会话参数。
// 用法：swiftc -O -o /tmp/e2e tools/e2e.swift src/Store.swift src/SessionHistory.swift src/Launcher.swift src/Terminal.swift src/ProcessProbe.swift
//       /tmp/e2e [ghostty|terminal] [new|continue] [--keep]
// 只使用本次新建的唯一临时目录、独占回执与可核验的本轮进程身份；不关闭任何用户已有窗口。
// 发送信号后不自动删除 workspace，只打印 CLEANUP-PENDING 供后续确认无占用后手动清理。
// --keep 保留测试进程约 120 秒（至少 60 秒可观察），并由脚本写 heartbeat.txt；不关闭窗口。
// 记录脚本只能证明启动器/终端命令链路，不能证明真实 PI 或真实 App 关闭重开。
import Cocoa

@main
struct E2E {
    static func main() {
        let args = CommandLine.arguments
        let terminalID = args.count > 1 && !args[1].hasPrefix("--") ? args[1] : "ghostty"
        let mode = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : "new"
        let keep = args.contains("--keep")
        guard mode == "new" || mode == "continue" else {
            print("FAIL mode 只能是 new 或 continue")
            exit(1)
        }
        guard let terminal = Terminal.kind(id: terminalID) else {
            print("FAIL 未知终端：\(terminalID)")
            exit(1)
        }

        let fm = FileManager.default
        let round = UUID().uuidString
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pi 启动器 e2e '\(round)' 中文 空格", isDirectory: true)
        let targetDir = workspace.appendingPathComponent("项目 目录 '单引号'", isDirectory: true)
        let receiptURL = workspace.appendingPathComponent("receipt 回执.txt")
        let heartbeatURL = workspace.appendingPathComponent("heartbeat 心跳.txt")
        let sessionURL = workspace.appendingPathComponent("session 会话.jsonl")
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try? "fixture session\n".write(to: sessionURL, atomically: true, encoding: .utf8)

        let fakePi = targetDir.appendingPathComponent("fake pi '\(round)'.bin")
        let receipt = Terminal.shellQuote(receiptURL.path)
        let heartbeat = Terminal.shellQuote(heartbeatURL.path)
        let script = """
        #!/bin/zsh
        set -u
        trap 'exit 0' TERM INT
        receipt=\(receipt)
        heartbeat=\(heartbeat)
        tmp="${receipt}.tmp.$$"
        {
          echo "round=\(round)"
          echo "pid=$$"
          echo "script=$0"
          echo "cwd=$(/bin/pwd -P)"
          i=0
          for arg in "$@"; do
            echo "arg$i=$arg"
            i=$((i+1))
          done
          echo "argc=$#"
        } > "$tmp"
        /bin/mv -f "$tmp" "$receipt"
        i=0
        while [ "$i" -lt 24 ]; do
          i=$((i+1))
          htmp="${heartbeat}.tmp.$$"
          {
            echo "epoch=$(/bin/date +%s)"
            echo "pid=$$"
          } > "$htmp"
          /bin/mv -f "$htmp" "$heartbeat"
          /bin/sleep 5
        done
        """
        try? script.write(to: fakePi, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi.path)

        // 与 App 中一致：把 pi 换成记录脚本；路径和脚本名本轮唯一。
        Launcher.piCommand = fakePi.path
        let launchStartedAt = Date()
        let expectedCWD = ProcessProbe.canonical(targetDir.path)

        func terminalWindowIDs() -> Set<Int> {
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
                return []
            }
            let owner = terminal.id == "terminal" ? "Terminal" : terminal.name
            var ids = Set<Int>()
            for item in list where (item[kCGWindowOwnerName as String] as? String) == owner {
                if let number = item[kCGWindowNumber as String] as? Int { ids.insert(number) }
            }
            return ids
        }

        func isRoundProcess(_ pid: pid_t, start: Date?) -> Bool {
            guard pid > 0, let expectedStart = start,
                  let currentStart = ProcessProbe.startTime(of: pid),
                  currentStart == expectedStart,
                  let cwd = ProcessProbe.cwd(of: pid),
                  ProcessProbe.canonical(cwd) == expectedCWD,
                  ProcessProbe.matches(command: fakePi.path, pid: pid) else {
                return false
            }
            return true
        }

        let beforeIDs = terminalWindowIDs()
        print("终端: \(terminal.name)")
        print("模式: \(mode)")
        print("唯一测试目录: \(targetDir.path)")
        print("回执: \(receiptURL.path)")
        print("心跳/保留证据: \(heartbeatURL.path)")

        let token = Launcher.CancelToken()
        var launchResult: Result<Void, Launcher.LaunchError>?
        Launcher.openStepwise(projectPath: targetDir.path,
                              sessionPath: mode == "continue" ? sessionURL.path : nil,
                              terminal: terminal, token: token) { result in
            launchResult = result
        }
        let launchDeadline = Date().addingTimeInterval(12)
        while launchResult == nil && Date() < launchDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if let result = launchResult {
            switch result {
            case .success(_):
                print("Launcher.openStepwise 返回成功（只代表命令已提交，不代表 PI 可输入）")
            case .failure(let error):
                token.cancel()
                print("FAIL Launcher.openStepwise: \(error.localizedDescription)")
                print("保留 workspace 与证据：\(workspace.path)")
                exit(1)
            }
        } else {
            token.cancel()
            print("FAIL Launcher.openStepwise 12 秒内未返回，已取消未提交等待")
            print("保留 workspace 与证据：\(workspace.path)")
            exit(1)
        }

        var recorded: String?
        for _ in 0..<24 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let value = try? String(contentsOf: receiptURL, encoding: .utf8), !value.isEmpty {
                recorded = value
                break
            }
        }
        guard let recorded else {
            token.cancel()
            print("FAIL 未发布完整独占回执（命令未执行、终端未开窗或回执仍在写）")
            print("保留 workspace 与证据：\(workspace.path)")
            exit(1)
        }

        var fields: [String: String] = [:]
        var argv: [String] = []
        for line in recorded.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            fields[key] = value
            if key.hasPrefix("arg"), let index = Int(key.dropFirst(3)) {
                while argv.count <= index { argv.append("") }
                argv[index] = value
            }
        }
        guard fields["round"] == round,
              let pidText = fields["pid"], let pid = pid_t(pidText), pid > 0,
              let scriptField = fields["script"],
              ProcessProbe.canonical(scriptField) == ProcessProbe.canonical(fakePi.path),
              let cwdField = fields["cwd"],
              ProcessProbe.canonical(cwdField) == expectedCWD,
              let argcText = fields["argc"], let argc = Int(argcText),
              argc == argv.count else {
            token.cancel()
            print("FAIL 独占回执不完整或身份字段不符")
            print("保留 workspace 与证据：\(workspace.path)")
            exit(1)
        }

        guard let observedStart = ProcessProbe.startTime(of: pid),
              observedStart >= launchStartedAt.addingTimeInterval(-1),
              isRoundProcess(pid, start: observedStart) else {
            token.cancel()
            print("FAIL 无法用内核启动时间/cwd/本轮唯一脚本确认 PID 归属，不发送信号")
            print("保留 workspace 与证据：\(workspace.path)")
            exit(1)
        }

        let afterIDs = terminalWindowIDs()
        let newIDs = afterIDs.subtracting(beforeIDs).sorted()

        var ok = true
        let actualCWD = ProcessProbe.canonical(fields["cwd"] ?? "")
        if actualCWD == expectedCWD {
            print("PASS 工作目录：\(actualCWD)")
        } else {
            print("FAIL 工作目录：期望 \(expectedCWD)，实际 \(actualCWD.isEmpty ? "无" : actualCWD)")
            ok = false
        }

        if mode == "continue" {
            if argv.count == 2, argv[0] == "--session",
               ProcessProbe.canonical(argv[1]) == ProcessProbe.canonical(sessionURL.path) {
                print("PASS 继续参数：--session \(argv[1])")
            } else {
                print("FAIL 继续参数不符：\(argv)")
                ok = false
            }
        } else if argv.isEmpty {
            print("PASS 新会话未带 --session")
        } else {
            print("FAIL 新会话出现多余参数：\(argv)")
            ok = false
        }

        if isRoundProcess(pid, start: observedStart) {
            print("PASS 本轮进程身份：pid=\(pid)，start=\(observedStart.timeIntervalSince1970)，cwd=\(actualCWD)")
        } else {
            print("FAIL 本轮进程身份在读取回执后发生变化")
            ok = false
        }

        if newIDs.isEmpty {
            print("WARN 未观察到新的终端窗口 ID（Terminal 可能新开 tab 或窗口不在屏上）；窗口差集只作观察")
        } else {
            print("OBSERVE 新增终端窗口 ID：\(newIDs)（仅观察，不用于归属判定，也不关闭任何窗口）")
        }

        if !ok {
            print("保留 workspace 与证据，不发送信号：\(workspace.path)")
            exit(1)
        }

        if keep {
            print("KEEP 本轮测试进程保留约 120 秒，pid=\(pid)")
            print("      脚本每 5 秒更新 \(heartbeatURL.path)；CLI 退出后存活不等于真实 App 关闭重开或真实 PI 验证。")
            print("      不发送信号，不删除 workspace。")
            exit(0)
        }

        // 发送任何信号前再次核验归属；无法证明就保留证据。
        guard isRoundProcess(pid, start: observedStart) else {
            print("FAIL 发送信号前无法重验 PID 归属，不发送信号、不删除目录")
            print("保留 workspace 与证据：\(workspace.path)")
            exit(1)
        }
        print("SIGNAL SIGTERM -> pid=\(pid)（已重验内核启动时间、cwd、本轮唯一脚本）")
        let signalResult = kill(pid, SIGTERM)
        if signalResult != 0 {
            print("WARN SIGTERM 发送失败；不对退出/占用作推断，不删除目录")
        }
        let cleanupURL = workspace.appendingPathComponent("cleanup-pending.txt")
        let cleanupRecord = """
        pid=\(pid)
        start=\(observedStart.timeIntervalSince1970)
        cwd=\(actualCWD)
        script=\(fakePi.path)
        signal=\(signalResult == 0 ? "sent" : "failed")
        exit=unknown
        cleanup=pending
        workspace=\(workspace.path)
        """
        try? cleanupRecord.write(to: cleanupURL, atomically: true, encoding: .utf8)
        print("POST-SIGNAL 不推断完整进程树已退出，也不自动删除 workspace")
        print("CLEANUP-PENDING workspace=\(workspace.path) pid=\(pid) start=\(observedStart.timeIntervalSince1970) cwd=\(actualCWD)")
        print("      身份/信号/退出状态已写入 \(cleanupURL.path)；请后续验收确认无占用后手动清理。")
        print(ok ? "E2E PASS（记录脚本；workspace 保留待清理，不代表真实 PI 可输入或真实 App 关闭重开）" : "E2E FAIL")
        exit(ok && signalResult == 0 ? 0 : 1)
    }
}
