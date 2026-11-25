// 终端选择：哪些终端能用来开 PI、哪些只是「装了但没适配」。
//
// 只给差异最小的两款写适配：Ghostty 和系统 Terminal，都真实开机验过。
// 其它常见终端只做检测——装了会出现在菜单里并标「未适配」，不照文档编造可用性。
//
// 命令拼接（shellQuote / command）是纯函数：Terminal.app 没有环境变量接口，
// 路径只能进命令行，所以引号必须能反解回原文，自检里逐条验。

import Cocoa

enum Terminal {
    /// 一款终端。supported = 已经适配（能真的开窗跑 PI）。
    struct Kind {
        let id: String
        let name: String
        /// 菜单里跟在名字后面的灰色小字，比如「系统自带」
        let note: String
        let bundleID: String
        let paths: [String]
        let supported: Bool

        /// 「已经在这个目录里开着就切过去」只有 Ghostty 能做到：
        /// Terminal.app 的 tab 没有工作目录属性（见 Terminal.sdef），查不到。
        var supportsRefocus: Bool { id == "ghostty" }
    }

    /// 已知终端表，顺序即菜单顺序
    static let known: [Kind] = [
        Kind(id: "ghostty", name: "Ghostty", note: "",
             bundleID: "com.mitchellh.ghostty",
             paths: ["/Applications/Ghostty.app", "~/Applications/Ghostty.app"],
             supported: true),
        Kind(id: "terminal", name: "Terminal", note: "系统自带",
             bundleID: "com.apple.Terminal",
             paths: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"],
             supported: true),

        // 以下只检测，不提供启动
        Kind(id: "iterm", name: "iTerm2", note: "",
             bundleID: "com.googlecode.iterm2",
             paths: ["/Applications/iTerm.app", "~/Applications/iTerm.app"],
             supported: false),
        Kind(id: "warp", name: "Warp", note: "",
             bundleID: "dev.warp.Warp-Stable",
             paths: ["/Applications/Warp.app"],
             supported: false),
        Kind(id: "kitty", name: "kitty", note: "",
             bundleID: "net.kovidgoyal.kitty",
             paths: ["/Applications/kitty.app", "~/Applications/kitty.app"],
             supported: false),
        Kind(id: "wezterm", name: "WezTerm", note: "",
             bundleID: "com.github.wez.wezterm",
             paths: ["/Applications/WezTerm.app"],
             supported: false),
        Kind(id: "alacritty", name: "Alacritty", note: "",
             bundleID: "org.alacritty",
             paths: ["/Applications/Alacritty.app"],
             supported: false),
        Kind(id: "hyper", name: "Hyper", note: "",
             bundleID: "co.zeit.hyper",
             paths: ["/Applications/Hyper.app"],
             supported: false),
        Kind(id: "tabby", name: "Tabby", note: "",
             bundleID: "org.tabby",
             paths: ["/Applications/Tabby.app"],
             supported: false)
    ]

    /// 没存过选、或存的终端不能用时，按这个顺序挑第一个能用的
    static let fallbackOrder = ["ghostty", "terminal"]

    static func kind(id: String) -> Kind? { known.first { $0.id == id } }

    // ── 检测 ──────────────────────────────────────────

    /// 已安装的终端，保持 known 的顺序。probe 可注入，自检里用来造各种状态。
    static func installed(_ probe: (Kind) -> Bool = isInstalled) -> [Kind] {
        known.filter(probe)
    }

    /// 先问 Launch Services（认得出装在任意位置的那份），再逐个试常见路径
    static func isInstalled(_ kind: Kind) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) != nil {
            return true
        }
        return kind.paths.contains { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// 实际该用哪款。selected 没装 / 未适配 / 为空时按 fallbackOrder 找一个能用的。
    /// fellBack = 存的选项没用了，调用方据此在底栏说明一句。
    static func resolve(selected: String?, available: [Kind]) -> (kind: Kind?, fellBack: Bool) {
        if let selected, let match = available.first(where: { $0.id == selected && $0.supported }) {
            return (match, false)
        }
        for id in fallbackOrder {
            if let match = available.first(where: { $0.id == id && $0.supported }) {
                return (match, selected != nil)
            }
        }
        return (available.first { $0.supported }, selected != nil)
    }

    // ── 偏好落盘 ──────────────────────────────────────
    // 和 projects.txt 同目录、同样「文件不在就是默认值」。

    static var preferenceURL: URL {
        Store.defaultFileURL.deletingLastPathComponent().appendingPathComponent("terminal.txt")
    }

    static func savedSelection(from url: URL = preferenceURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    @discardableResult
    static func saveSelection(_ id: String, to url: URL = preferenceURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data((id + "\n").utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // ── 命令行拼装（纯函数）────────────────────────────

    /// POSIX 单引号引起来：整段包进 '…'，内部的 ' 写成 '\''。
    static func shellQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 交给 shell 的一行：先 cd 进项目，再 exec 成 pi，退出时不留一层 shell。
    /// sessionPath 有值时追加 --session，路径同样引起来。
    static func command(projectPath: String, sessionPath: String?, piCommand: String) -> String {
        var line = "cd \(shellQuote(projectPath)) && exec \(shellQuote(piCommand))"
        if let sessionPath {
            line += " --session \(shellQuote(sessionPath))"
        }
        return line
    }
}
