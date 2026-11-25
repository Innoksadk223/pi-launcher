// 渲染验证：用与 App 相同的 WebKit 加载界面，注入模拟数据，多宽度截图。
// 用法：swiftc -O -parse-as-library -o /tmp/shot tools/shot.swift && /tmp/shot <ui目录> <输出目录> [day|night]
// 昼夜各跑一遍，夜里那组的文件名带 -night 后缀。
import Cocoa
import WebKit

@main
struct Shot {
    static func main() {
        let args = CommandLine.arguments
        let uiDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "ui")
        let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/shots")
        let theme = args.count > 3 && args[3] == "night" ? "night" : "day"
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(uiDir: uiDir, outDir: outDir, theme: theme)
        app.delegate = delegate
        app.run()
    }
}

final class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let uiDir: URL
    let outDir: URL
    let theme: String
    var window: NSWindow!
    var web: WKWebView!
    var shots: [(String, CGSize, String?)] = []
    var index = 0
    var finished = 0
    var current: (String, CGSize, String?)?

    // 覆盖各种边界：长路径、中文、空格、单引号、失效路径、无会话、多会话
    let now = Date().timeIntervalSince1970 * 1000
    lazy var payload: [String: Any] = [
        "home": "/Users/you",
        "status": "就绪",
        // 与原生检测结果同形：已装的两款可造，未适配的灰着
        "terminals": [
            ["id": "ghostty", "name": "Ghostty", "note": "", "supported": true, "selected": true],
            ["id": "terminal", "name": "Terminal", "note": "系统自带", "supported": true, "selected": false],
            ["id": "iterm", "name": "iTerm2", "note": "", "supported": false, "selected": false]
        ],
        "projects": [
            ["id": "/Users/you/projects/tools", "path": "/Users/you/projects/tools",
             "favorite": true, "missing": false,
             "sessionCount": 21, "lastActivity": now - 2 * 3600 * 1000],
            ["id": "/Users/you/projects/我的项目/",
             "path": "/Users/you/projects/我的项目/",
             "favorite": true, "missing": false,
             "sessionCount": 41, "lastActivity": now - 3 * 86400 * 1000],
            ["id": "/Users/you/.pi", "path": "/Users/you/.pi",
             "favorite": false, "missing": false,
             "sessionCount": 104, "lastActivity": now - 8 * 86400 * 1000],
            ["id": "/Users/you/projects/一个很长的中文项目目录名称用来测试截断行为是否正常",
             "path": "/Users/you/projects/一个很长的中文项目目录名称用来测试截断行为是否正常",
             "favorite": false, "missing": false,
             "sessionCount": 3, "lastActivity": now - 16 * 86400 * 1000],
            ["id": "/Users/you/projects/demo-site", "path": "/Users/you/projects/demo-site",
             "favorite": false, "missing": false, "sessionCount": 0],
            ["id": "/Users/you/projects/已删除的项目", "path": "/Users/you/projects/已删除的项目",
             "favorite": false, "missing": true]
        ]
    ]

    lazy var historyPayload: [String: Any] = [
        "project": "/Users/you/projects/tools",
        "ticket": 1,
        "sessions": [
            ["path": "/a.jsonl", "title": "用液态玻璃与 ios 审美制作 gpt6.1sol 宣传页", "modified": now - 3600 * 1000, "messageCount": 105],
            ["path": "/b.jsonl", "title": "创建一个 HTML，内容是 SVG 绘制一个鹈鹕骑自行车的 2D 动画。", "modified": now - 2 * 3600 * 1000, "messageCount": 41],
            ["path": "/c.jsonl", "title": "创建一个HTML，内容是SVG绘制一个鹈鹕骑自行车的2D动画，你不需要任何测试。", "modified": now - 3 * 3600 * 1000, "messageCount": 102],
            ["path": "/d.jsonl", "title": "将这部分的内容挑选出其中的几部分，形成一个skill。 判定：词表出现即处理", "modified": now - 14 * 86400 * 1000, "messageCount": 140],
            ["path": "/e.jsonl", "title": "将这部分的内容挑选出其中的几部分，形成一个skill。 判定：词表出现即处理", "modified": now - 14 * 86400 * 1000, "messageCount": 216],
            ["path": "/f.jsonl", "title": "问一下 当使用 plannatator 后出现了计划，我进行一些调整", "modified": now - 20 * 86400 * 1000, "messageCount": 131]
        ]
    ]

    init(uiDir: URL, outDir: URL, theme: String) {
        self.uiDir = uiDir
        self.outDir = outDir
        self.theme = theme
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shots = [
            ("projects-820", CGSize(width: 820, height: 660), nil),
            ("projects-560", CGSize(width: 560, height: 660), nil),
            ("projects-390", CGSize(width: 390, height: 700), nil),
            ("history-820", CGSize(width: 820, height: 660), "history"),
            ("search-820", CGSize(width: 820, height: 660), "search"),
            ("empty-820", CGSize(width: 820, height: 660), "empty")
        ]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        web = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        window.setFrame(NSRect(x: 0, y: 0, width: 820, height: 660), display: true)
        window.makeKeyAndOrderFront(nil)
        // 首次加载也要有 current，didFinish 才知道该渲染哪一张
        current = shots[0]
        index = 1
        web.loadFileURL(uiDir.appendingPathComponent("index.html"), allowingReadAccessTo: uiDir)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 每张截图都从「干净加载」开始：上一次点击留下的历史页状态要清掉
        guard let (name, _, mode) = current else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.web.evaluateJavaScript(self.script(for: mode)) { _, err in
                if let err { print("注入失败 \(name): \(err)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let file = name + (self.theme == "night" ? "-night" : "") + ".png"
                    WebBridge.snap(self.window, to: self.outDir.appendingPathComponent(file)) { ok in
                        if ok { self.finished += 1 }
                        self.renderNext()
                    }
                }
            }
        }
    }

    func renderNext() {
        guard index < shots.count else {
            print("完成 \(finished) 张")
            NSApp.terminate(nil)
            return
        }
        let shot = shots[index]
        index += 1
        current = shot
        window.setFrame(NSRect(x: 0, y: 0, width: shot.1.width, height: shot.1.height), display: true)
        web.loadFileURL(uiDir.appendingPathComponent("index.html"), allowingReadAccessTo: uiDir)
    }

    func script(for mode: String?) -> String {
        func json(_ object: Any) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        // 主题先定：页面首帧已经设过 data-theme，这里覆盖成截图要的那一套，
        // 同时清掉可能残留的手动选择，避免两次跑图相互污染。
        let themed = { (body: String) -> String in
            "document.documentElement.dataset.theme = '\(self.theme)';" +
            "try { localStorage.setItem('pi.launcher.theme', '\(self.theme)'); } catch (e) {}" +
            body
        }
        switch mode {
        case "history":
            // 先把数据推给界面，再点「历史」；否则会停在「正在读取…」那一帧
            return themed("""
            window.__render(\(json(payload)));
            document.querySelector('.cell__sessions').click();
            window.__history(\(json(historyPayload)));
            """)
        case "search":
            return themed("""
            window.__render(\(json(payload)));
            var q=document.getElementById('q'); q.value='我的项目'; q.dispatchEvent(new Event('input'));
            """)
        case "empty":
            return themed("""
            window.__render(\(json(payload)));
            var q=document.getElementById('q'); q.value='zzzz'; q.dispatchEvent(new Event('input'));
            """)
        default:
            return themed("window.__render(\(json(payload)));")
        }
    }
}

enum WebBridge {

    /// 用 ScreenCaptureKit 截窗口（CGWindowListCreateImage 在 macOS 15+ 已不可用）
    static func snap(_ window: NSWindow, to url: URL, done: @escaping (Bool) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let win = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    print("找不到窗口 \(url.lastPathComponent)"); done(false); return
                }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(win.frame.width * 2)
                cfg.height = Int(win.frame.height * 2)
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg)
                let rep = NSBitmapImageRep(cgImage: img)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("✓ \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                done(true)
            } catch {
                print("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                done(false)
            }
        }
    }
}

import ScreenCaptureKit
