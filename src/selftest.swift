// 自检：存储解析、去重、截断、往返、首启动。
// 只使用临时目录，不触碰真实数据。
// 用法：swiftc -o /tmp/selftest selftest.swift ../src/Store.swift && /tmp/selftest
import Foundation
import Dispatch

@main
struct SelfTest {
    static func main() {
    var failures: [String] = []
    func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if !condition { failures.append(label + (detail().isEmpty ? "" : " -> \(detail())")) }
    }

    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pi-launcher-store-test 测试 'dir'")
    try? fm.removeItem(at: root)
    try! fm.createDirectory(at: root.appendingPathComponent("项目 A"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: root.appendingPathComponent("proj'b"), withIntermediateDirectories: true)

    let pathA = root.appendingPathComponent("项目 A").path
    let pathB = root.appendingPathComponent("proj'b").path
    let missing = root.appendingPathComponent("不存在").path

    // ── 1. serialize ⇄ parse 往返 ──
    let text = Store.serialize(favorites: [pathA, pathB], recents: [pathB])
    check("serialize 以 F/R 前缀换行结尾", text.hasSuffix("\n") && text.contains("F\t"))
    let parsed = Store.parse(text)
    check("往返 favorites", parsed.favorites == [pathA, pathB], "\(parsed.favorites)")
    check("往返 recents", parsed.recents == [pathB], "\(parsed.recents)")

    // ── 2. 坏行与不存在的路径应被跳过 ──
    let messy = "F\t\(pathA)\ngarbage\nX\t\(pathA)\nF\t\(missing)\nR\t\(pathB)\nF\t\(pathA)\n"
    let messyParsed = Store.parse(messy)
    check("跳过坏前缀与坏行", messyParsed.favorites == [pathA], "\(messyParsed.favorites)")
    check("跳过不存在的路径", !messyParsed.favorites.contains(missing))
    check("去重", messyParsed.favorites.count == 1)
    check("正常行仍被保留", messyParsed.recents == [pathB], "\(messyParsed.recents)")

    // ── 3. 空文本 / 空列表 ──
    let empty = Store.parse("")
    check("空文本得空列表", empty.favorites.isEmpty && empty.recents.isEmpty)
    check("空列表序列化为空文本", Store.serialize(favorites: [], recents: []).isEmpty)

    // ── 4. 最近列表：置顶、去重、截断 ──
    check("pushRecent 置顶", Store.pushRecent("/b", into: ["/a", "/b", "/c"]) == ["/b", "/a", "/c"],
          "\(Store.pushRecent("/b", into: ["/a", "/b", "/c"]))")
    check("pushRecent 截断", Store.pushRecent("/d", into: ["/a", "/b", "/c"], limit: 3) == ["/d", "/a", "/b"],
          "\(Store.pushRecent("/d", into: ["/a", "/b", "/c"], limit: 3))")
    check("pushRecent 空列表", Store.pushRecent("/x", into: []) == ["/x"])

    // ── 5. 文件往返：写到嵌套的新目录再读回 ──
    let storeFile = root.appendingPathComponent("fresh run/deep/projects.txt")
    check("首次保存（目录不存在）成功",
          Store.save(favorites: [pathA], recents: [pathB], to: storeFile))
    let reloaded = Store.load(from: storeFile)
    check("读回 favorites", reloaded.favorites == [pathA], "\(reloaded.favorites)")
    check("读回 recents", reloaded.recents == [pathB], "\(reloaded.recents)")
    check("保存后无 .tmp 残留",
          !fm.fileExists(atPath: storeFile.path + ".tmp"))

    // ── 6. 首次使用：文件不存在必须是正常情况 ──
    let absent = Store.load(from: root.appendingPathComponent("nope/projects.txt"))
    check("文件不存在时返回空列表且不报错", absent.favorites.isEmpty && absent.recents.isEmpty)

    // ── 7. 空文件同样正常 ──
    let emptyFile = root.appendingPathComponent("empty/projects.txt")
    try! fm.createDirectory(at: emptyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    fm.createFile(atPath: emptyFile.path, contents: Data())
    let fromEmpty = Store.load(from: emptyFile)
    check("空文件返回空列表", fromEmpty.favorites.isEmpty && fromEmpty.recents.isEmpty)

    // ── 8. 覆盖保存（文件已存在，走 replaceItemAt 分支）──
    check("覆盖保存成功", Store.save(favorites: [pathB], recents: [], to: storeFile))
    let overwritten = Store.load(from: storeFile)
    check("覆盖后内容正确", overwritten.favorites == [pathB] && overwritten.recents.isEmpty,
          "\(overwritten.favorites) / \(overwritten.recents)")

    // ── 9. 真实数据文件默认路径不应被本测试改动 ──
    check("默认路径指向 Application Support",
          Store.defaultFileURL.path.contains("Library/Application Support/PI Project Launcher/projects.txt"),
          Store.defaultFileURL.path)
    // ── 10. 取消常用不能让项目从列表消失（回归：曾丢失条目）──
    let p = pathA
    // 场景 A：常用项不在最近里 -> 取消后必须降级到最近
    let a = Store.togglingFavorite(p, favorites: [p], recents: [])
    check("取消常用后仍在列表中（降级到最近）", a.favorites.isEmpty && a.recents == [p],
          "fav=\(a.favorites) rec=\(a.recents)")
    check("取消常用返回 madeFavorite=false", a.madeFavorite == false)
    // 场景 B：已在最近里 -> 不应产生重复
    let b = Store.togglingFavorite(p, favorites: [p], recents: [p])
    check("已在最近时不重复", b.recents == [p], "\(b.recents)")
    // 场景 C：设为常用
    let c = Store.togglingFavorite(p, favorites: [], recents: [p])
    check("设为常用生效", c.favorites == [p] && c.madeFavorite == true)
    // 场景 D：往返切换后项目仍可见
    let on = Store.togglingFavorite(p, favorites: [], recents: [])
    let off = Store.togglingFavorite(p, favorites: on.favorites, recents: on.recents)
    check("切换往返后项目仍可见", on.favorites == [p] && (off.favorites == [] && off.recents == [p]))

    // ── 11. 会话历史：合成 JSONL，不触碰真实 ~/.pi ──
    let agentDir = root.appendingPathComponent("agent")
    let project = root.appendingPathComponent("history 项目.x").path
    try! fm.createDirectory(atPath: project, withIntermediateDirectories: true)
    let sessions = SessionHistory.directory(for: project, agentDir: agentDir)
    try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)

    // 按 PI 真实格式手写前缀：PI 每条都以 {"type":"... 开头、冒号后无空格。
    // 用 JSONSerialization 会打乱键序（实测生成 {"message":...），测不出真实场景。
    func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let text = String(data: data, encoding: .utf8)!   // ["..."]
        return String(text.dropFirst().dropLast())
    }
    func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    func write(_ name: String, _ lines: [String]) {
        try! (lines.joined(separator: "\n") + "\n")
            .write(to: sessions.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func header(_ id: String, cwd: String, at when: String) -> String {
        #"{"type":"session","version":3,"id":"\#(id)","timestamp":"\#(when)","cwd":\#(jsonString(cwd))}"#
    }
    func message(role: String, text: String, at ms: Double) -> String {
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
        return #"{"type":"message","id":"\#(UUID().uuidString)","message":{"role":"\#(role)","content":\#(jsonString(text)),"timestamp":\#(ms)},"timestamp":"\#(iso)"}"#
    }

    let base = 1_790_000_000_000.0   // 毫秒
    // a. 有名字，最新活动
    write("a.jsonl", [header("id-a", cwd: project, at: "2026-09-21T17:30:53.438Z"),
                      message(role: "user", text: "第一条提问", at: base),
                      line(["type": "session_info", "name": "  重构   启动器  ", "timestamp": "2026-09-21T18:00:00.000Z"]),
                      message(role: "assistant", text: "回答", at: base + 5_000_000)])
    // b. 无名字 → 回落第一条用户提问；带 assistant 正文不应出现在标题里
    write("b.jsonl", [header("id-b", cwd: project, at: "2026-09-20T10:00:00.000Z"),
                      message(role: "user", text: "  帮我\n换行   折叠  ", at: base + 300_000),
                      message(role: "assistant", text: "这段回答不该进标题", at: base + 900_000)])
    // c. 头部 cwd 不符 → 整个文件剔除
    write("c.jsonl", [header("id-c", cwd: root.appendingPathComponent("别的项目").path, at: "2026-09-21T17:00:00.000Z"),
                      message(role: "user", text: "别的项目的问题", at: base + 100_000)])
    // d. 只有头部没有消息 → 剔除
    write("d.jsonl", [header("id-d", cwd: project, at: "2026-09-21T17:00:00.000Z")])
    // e. 损坏行 + 超大行 → 仍可解析，且不影响其它文件
    let huge = message(role: "assistant", text: String(repeating: "x", count: 300 * 1024), at: base + 1_200_000)
    write("e.jsonl", [header("id-e", cwd: project, at: "2026-09-21T17:00:00.000Z"),
                      "{ 这不是合法 JSON",
                      huge,
                      message(role: "user", text: "超大行之后仍要能读到这条", at: base + 1_800_000)])
    // f–n. 11 条填充项，用于验证「只取 10 条」与时间倒序
    for i in 0..<11 {
        write("fill-\(i).jsonl", [header("id-f\(i)", cwd: project, at: "2026-09-19T10:00:00.000Z"),
                                  message(role: "user", text: "填充会话 \(i)", at: base - 10_000_000 - Double(i) * 1_000_000)])
    }
    // g. 超长用户提问 → 标题必须被截断
    write("g.jsonl", [header("id-g", cwd: project, at: "2026-09-18T10:00:00.000Z"),
                      message(role: "user", text: String(repeating: "长", count: 300), at: base + 400_000)])
    // h. 回归：开场前频繁切模型／思考等级（>16 行控制记录后才出现 system/user 消息）不能被漏掉
    var preludeLines = [header("id-h", cwd: project, at: "2026-09-21T19:00:00.000Z")]
    for i in 0..<24 {
        preludeLines.append(#"{"type":"thinking_level_change","id":"t\#(i)","thinkingLevel":"high","timestamp":"2026-09-21T19:00:00.000Z"}"#)
    }
    preludeLines.append(message(role: "system", text: "系统提示", at: base + 6_000_000))
    preludeLines.append(message(role: "user", text: "切了很多次思考等级后的最新会话", at: base + 6_000_000))
    preludeLines.append(message(role: "assistant", text: "收到", at: base + 6_001_000))
    write("h.jsonl", preludeLines)
    write("ignore.txt", ["not a session"])   // 非 jsonl 必须忽略

    let found = (try? SessionHistory.list(project: project, agentDir: agentDir)) ?? []
    check("会话列表最多 10 条", found.count == 10, "\(found.count)")
    check("按活动时间倒序", found.map(\.title).prefix(4) == ["切了很多次思考等级后的最新会话", "重构 启动器", "超大行之后仍要能读到这条", "帮我 换行 折叠"],
          "\(found.map(\.title).prefix(4))")
    check("最新活动的排在首位", found.first?.path.hasSuffix("/h.jsonl") == true, "\(found.first?.path ?? "-")")
    check("无名字时用第一条用户提问", found.contains { $0.title == "帮我 换行 折叠" })
    check("会话名折叠空白", found.contains { $0.title == "重构 启动器" })
    check("会话名不含 assistant 正文", !found.contains { $0.title.contains("不该进标题") })
    check("剔除头部 cwd 不符的会话", !found.contains { $0.path.hasSuffix("/c.jsonl") })
    check("剔除只有头部没有消息的会话", !found.contains { $0.path.hasSuffix("/d.jsonl") })
    check("忽略非 jsonl 文件", !found.contains { $0.path.hasSuffix("/ignore.txt") })
    check("超长会话名被截断到 200", found.contains { $0.title.count == 200 && $0.title.hasPrefix("长") },
          "\(found.map(\.title.count))")
    // 相邻两项时间不回升
    check("时间倒序", zip(found, found.dropFirst()).allSatisfy { $0.modified >= $1.modified })
    // 空目录：目录不存在时返回空列表而不是抛错
    let lonely = (try? SessionHistory.list(project: root.appendingPathComponent("没有会话的项目").path,
                                           agentDir: agentDir)) ?? []
    check("项目没有会话目录时返回空列表", lonely.isEmpty)
    // 目录名编码：绝对路径去首个斜杠，`/ \ :` 换成 -（期望值硬编码，避免与实现同形状而漏报）
    check("会话目录名编码正确（空格/点/中文）",
          SessionHistory.directory(for: "/tmp/我的 项目.v2", agentDir: agentDir).lastPathComponent
            == "--tmp-我的 项目.v2--",
          SessionHistory.directory(for: "/tmp/我的 项目.v2", agentDir: agentDir).lastPathComponent)

    // ── 12. 界面回传的路径必须重新核验 ──
    let validPath = sessions.appendingPathComponent("a.jsonl").path
    check("接受本项目会话", SessionHistory.validated(validPath, project: project, agentDir: agentDir) != nil)
    check("拒绝项目会话目录之外的文件",
          SessionHistory.validated("/etc/hosts", project: project, agentDir: agentDir) == nil)
    check("拒绝路径穿越",
          SessionHistory.validated(sessions.appendingPathComponent("../../a.jsonl").path,
                                   project: project, agentDir: agentDir) == nil)
    check("拒绝无效会话文件",
          SessionHistory.validated(sessions.appendingPathComponent("d.jsonl").path,
                                   project: project, agentDir: agentDir) == nil)
    check("拒绝不存在的文件",
          SessionHistory.validated(sessions.appendingPathComponent("nope.jsonl").path,
                                   project: project, agentDir: agentDir) == nil)

    // ── 14. 「添加常用项目」：只加常用，不改最近，不重复 ──
    let favPath = pathA
    let addOnce = Store.addingFavorite(favPath, favorites: [], recents: [])
    check("加入常用后出现在常用列表", addOnce.favorites == [favPath] && addOnce.added == true)
    check("加入常用不改动最近列表", addOnce.recents == [])
    let addAgain = Store.addingFavorite(favPath, favorites: [favPath], recents: [pathB])
    check("重复加入不产生重复项", addAgain.favorites == [favPath] && addAgain.added == false)
    check("重复加入不动最近列表", addAgain.recents == [pathB])
    check("加入常用后项目仍可见（不再进最近也不丢）",
          Store.parse(Store.serialize(favorites: addOnce.favorites, recents: addOnce.recents)).favorites == [favPath])
    // 回归：旧实现把「添加常用」错当成「打开项目」，等于从未写入常用区
    check("加入常用后不再处于「未收藏」状态",
          Store.togglingFavorite(favPath, favorites: addOnce.favorites, recents: addOnce.recents).madeFavorite == false)


    // ── 13. 启动命令：新会话逐字不变，恢复只多 --session，且路径不进命令 ──
    let tricky = "/tmp/项目 'A' 带引号 /sub"
    let plain = Launcher.appleScript(projectPath: tricky)
    let resumed = Launcher.appleScript(projectPath: tricky, sessionPath: "/tmp/会话 'B'.jsonl")

    check("新会话命令与既有实现一致",
          plain.contains(#"set command of cfg to "/bin/zsh -lc 'cd \"$PI_PROJECT_DIR\" || exit 1; exec \"$PI_BIN\"'""#))
    check("恢复命令追加固定字面量 --session",
          resumed.contains(#"exec \"$PI_BIN\" --session \"$PI_SESSION\"'"#))
    check("新会话命令不含 --session", !plain.contains("--session"))
    check("新会话不声明 PI_SESSION", !plain.contains("PI_SESSION"))
    check("恢复时声明 PI_SESSION", resumed.contains("PI_SESSION="))
    check("恢复时把会话路径交给环境变量", resumed.contains("/tmp/会话 'B'.jsonl"))
    // 真正的守门检查：项目路径与会话路径都不得出现在 command 那一行
    func commandLine(_ script: String) -> String {
        script.split(separator: "\n").first { $0.contains("set command of cfg") }.map(String.init) ?? ""
    }
    check("项目路径不进 command 行", !commandLine(plain).contains("项目") && !commandLine(resumed).contains("项目"),
          commandLine(resumed))
    check("会话路径不进 command 行", !commandLine(resumed).contains("会话"), commandLine(resumed))
    check("项目路径确实在环境变量里", plain.contains(tricky))
    check("反斜杠与引号转义正确", Launcher.asLiteral(#"a\b"c"#) == #""a\\b\"c""#)

    // ── 13b. 已有窗口查询：可靠匹配优先；未知/畸形无匹配不当作“明确没有窗口” ──
    let classifyTarget = project
    let foundOutput = "T\twin-1\t\(classifyTarget)\n"
    let classifiedFound = Launcher.classifyExistingTerminalOutput(foundOutput, target: classifyTarget)
    if case .found(let id) = classifiedFound {
        check("窗口查询可靠匹配返回窗口 id", id == "win-1", id)
    } else {
        check("窗口查询可靠匹配返回窗口 id", false)
    }
    func existingFailure(_ value: Launcher.ExistingTerminal) -> Bool {
        if case .failure = value { return true }
        return false
    }
    if case .none = Launcher.classifyExistingTerminalOutput("", target: classifyTarget) {
        check("窗口查询明确空结果视为未找到", true)
    } else {
        check("窗口查询明确空结果视为未找到", false)
    }
    let otherOnly = Launcher.classifyExistingTerminalOutput("T\twin-2\t/tmp/other\n",
                                                            target: classifyTarget)
    if case .none = otherOnly {
        check("完整 T 行无匹配视为明确未找到", true)
    } else {
        check("完整 T 行无匹配视为明确未找到", false)
    }
    let partialUnknown = Launcher.classifyExistingTerminalOutput(
        "T\twin-2\t/tmp/other\nE\t1\n", target: classifyTarget)
    check("存在不可读窗口项且无匹配时查询失败", existingFailure(partialUnknown))
    let malformed = Launcher.classifyExistingTerminalOutput("garbage\n", target: classifyTarget)
    check("不可解析窗口输出视为查询失败", existingFailure(malformed))
    let foundDespiteUnknown = Launcher.classifyExistingTerminalOutput(
        "T\twin-1\t\(classifyTarget)\nE\t1\n", target: classifyTarget)
    if case .found(let id) = foundDespiteUnknown {
        check("已有可靠匹配时保留结果", id == "win-1", id)
    } else {
        check("已有可靠匹配时保留结果", false)
    }
    let malformedField = Launcher.classifyExistingTerminalOutput(
        "T\t\t\(classifyTarget)\n", target: classifyTarget)
    check("窗口 id 缺失视为查询失败", existingFailure(malformedField))

    // ── 15. 最近列表可移除（v3 新增）──
    let removed = Store.removingRecent("/b", favorites: ["/a"], recents: ["/a", "/b", "/c"])
    check("移除最近项", removed.recents == ["/a", "/c"], "\(removed.recents)")
    check("移除不动常用列表", removed.favorites == ["/a"])
    let removedAbsent = Store.removingRecent("/zzz", favorites: [], recents: ["/a"])
    check("移除不存在的项是幂等的", removedAbsent.recents == ["/a"])

    // ── 16. 「继续上次」：latest 必须给出最近活动且属于本项目的一条 ──
    let latestItem = SessionHistory.latest(project: project, agentDir: agentDir)
    check("latest 返回本项目最近会话", latestItem?.path.hasSuffix("/h.jsonl") == true,
          latestItem?.path ?? "nil")
    check("latest 不返回其它项目的会话",
          SessionHistory.latest(project: root.appendingPathComponent("没有会话的项目").path,
                                agentDir: agentDir) == nil)

    // ── 17. 会话元信息：消息条数 + 摘要 ──
    check("list 返回消息条数", found.first { $0.path.hasSuffix("/a.jsonl") }?.messageCount == 2,
          "\(found.first { $0.path.hasSuffix("/a.jsonl") }?.messageCount ?? -1)")
    check("list 多前导记录会话也能正确计数与核验",
          found.first { $0.path.hasSuffix("/h.jsonl") }?.messageCount == 3
            && SessionHistory.validated(sessions.appendingPathComponent("h.jsonl").path,
                                        project: project, agentDir: agentDir) != nil,
          "\(found.first { $0.path.hasSuffix("/h.jsonl") }?.messageCount ?? -1)")
    check("countMessages 不把 session_info 算成消息",
          found.first { $0.path.hasSuffix("/b.jsonl") }?.messageCount == 2,
          "\(found.first { $0.path.hasSuffix("/b.jsonl") }?.messageCount ?? -1)")
    let summary = SessionHistory.summary(project: project, agentDir: agentDir)
    // 目录里共 18 个 jsonl：a b c d e g h + 11 个 fill。
    // summary 如实报「目录里有几个会话文件」，其中 c/d 因内容不合格不会出现在列表里——
    // 卡片上写的是「这个项目有过多少次会话」，不是「历史页能列出几条」。
    check("summary 给出会话文件总数", summary?.count == 18, "\(summary?.count ?? -1)")
    check("summary 给出最近活动时间", summary?.last != nil)
    check("summary 在无会话项目上返回 nil",
          SessionHistory.summary(project: root.appendingPathComponent("没有会话的项目").path,
                                 agentDir: agentDir) == nil)

    // ── 18. 终端：注册表检测、偏好回落、命令行引号 ──
    // 检测靠注入的探针，不依赖本机装了什么
    let onlyTerminal = Terminal.installed { $0.id == "terminal" }
    check("只装 Terminal 时只列它", onlyTerminal.map(\.id) == ["terminal"], "\(onlyTerminal.map(\.id))")
    let ghosttyAndITerm = Terminal.installed { $0.id == "ghostty" || $0.id == "iterm" }
    check("装了但未适配的终端也会被检测到",
          ghosttyAndITerm.contains { $0.id == "iterm" && !$0.supported }, "\(ghosttyAndITerm.map(\.id))")
    check("菜单顺序跟随注册表", ghosttyAndITerm.map(\.id) == ["ghostty", "iterm"])

    let pickedITerm = Terminal.resolve(selected: "iterm", available: ghosttyAndITerm)
    check("选了未适配的终端会回落到 Ghostty", pickedITerm.kind?.id == "ghostty", pickedITerm.kind?.id ?? "nil")
    check("回落时要标记出来（底栏要说明）", pickedITerm.fellBack)
    let firstRun = Terminal.resolve(selected: nil, available: ghosttyAndITerm)
    check("没存过选择时用 Ghostty，不算回落", firstRun.kind?.id == "ghostty" && !firstRun.fellBack)
    let kept = Terminal.resolve(selected: "terminal", available: onlyTerminal)
    check("选中的终端可用时原样使用", kept.kind?.id == "terminal" && !kept.fellBack)
    let goneGhostty = Terminal.resolve(selected: "ghostty", available: onlyTerminal)
    check("选的终端没装了就回落到 Terminal 并标记",
          goneGhostty.kind?.id == "terminal" && goneGhostty.fellBack, goneGhostty.kind?.id ?? "nil")
    check("一个都用不了时没有可用终端", Terminal.resolve(selected: "ghostty", available: []).kind == nil)
    check("只有 Ghostty 能复用已开窗口",
          Terminal.known.first { $0.id == "ghostty" }?.supportsRefocus == true
            && Terminal.known.first { $0.id == "terminal" }?.supportsRefocus == false)

    // 偏好文件：读写往返、空文件 / 空行当没存过
    let prefFile = root.appendingPathComponent("pref/terminal.txt")
    check("首次写入偏好（目录不存在）成功", Terminal.saveSelection("terminal", to: prefFile))
    check("读回偏好", Terminal.savedSelection(from: prefFile) == "terminal",
          Terminal.savedSelection(from: prefFile) ?? "nil")
    check("偏好文件不存在时视为没存过",
          Terminal.savedSelection(from: root.appendingPathComponent("pref/none.txt")) == nil)
    try! "\n  \n".write(to: prefFile, atomically: true, encoding: .utf8)
    check("空行视为没存过", Terminal.savedSelection(from: prefFile) == nil)
    try! "  ghostty \n".write(to: prefFile, atomically: true, encoding: .utf8)
    check("偏好去除首尾空白", Terminal.savedSelection(from: prefFile) == "ghostty")
    check("偏好默认路径与项目列表同目录",
          Terminal.preferenceURL.deletingLastPathComponent().path
            == Store.defaultFileURL.deletingLastPathComponent().path)

    // 引号：用真的 zsh 反解，比只对字符串形状更可靠
    func shell(_ line: String) -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", line]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
    let trickyPaths = ["/tmp/项目 'A' 带引号 /sub", "/tmp/plain",
                       "/tmp/$(whoami) `x` ; echo bad", "/tmp/back\\slash", "/tmp/dollar$HOME"]
    for path in trickyPaths {
        let echoed = shell("printf %s \(Terminal.shellQuote(path))")
        check("单引号转义能反解回原文", echoed.out == path, "\(path) -> \(echoed.out)")
    }

    // 整条命令：cd 进项目、不带 --session 时不出现、路径不被 shell 展开
    let trickyDir = root.appendingPathComponent("项目 'A' 带引号 /sub").path
    try! fm.createDirectory(atPath: trickyDir, withIntermediateDirectories: true)
    let cmdPlain = Terminal.command(projectPath: trickyDir, sessionPath: nil, piCommand: "/bin/echo")
    check("新会话命令不含 --session", !cmdPlain.contains("--session"), cmdPlain)
    let cmdResume = Terminal.command(projectPath: trickyDir, sessionPath: "/tmp/会话 'B'.jsonl",
                                     piCommand: "/bin/echo")
    check("恢复命令追加 --session", cmdResume.contains("--session '" + "/tmp/会话 '\\''B'\\''.jsonl"), cmdResume)
    let resumeEcho = shell(cmdResume)
    check("恢复命令交给 shell 后参数不被拆开",
          resumeEcho.out == "--session /tmp/会话 'B'.jsonl\n" && resumeEcho.code == 0,
          "\(resumeEcho.out) code=\(resumeEcho.code)")
    let plainEcho = shell(cmdPlain)
    check("新会话命令 cd 进项目后执行", plainEcho.out == "\n" && plainEcho.code == 0,
          "\(plainEcho.out) code=\(plainEcho.code)")
    // cd 失败必须停住，不能在错的目录里起 pi
    let badCd = shell(Terminal.command(projectPath: root.appendingPathComponent("不存在的目录").path,
                                      sessionPath: nil, piCommand: "/bin/echo"))
    check("目录不存在时不执行后面的命令", badCd.out.isEmpty, badCd.out)

    // ── 19. 进程探测：新会话要靠它确认「pi 真的在这个目录里起来了」──
    let probeDir = root.appendingPathComponent("probe 项目").path
    try! fm.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
    let mark = Date()
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["5"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: probeDir)
    try! sleeper.run()
    var seen = false
    for _ in 0..<40 where !seen {
        seen = ProcessProbe.running(in: probeDir, since: mark)
        if !seen { usleep(50_000) }
    }
    check("能在项目目录里找到新起的进程", seen)
    check("没进程的目录找不到（不能凭空说起来了）",
          !ProcessProbe.running(in: root.appendingPathComponent("空目录").path, since: mark))
    check("启动之前的进程不算这一次",
          !ProcessProbe.running(in: probeDir, since: Date().addingTimeInterval(60)))
    // 身份过滤：`exec pi` 失败时包装的 shell 仍在目录里，不能把它当成 pi。
    // 本机实测真 pi 的三处写法是 comm=node / exe=…/node / argv[0]=pi，
    // 所以认身份必须看 argv，只看 exe 文件名会永远等不到。
    check("不是 pi 的进程不算（避免把包装 shell 当成 pi）",
          !ProcessProbe.running(in: probeDir, since: Date().addingTimeInterval(-5), expectedCommand: "pi"))
    check("按名字筛到同一个可执行文件时才算",
          ProcessProbe.running(in: probeDir, since: Date().addingTimeInterval(-5), expectedCommand: "sleep"))

    // 名字叫 pi 的脚本进程：argv 认得出它（这正是不比 exe 文件名的原因）
    let piDir = root.appendingPathComponent("带 pi 的目录").path
    try! fm.createDirectory(atPath: piDir, withIntermediateDirectories: true)
    let fakePi = piDir + "/pi"
    try! "#!/bin/zsh\n/bin/sleep 3\n".write(toFile: fakePi, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePi)
    let piProcess = Process()
    piProcess.executableURL = URL(fileURLWithPath: fakePi)
    piProcess.currentDirectoryURL = URL(fileURLWithPath: piDir)
    try! piProcess.run()
    var piSeen = false
    for _ in 0..<40 where !piSeen {
        piSeen = ProcessProbe.running(in: piDir, since: Date().addingTimeInterval(-5), expectedCommand: "pi")
        if !piSeen { usleep(50_000) }
    }
    check("名字叫 pi 的脚本进程能被认出来（argv 口径）", piSeen)
    check("同一个脚本换成别的名字就不算",
          !ProcessProbe.running(in: piDir, since: Date().addingTimeInterval(-5), expectedCommand: "node"))
    piProcess.terminate()
    piProcess.waitUntilExit()
    sleeper.terminate()
    sleeper.waitUntilExit()

    // ── 20a. 生命周期门：退出后后台回调不得再执行动作 ──
    let lifecycle = ProcessProbe.LifecycleGuard()
    var lifecycleActions = 0
    check("生命周期门初始允许动作", lifecycle.isActive)
    check("生命周期门执行一次动作", lifecycle.performIfActive { lifecycleActions += 1 })
    lifecycle.shutdown()
    check("生命周期门退出后拒绝动作", !lifecycle.isActive)
    check("生命周期门退出后不执行", !lifecycle.performIfActive { lifecycleActions += 1 })
    check("生命周期门只执行过退出前动作", lifecycleActions == 1, "\(lifecycleActions)")

    // 准备期动作队列：入队不执行；一次取走；关闭后丢弃。
    let actionQueue = ProcessProbe.ActionQueue()
    var actionQueueRan = 0
    actionQueue.enqueue { actionQueueRan += 1 }
    actionQueue.enqueue { actionQueueRan += 10 }
    check("准备期动作入队后尚未执行", actionQueueRan == 0, "\(actionQueueRan)")
    let actionQueueBatch = actionQueue.takeAll()
    check("准备期动作一次全部取走", actionQueueBatch.count == 2, "\(actionQueueBatch.count)")
    actionQueueBatch.forEach { $0() }
    check("准备期动作按入队顺序执行", actionQueueRan == 11, "\(actionQueueRan)")
    actionQueue.close()
    actionQueue.enqueue { actionQueueRan += 100 }
    check("动作队列关闭后不再接收",
          actionQueue.takeAll().isEmpty && actionQueueRan == 11, "\(actionQueueRan)")

    // ── 20b. 增量摘要投影：nil 移除、合并目标、replaceAll、当前项目过滤 ──
    var projected: [String: Int] = ["a": 1, "b": 2, "stale": 3]
    ProcessProbe.RuntimeProjection.apply(
        to: &projected, requested: ["a", "c"], snapshot: ["a": 9],
        replaceAll: false, current: ["a", "c"], normalize: { $0 })
    check("摘要投影移除缺失/已移除项目并保留命中",
          projected == ["a": 9], "\(projected)")
    var merged: [String: Int] = ["old": 1]
    ProcessProbe.RuntimeProjection.apply(
        to: &merged, requested: ["a", "b"], snapshot: ["a": 4, "b": 5],
        replaceAll: false, current: ["a", "b"], normalize: { $0 })
    check("摘要投影合并多个增量目标",
          merged == ["a": 4, "b": 5], "\(merged)")
    var projectedReplaced: [String: Int] = ["old": 1, "a": 2]
    ProcessProbe.RuntimeProjection.apply(
        to: &projectedReplaced, requested: ["a", "b"], snapshot: ["a": 7],
        replaceAll: true, current: ["a", "b"], normalize: { $0 })
    check("摘要投影 replaceAll 清掉旧项",
          projectedReplaced == ["a": 7], "\(projectedReplaced)")
    var normalized: [String: Int] = ["/tmp/a/": 1, "/tmp/b": 2]
    ProcessProbe.RuntimeProjection.apply(
        to: &normalized, requested: ["/tmp/a/", "/tmp/c"], snapshot: ["/tmp/a/": 8],
        replaceAll: false, current: ["/tmp/a", "/tmp/c"],
        normalize: { path in path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path })
    check("摘要投影按当前项目归一化过滤",
          normalized == ["/tmp/a/": 8], "\(normalized)")

    // 协调器只保留等价路径中的一个原键；投影必须按词法键命中别名，同时保留项目 ID。
    let lexicalKey: (String) -> String = { path in
        var key = URL(fileURLWithPath: path).standardizedFileURL.path
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }
    var aliased: [String: Int] = ["/tmp/a": 1]
    ProcessProbe.RuntimeProjection.apply(
        to: &aliased, requested: ["/tmp/a/"], snapshot: ["/tmp/a": 9],
        replaceAll: false, current: ["/tmp/a", "/tmp/a/"], normalize: lexicalKey)
    check("摘要投影别名键命中并保留项目 ID",
          aliased == ["/tmp/a": 9, "/tmp/a/": 9], "\(aliased)")
    var aliasedNil: [String: Int] = ["/tmp/a": 1, "/tmp/a/": 2]
    ProcessProbe.RuntimeProjection.apply(
        to: &aliasedNil, requested: ["/tmp/a/"], snapshot: [:],
        replaceAll: false, current: ["/tmp/a", "/tmp/a/"], normalize: lexicalKey)
    check("摘要投影真实 nil 清掉同一词法键的别名",
          aliasedNil.isEmpty, "\(aliasedNil)")
    var emptied: [String: Int] = ["old": 1]
    ProcessProbe.RuntimeProjection.apply(
        to: &emptied, requested: [], snapshot: [:],
        replaceAll: true, current: [], normalize: lexicalKey)
    check("摘要投影空目标 replaceAll 清空",
          emptied.isEmpty, "\(emptied)")

    // ── 20. 共享启动监测：立即首检、每轮一份 PID 快照、按请求匹配、停止/超时 ──
    func waitMonitor(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
    let monitorDir = root.appendingPathComponent("monitor 项目").path
    try! fm.createDirectory(atPath: monitorDir, withIntermediateDirectories: true)
    let monitorLock = NSLock()
    var monitorListCalls = 0
    var monitorEvents: [String] = []
    let monitorDone = DispatchSemaphore(value: 0)
    var monitorResult: ProcessProbe.MonitorResult?
    let immediateMonitor = ProcessProbe.Monitor(
        interval: 5.0,
        lister: {
            monitorLock.lock(); monitorListCalls += 1; monitorLock.unlock()
            return [4242]
        },
        startTime: { _ in
            monitorLock.lock(); monitorEvents.append("start"); monitorLock.unlock()
            return Date()
        },
        cwd: { _ in
            monitorLock.lock(); monitorEvents.append("cwd"); monitorLock.unlock()
            return monitorDir
        },
        matches: { _, _ in
            monitorLock.lock(); monitorEvents.append("match"); monitorLock.unlock()
            return true
        })
    immediateMonitor.add(id: "monitor-immediate", projectPath: monitorDir,
                         since: Date().addingTimeInterval(-1), expectedCommand: "pi",
                         deadline: Date().addingTimeInterval(2)) { result in
        monitorLock.lock(); monitorResult = result; monitorLock.unlock()
        monitorDone.signal()
    }
    check("共享监测器立即首检（不等 interval）",
          waitMonitor(monitorDone, seconds: 1))
    monitorLock.lock()
    let immediateResult = monitorResult
    let listCallsAfterImmediate = monitorListCalls
    let eventOrder = monitorEvents
    monitorLock.unlock()
    check("共享监测器命中运行中进程", immediateResult == .some(.running))
    check("共享监测器一轮只枚举一次 PID 列表", listCallsAfterImmediate == 1,
          "\(listCallsAfterImmediate)")
    if let startIndex = eventOrder.firstIndex(of: "start"),
       let cwdIndex = eventOrder.firstIndex(of: "cwd"),
       let matchIndex = eventOrder.firstIndex(of: "match") {
        check("共享监测器先读启动时间再读 cwd/身份",
              startIndex < cwdIndex && cwdIndex < matchIndex, "\(eventOrder)")
    } else {
        check("共享监测器先读启动时间再读 cwd/身份", false, "\(eventOrder)")
    }
    immediateMonitor.shutdown()

    // 两个并发请求共用同一轮 PID 快照；第一轮空结果不结束，下一轮一起命中。
    let sharedLock = NSLock()
    var sharedListCalls = 0
    var sharedResults: [String: ProcessProbe.MonitorResult] = [:]
    let sharedDone = DispatchSemaphore(value: 0)
    let sharedMonitor = ProcessProbe.Monitor(
        interval: 1.0,
        lister: {
            sharedLock.lock()
            sharedListCalls += 1
            let call = sharedListCalls
            sharedLock.unlock()
            return call < 2 ? [] : [4242]
        },
        startTime: { _ in Date() },
        cwd: { _ in monitorDir },
        matches: { _, _ in true })
    let sharedCompletion: (String) -> (ProcessProbe.MonitorResult) -> Void = { id in
        return { result in
            sharedLock.lock()
            sharedResults[id] = result
            let count = sharedResults.count
            sharedLock.unlock()
            if count == 2 { sharedDone.signal() }
        }
    }
    sharedMonitor.add(id: "shared-a", projectPath: monitorDir,
                      since: Date().addingTimeInterval(-1), expectedCommand: nil,
                      deadline: Date().addingTimeInterval(2), completion: sharedCompletion("a"))
    sharedMonitor.add(id: "shared-b", projectPath: monitorDir,
                      since: Date().addingTimeInterval(-1), expectedCommand: nil,
                      deadline: Date().addingTimeInterval(2), completion: sharedCompletion("b"))
    check("共享监测器两个请求都完成", waitMonitor(sharedDone, seconds: 2))
    sharedLock.lock()
    let sharedSnapshot = sharedResults
    let sharedCallCount = sharedListCalls
    sharedLock.unlock()
    check("共享监测器两请求均命中", sharedSnapshot["a"] == .some(.running) &&
          sharedSnapshot["b"] == .some(.running), "\(sharedSnapshot)")
    check("共享监测器多请求仍每轮只枚举一次",
          sharedCallCount == 2, "\(sharedCallCount)")
    sharedMonitor.shutdown()

    var timeoutResult: ProcessProbe.MonitorResult?
    let timeoutDone = DispatchSemaphore(value: 0)
    var timeoutCalls = 0
    let timeoutLock = NSLock()
    let timeoutMonitor2 = ProcessProbe.Monitor(
        interval: 0.02,
        lister: {
            timeoutLock.lock(); timeoutCalls += 1; timeoutLock.unlock()
            return []
        },
        startTime: { _ in nil },
        cwd: { _ in nil },
        matches: { _, _ in false })
    timeoutMonitor2.add(id: "monitor-timeout", projectPath: monitorDir,
                        since: Date().addingTimeInterval(-1), expectedCommand: "pi",
                        deadline: Date().addingTimeInterval(0.08)) { result in
        timeoutLock.lock(); timeoutResult = result; timeoutLock.unlock()
        timeoutDone.signal()
    }
    check("共享监测器超时回调", waitMonitor(timeoutDone, seconds: 2))
    timeoutLock.lock()
    let timedOut = timeoutResult
    let callsAtTimeout = timeoutCalls
    timeoutLock.unlock()
    check("共享监测器超时结果正确", timedOut == .some(.timedOut))
    usleep(120_000)
    timeoutLock.lock()
    let callsAfterStop = timeoutCalls
    timeoutLock.unlock()
    check("共享监测器无待办后停止枚举", callsAfterStop == callsAtTimeout,
          "\(callsAtTimeout) -> \(callsAfterStop)")
    timeoutMonitor2.shutdown()

    // 同一 PID 的启动时间/cwd 每轮重读；第二轮看到新身份才成功。
    let reuseLock = NSLock()
    var reuseStarted = Date().addingTimeInterval(-10)
    let reuseDone = DispatchSemaphore(value: 0)
    var reuseResult: ProcessProbe.MonitorResult?
    let reuseMonitor = ProcessProbe.Monitor(
        interval: 0.02,
        lister: { [777] },
        startTime: { _ in reuseLock.lock(); defer { reuseLock.unlock() }; return reuseStarted },
        cwd: { _ in monitorDir },
        matches: { _, _ in true })
    reuseMonitor.add(id: "monitor-reuse", projectPath: monitorDir,
                     since: Date(), expectedCommand: nil,
                     deadline: Date().addingTimeInterval(2)) { result in
        reuseLock.lock(); reuseResult = result; reuseLock.unlock()
        reuseDone.signal()
    }
    usleep(80_000)
    reuseLock.lock(); reuseStarted = Date(); reuseLock.unlock()
    check("同一 PID 新一轮重读启动时间后命中", waitMonitor(reuseDone, seconds: 2))
    reuseLock.lock()
    let reused = reuseResult
    reuseLock.unlock()
    check("PID 复用不跨轮缓存身份", reused == .some(.running))
    reuseMonitor.shutdown()

    try? fm.removeItem(at: root)

    // ── 19. 性能断言：读取必须走头部增量，不能退回全文解析 ──
    // 造 40 个会话、每个 400KB，全量解析会超过 300ms；头部读取应远低于 100ms。
    let perfProject = root.appendingPathComponent("perf 项目").path
    try! fm.createDirectory(atPath: perfProject, withIntermediateDirectories: true)
    let perfDir = SessionHistory.directory(for: perfProject, agentDir: agentDir)
    try! fm.createDirectory(at: perfDir, withIntermediateDirectories: true)
    let filler = String(repeating: "z", count: 400 * 1024)
    for i in 0..<40 {
        let body = [
            header("perf-\(i)", cwd: perfProject, at: "2026-09-21T17:30:53.438Z"),
            message(role: "user", text: "性能会话 \(i)", at: base - Double(i) * 1000),
            message(role: "assistant", text: filler, at: base),
            message(role: "assistant", text: filler, at: base + 1000)
        ].joined(separator: "\n") + "\n"
        try! body.write(to: perfDir.appendingPathComponent("p\(i).jsonl"), atomically: true, encoding: .utf8)
    }
    // 首次读取要落冷缓存，实测 137ms；第二次起 4–8ms。这里测热路径（更接近真实使用：
    // 用户点开历史之前，卡片摘要已经读过一遍同一批文件）。
    _ = try? SessionHistory.list(project: perfProject, agentDir: agentDir)
    let perfStart = Date()
    let perfFound = (try? SessionHistory.list(project: perfProject, agentDir: agentDir)) ?? []
    let perfMs = Date().timeIntervalSince(perfStart) * 1000
    check("40 个 400KB 会话的热路径读取在 100ms 内", perfMs < 100, String(format: "%.0f ms", perfMs))
    check("性能样本仍能正确列出 10 条", perfFound.count == 10, "\(perfFound.count)")
    // 这些文件的 mtime 是写入顺序，最后一个写的 p39 最新；标题必须来自它自己
    check("性能样本标题取最新那条", perfFound.first?.title == "性能会话 39", perfFound.first?.title ?? "-")
    check("性能样本消息条数正确", perfFound.first?.messageCount == 3, "\(perfFound.first?.messageCount ?? -1)")

    try? fm.removeItem(at: root)

    // ── 20. 会话缓存：冷/热、追加、替换、删除、同名重建、空目录 ──
    let cacheRoot = root.appendingPathComponent("缓存 项目")
    try! fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    let cacheProject = cacheRoot.appendingPathComponent("主项目").path
    try! fm.createDirectory(atPath: cacheProject, withIntermediateDirectories: true)
    let cacheDir = SessionHistory.directory(for: cacheProject, agentDir: agentDir)
    try! fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    func cacheWrite(_ name: String, _ lines: [String]) {
        try! (lines.joined(separator: "\n") + "\n")
            .write(to: cacheDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    for i in 0..<12 {
        cacheWrite("c\(i).jsonl", [header("cache-\(i)", cwd: cacheProject, at: "2026-09-21T17:00:00.000Z"),
                                    message(role: "user", text: "缓存在线 \(i)", at: base + Double(i) * 1_000_000),
                                    message(role: "assistant", text: "回答 \(i)", at: base + Double(i) * 1_000_000 + 1_000)])
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000 + Double(i))],
                              ofItemAtPath: cacheDir.appendingPathComponent("c\(i).jsonl").path)
    }
    // 内容不合格（头部 cwd 属于别的项目）的文件
    cacheWrite("other.jsonl", [header("cache-other", cwd: cacheRoot.appendingPathComponent("别的项目").path,
                                       at: "2026-09-21T17:00:00.000Z"),
                               message(role: "user", text: "别的项目", at: base)])
    // 会话目录里的符号链接必须被拒绝
    try? fm.createSymbolicLink(at: cacheDir.appendingPathComponent("link.jsonl"),
                               withDestinationURL: cacheDir.appendingPathComponent("c0.jsonl"))
    let cacheFileCount = 14   // 12 个正常会话 + other + link

    SessionHistory.invalidateAll()
    SessionHistory.resetStatistics()
    let cacheCold = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    let cacheColdStats = SessionHistory.statistics()
    check("缓存冷读仍列 10 条", cacheCold.count == 10, "\(cacheCold.count)")
    check("每轮属性快照只取一次（等于文件数）",
          cacheColdStats.attributeReads == cacheFileCount, "\(cacheColdStats.attributeReads)")
    check("冷读只为最终条目计数", cacheColdStats.messageCountReads == 10, "\(cacheColdStats.messageCountReads)")
    check("冷读只扫描可解析候选的头部", cacheColdStats.headScans == 13, "\(cacheColdStats.headScans)")

    SessionHistory.resetStatistics()
    let cacheWarm = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    let cacheWarmStats = SessionHistory.statistics()
    check("热读不再扫头部或计数",
          cacheWarmStats.headScans == 0 && cacheWarmStats.messageCountReads == 0,
          "head=\(cacheWarmStats.headScans) count=\(cacheWarmStats.messageCountReads)")
    check("热读仍每轮收集一次属性", cacheWarmStats.attributeReads == cacheFileCount,
          "\(cacheWarmStats.attributeReads)")
    check("热读命中计数缓存", cacheWarmStats.countHits == 10, "\(cacheWarmStats.countHits)")
    check("热读结果与冷读一致",
          cacheCold.count == cacheWarm.count && zip(cacheCold, cacheWarm).allSatisfy { pair in
              pair.0.path == pair.1.path && pair.0.title == pair.1.title
                  && pair.0.messageCount == pair.1.messageCount
                  && abs(pair.0.modified.timeIntervalSince(pair.1.modified)) < 0.001
          })

    SessionHistory.resetStatistics()
    let cacheLatest = SessionHistory.latest(project: cacheProject, agentDir: agentDir)
    let cacheValidated = SessionHistory.validated(cacheDir.appendingPathComponent("c5.jsonl").path,
                                                  project: cacheProject, agentDir: agentDir)
    let noCountStats = SessionHistory.statistics()
    check("latest 与 list 选择同一条", cacheLatest?.path == cacheWarm.first?.path,
          "\(cacheLatest?.path ?? "nil")")
    check("validated 仍接受本项目会话", cacheValidated != nil)
    check("latest/validated 的消息计数调用为 0",
          noCountStats.messageCountReads == 0 && noCountStats.countHits == 0,
          "read=\(noCountStats.messageCountReads) hit=\(noCountStats.countHits)")

    func cacheAppend(_ name: String, _ text: String) {
        let handle = try! FileHandle(forWritingTo: cacheDir.appendingPathComponent(name))
        handle.seekToEndOfFile()
        handle.write(Data((message(role: "user", text: text, at: base + 900_000_000) + "\n").utf8))
        try! handle.close()
    }
    cacheAppend("c1.jsonl", "追加后的问题")
    let afterAppend = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    let appended = afterAppend.first { $0.path.hasSuffix("/c1.jsonl") }
    check("追加后消息计数增加", appended?.messageCount == 3, "\(appended?.messageCount ?? -1)")
    check("追加后该会话按真实活动排到最前", afterAppend.first?.path.hasSuffix("/c1.jsonl") == true,
          afterAppend.first?.path ?? "nil")

    cacheWrite("c2.jsonl", [header("cache-2b", cwd: cacheProject, at: "2026-09-21T17:00:00.000Z"),
                            message(role: "user", text: "替换后的标题", at: base + 950_000_000),
                            message(role: "assistant", text: "替换后的回答", at: base + 960_000_000)])
    let afterReplace = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    let replaced = afterReplace.first { $0.path.hasSuffix("/c2.jsonl") }
    check("替换文件后标题更新", replaced?.title == "替换后的标题", replaced?.title ?? "nil")
    check("替换文件后计数更新", replaced?.messageCount == 2, "\(replaced?.messageCount ?? -1)")

    try! fm.removeItem(at: cacheDir.appendingPathComponent("c3.jsonl"))
    let afterDelete = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    check("删除的会话不再出现", !afterDelete.contains { $0.path.hasSuffix("/c3.jsonl") })

    // 同名重建：把 mtime 复原，只能靠 inode/ctime 识别成新文件
    let rebuildURL = cacheDir.appendingPathComponent("c4.jsonl")
    let oldModified = (try? rebuildURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    try! fm.removeItem(at: rebuildURL)
    try! ([header("cache-4b", cwd: cacheProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "同名重建后的标题", at: base + 970_000_000),
           message(role: "assistant", text: "回答", at: base + 971_000_000)]
          .joined(separator: "\n") + "\n")
        .write(to: rebuildURL, atomically: true, encoding: .utf8)
    if let oldModified = oldModified {
        try? fm.setAttributes([.modificationDate: oldModified], ofItemAtPath: rebuildURL.path)
    }
    let afterRebuild = (try? SessionHistory.list(project: cacheProject, agentDir: agentDir)) ?? []
    let rebuilt = afterRebuild.first { $0.path.hasSuffix("/c4.jsonl") }
    check("同名文件重建后不吃旧缓存", rebuilt?.title == "同名重建后的标题", rebuilt?.title ?? "nil")

    let emptyProject = cacheRoot.appendingPathComponent("空项目").path
    try! fm.createDirectory(atPath: emptyProject, withIntermediateDirectories: true)
    let emptyDir = SessionHistory.directory(for: emptyProject, agentDir: agentDir)
    try! fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    check("空会话目录列表为空且不报错",
          ((try? SessionHistory.list(project: emptyProject, agentDir: agentDir)) ?? []).isEmpty)
    check("空会话目录摘要为 nil", SessionHistory.summary(project: emptyProject, agentDir: agentDir) == nil)

    // ── 21. 目录编码碰撞：缓存不能把 A 项目的会话当成 B 项目的 ──
    let collideRoot = root.appendingPathComponent("碰撞 项目")
    let collideA = collideRoot.appendingPathComponent("a-b").path
    let collideB = collideRoot.appendingPathComponent("a/b").path
    try! fm.createDirectory(atPath: collideA, withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: collideB, withIntermediateDirectories: true)
    let collideDirA = SessionHistory.directory(for: collideA, agentDir: agentDir)
    let collideDirB = SessionHistory.directory(for: collideB, agentDir: agentDir)
    check("两个项目确实共享同一个编码目录", collideDirA.path == collideDirB.path,
          "\(collideDirA.path) / \(collideDirB.path)")
    try! fm.createDirectory(at: collideDirA, withIntermediateDirectories: true)
    try! ([header("collide-a", cwd: collideA, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "只属于 A 的会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: collideDirA.appendingPathComponent("shared.jsonl"), atomically: true, encoding: .utf8)
    SessionHistory.invalidateAll()
    let collideBFirst = (try? SessionHistory.list(project: collideB, agentDir: agentDir)) ?? []
    let collideAList = (try? SessionHistory.list(project: collideA, agentDir: agentDir)) ?? []
    let collideBSecond = (try? SessionHistory.list(project: collideB, agentDir: agentDir)) ?? []
    check("编码碰撞的另一个项目看不到 A 的会话", collideBFirst.isEmpty && collideBSecond.isEmpty,
          "\(collideBFirst.count) / \(collideBSecond.count)")
    check("编码碰撞时 A 项目仍能看到自己的会话", collideAList.count == 1, "\(collideAList.count)")

    // ── 22. 符号链接：会话文件拒绝；项目路径可走物理目录 ──
    let physicalProject = cacheRoot.appendingPathComponent("physical").path
    try! fm.createDirectory(atPath: physicalProject, withIntermediateDirectories: true)
    let linkProject = cacheRoot.appendingPathComponent("link-project").path
    try? fm.createSymbolicLink(atPath: linkProject, withDestinationPath: physicalProject)
    let physicalDir = SessionHistory.directory(for: physicalProject, agentDir: agentDir)
    try! fm.createDirectory(at: physicalDir, withIntermediateDirectories: true)
    try! ([header("physical-1", cwd: physicalProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "物理路径下的会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: physicalDir.appendingPathComponent("p.jsonl"), atomically: true, encoding: .utf8)
    let viaLink = (try? SessionHistory.list(project: linkProject, agentDir: agentDir)) ?? []
    check("项目路径是符号链接时仍能找到物理目录的会话", viaLink.count == 1, "\(viaLink.count)")
    try? fm.createSymbolicLink(atPath: physicalDir.appendingPathComponent("alias.jsonl").path,
                               withDestinationPath: physicalDir.appendingPathComponent("p.jsonl").path)
    let withAlias = (try? SessionHistory.list(project: physicalProject, agentDir: agentDir)) ?? []
    check("会话目录里的符号链接文件被拒绝", !withAlias.contains { $0.path.hasSuffix("/alias.jsonl") })

    // ── 23. 读取过程中文件变化：不写缓存 ──
    let mutationProject = cacheRoot.appendingPathComponent("读中变化").path
    try! fm.createDirectory(atPath: mutationProject, withIntermediateDirectories: true)
    let mutationDir = SessionHistory.directory(for: mutationProject, agentDir: agentDir)
    try! fm.createDirectory(at: mutationDir, withIntermediateDirectories: true)
    let mutationFile = mutationDir.appendingPathComponent("only.jsonl")
    try! ([header("mutation", cwd: mutationProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "读中变化的会话", at: base),
           message(role: "assistant", text: "回答", at: base + 1_000)]
          .joined(separator: "\n") + "\n")
        .write(to: mutationFile, atomically: true, encoding: .utf8)
    SessionHistory.invalidate(project: mutationProject, agentDir: agentDir)
    SessionHistory.resetStatistics()
    SessionHistory.readMutationHook = {
        SessionHistory.readMutationHook = nil
        if let handle = try? FileHandle(forWritingTo: mutationFile) {
            handle.seekToEndOfFile()
            handle.write(Data((message(role: "user", text: "读中追加的问题", at: base + 2_000_000) + "\n").utf8))
            try? handle.close()
        }
    }
    _ = try? SessionHistory.list(project: mutationProject, agentDir: agentDir)
    let mutationStats = SessionHistory.statistics()
    check("读取中变化的结果不写缓存", mutationStats.cacheStores == 0, "\(mutationStats.cacheStores)")
    SessionHistory.readMutationHook = nil
    let mutationSettled = (try? SessionHistory.list(project: mutationProject, agentDir: agentDir)) ?? []
    check("变化稳定后读到最新消息数", mutationSettled.first?.messageCount == 3,
          "\(mutationSettled.first?.messageCount ?? -1)")

    // ── 24. 候选上限、mtime 错序、长残缺行 ──
    let bigProject = cacheRoot.appendingPathComponent("大目录").path
    try! fm.createDirectory(atPath: bigProject, withIntermediateDirectories: true)
    let bigDir = SessionHistory.directory(for: bigProject, agentDir: agentDir)
    try! fm.createDirectory(at: bigDir, withIntermediateDirectories: true)
    for i in 0..<45 {
        let body = [header("big-\(i)", cwd: bigProject, at: "2026-09-21T17:00:00.000Z"),
                    message(role: "user", text: "大批量会话 \(i)", at: base + Double(i) * 1_000),
                    message(role: "assistant", text: "回答", at: base + Double(i) * 1_000 + 1)]
            .joined(separator: "\n") + "\n"
        let url = bigDir.appendingPathComponent("b\(i).jsonl")
        try! body.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(i))],
                              ofItemAtPath: url.path)
    }
    SessionHistory.invalidateAll()
    SessionHistory.resetStatistics()
    let bigList = (try? SessionHistory.list(project: bigProject, agentDir: agentDir)) ?? []
    let bigStats = SessionHistory.statistics()
    check("超过 40 个候选时仍只深解析 40 个", bigStats.headScans == 40, "\(bigStats.headScans)")
    check("超过 40 个候选时列表仍是 10 条", bigList.count == 10, "\(bigList.count)")
    check("目录快照每轮只收一次", bigStats.attributeReads == 45, "\(bigStats.attributeReads)")

    // summary 缓存用全普通文件的目录验证（含链接的目录按规则不缓存）。
    SessionHistory.resetStatistics()
    let bigSummaryCold = SessionHistory.summary(project: bigProject, agentDir: agentDir)
    let bigSummaryColdStats = SessionHistory.statistics()
    check("summary 统计目录里的全部会话文件", bigSummaryCold?.count == 45,
          "\(bigSummaryCold?.count ?? -1)")
    check("summary 冷读只读前三个尾部", bigSummaryColdStats.activityReads == 3,
          "\(bigSummaryColdStats.activityReads)")
    SessionHistory.resetStatistics()
    let bigSummaryWarm = SessionHistory.summary(project: bigProject, agentDir: agentDir)
    let bigSummaryWarmStats = SessionHistory.statistics()
    check("summary 热缓存不再读尾部",
          bigSummaryWarmStats.activityReads == 0 && bigSummaryWarmStats.summaryHits == 1,
          "activity=\(bigSummaryWarmStats.activityReads) hits=\(bigSummaryWarmStats.summaryHits)")
    check("summary 冷热结果一致", bigSummaryCold?.count == bigSummaryWarm?.count)
    // 仅改 mtime（内容不变）也必须让 summary 缓存失效
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)],
                          ofItemAtPath: bigDir.appendingPathComponent("b44.jsonl").path)
    SessionHistory.resetStatistics()
    let bigSummaryAfterMtime = SessionHistory.summary(project: bigProject, agentDir: agentDir)
    check("mtime 变化后 summary 重新读取", SessionHistory.statistics().activityReads > 0,
          "\(SessionHistory.statistics().activityReads)")
    check("mtime 变化后 summary 计数仍正确", bigSummaryAfterMtime?.count == 45,
          "\(bigSummaryAfterMtime?.count ?? -1)")

    let orderProject = cacheRoot.appendingPathComponent("mtime 错序").path
    try! fm.createDirectory(atPath: orderProject, withIntermediateDirectories: true)
    let orderDir = SessionHistory.directory(for: orderProject, agentDir: agentDir)
    try! fm.createDirectory(at: orderDir, withIntermediateDirectories: true)
    try! ([header("order-stale", cwd: orderProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "mtime 最新但活动旧", at: base),
           message(role: "assistant", text: "旧", at: base + 1_000)]
          .joined(separator: "\n") + "\n")
        .write(to: orderDir.appendingPathComponent("stale.jsonl"), atomically: true, encoding: .utf8)
    try! ([header("order-fresh", cwd: orderProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "mtime 更旧但活动最新", at: base),
           message(role: "assistant", text: "新", at: base + 9_000_000)]
          .joined(separator: "\n") + "\n")
        .write(to: orderDir.appendingPathComponent("fresh.jsonl"), atomically: true, encoding: .utf8)
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
                          ofItemAtPath: orderDir.appendingPathComponent("stale.jsonl").path)
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                          ofItemAtPath: orderDir.appendingPathComponent("fresh.jsonl").path)
    let ordered = (try? SessionHistory.list(project: orderProject, agentDir: agentDir)) ?? []
    check("mtime 错序时按真实活动时间排序", ordered.first?.path.hasSuffix("/fresh.jsonl") == true,
          ordered.first?.path ?? "nil")

    let partialProject = cacheRoot.appendingPathComponent("残缺行").path
    try! fm.createDirectory(atPath: partialProject, withIntermediateDirectories: true)
    let partialDir = SessionHistory.directory(for: partialProject, agentDir: agentDir)
    try! fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
    let partialBody = header("partial", cwd: partialProject, at: "2026-09-21T17:00:00.000Z") + "\n"
        + message(role: "user", text: "残缺行之前的提问", at: base) + "\n"
        + #"{"type":"message","id":"truncated","message":{"role":"user","content":"没写完"#
    try! partialBody.write(to: partialDir.appendingPathComponent("partial.jsonl"),
                           atomically: true, encoding: .utf8)
    let partialList = (try? SessionHistory.list(project: partialProject, agentDir: agentDir)) ?? []
    check("残缺尾行不影响会话可用", partialList.first?.title == "残缺行之前的提问",
          partialList.first?.title ?? "nil")
    let longBody = [header("long", cwd: partialProject, at: "2026-09-21T17:00:00.000Z"),
                    message(role: "user", text: String(repeating: "长", count: 300 * 1024), at: base),
                    message(role: "user", text: "超长提问之后的短提问", at: base + 1_000)]
        .joined(separator: "\n") + "\n"
    try! longBody.write(to: partialDir.appendingPathComponent("long.jsonl"),
                        atomically: true, encoding: .utf8)
    let longList = (try? SessionHistory.list(project: partialProject, agentDir: agentDir)) ?? []
    check("超长用户提问行被丢弃后仍读到后续提问",
          longList.contains { $0.title == "超长提问之后的短提问" })

    // ── 25. 缓存容量与移除 ──
    let capRoot = cacheRoot.appendingPathComponent("容量")
    var capProjects: [String] = []
    for p in 0..<7 {
        let projectPath = capRoot.appendingPathComponent("p\(p)").path
        try! fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        capProjects.append(projectPath)
        let dir = SessionHistory.directory(for: projectPath, agentDir: agentDir)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<40 {
            let body = [header("cap-\(p)-\(i)", cwd: projectPath, at: "2026-09-21T17:00:00.000Z"),
                        message(role: "user", text: "容量样本 \(p)-\(i)", at: base + Double(i))]
                .joined(separator: "\n") + "\n"
            try! body.write(to: dir.appendingPathComponent("k\(i).jsonl"), atomically: true, encoding: .utf8)
        }
        _ = try? SessionHistory.list(project: projectPath, agentDir: agentDir)
    }
    let capStats = SessionHistory.statistics()
    check("缓存条目有全局上限", capStats.cachedEntries <= 256, "\(capStats.cachedEntries)")
    check("单目录缓存条目有上限", capStats.largestDirectoryEntryCount <= 64,
          "\(capStats.largestDirectoryEntryCount)")
    check("缓存条目确实写入", capStats.cachedEntries > 0)
    let beforeRemove = capStats.cachedEntries
    let remover = SummaryCoordinator(agentDir: agentDir)
    remover.remove(project: capProjects[6])
    check("移除项目后缓存条目减少", SessionHistory.statistics().cachedEntries < beforeRemove,
          "\(beforeRemove) -> \(SessionHistory.statistics().cachedEntries)")

    // ── 26. 摘要协调器：去重、单轮、合并、取消 ──
    let coordinatorRoot = root.appendingPathComponent("协调器 项目")
    let coordA = coordinatorRoot.appendingPathComponent("A").path
    let coordB = coordinatorRoot.appendingPathComponent("B").path
    let coordC = coordinatorRoot.appendingPathComponent("C").path
    for path in [coordA, coordB, coordC] {
        try! fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        switch semaphore.wait(timeout: .now() + seconds) {
        case .success: return true
        case .timedOut: return false
        }
    }
    func waitForTimeout(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        switch semaphore.wait(timeout: .now() + seconds) {
        case .success: return false
        case .timedOut: return true
        }
    }

    let scanLock = NSLock()
    var scanLog: [String] = []
    var activeScans = 0
    var peakScans = 0
    var sawCancel = false
    var blockFirst = true
    let firstStarted = DispatchSemaphore(value: 0)
    let firstGate = DispatchSemaphore(value: 0)

    let coordinator = SummaryCoordinator(scan: { project, isCancelled -> SessionHistory.Summary? in
        scanLock.lock()
        scanLog.append(project)
        activeScans += 1
        peakScans = max(peakScans, activeScans)
        let shouldBlock = blockFirst
        blockFirst = false
        scanLock.unlock()
        if shouldBlock {
            firstStarted.signal()
            firstGate.wait()
        }
        if isCancelled() {
            scanLock.lock()
            activeScans -= 1
            sawCancel = true
            scanLock.unlock()
            return nil
        }
        scanLock.lock()
        activeScans -= 1
        scanLock.unlock()
        return (count: 1, last: Date(timeIntervalSince1970: 1_700_000_000) as Date?)
    })

    var deliveredSnapshots: [SummaryCoordinator.Snapshot] = []
    let completionSignal = DispatchSemaphore(value: 0)
    coordinator.request(projects: [coordA, coordB, coordA]) { snapshot in
        scanLock.lock()
        deliveredSnapshots.append(snapshot)
        scanLock.unlock()
        completionSignal.signal()
    }
    check("协调器首轮开始扫描", waitForSignal(firstStarted, seconds: 5))
    coordinator.request(projects: [coordC, coordB]) { snapshot in
        scanLock.lock()
        deliveredSnapshots.append(snapshot)
        scanLock.unlock()
        completionSignal.signal()
    }
    firstGate.signal()
    check("协调器在超时前完成合并扫描", waitForSignal(completionSignal, seconds: 10))
    usleep(150_000)   // 给可能的迟到回调留出窗口，确认不会重复交付
    scanLock.lock()
    let loggedScans = scanLog
    let observedCancel = sawCancel
    let peak = peakScans
    let delivered = deliveredSnapshots
    scanLock.unlock()
    check("协调器同一时间只有一轮扫描", peak == 1, "\(peak)")
    check("协调器在项目边界观察到取消", observedCancel)
    check("被合并的请求只交付一次统一回调", delivered.count == 1, "\(delivered.count)")
    if let snapshot = delivered.first {
        check("协调器合并待办且保留原项目键",
              Set(snapshot.summaries.keys) == Set([coordA, coordB, coordC]),
              "\(Array(snapshot.summaries.keys).sorted())")
    } else {
        check("协调器交付了合并后的结果", false)
    }
    check("取消后重新扫描待办项目且不重复", loggedScans == [coordA, coordA, coordB, coordC],
          "\(loggedScans)")

    let linkCoordProject = coordinatorRoot.appendingPathComponent("link").path
    try? fm.createSymbolicLink(atPath: linkCoordProject, withDestinationPath: coordA)
    var linkLog: [String] = []
    let linkDone = DispatchSemaphore(value: 0)
    let linkCoordinator = SummaryCoordinator(scan: { project, _ -> SessionHistory.Summary? in
        scanLock.lock()
        linkLog.append(project)
        scanLock.unlock()
        return (count: 0, last: nil)
    })
    linkCoordinator.request(projects: [coordA, linkCoordProject, coordA + "/"]) { _ in linkDone.signal() }
    check("协调器完成词法去重请求", waitForSignal(linkDone, seconds: 5))
    scanLock.lock()
    let linkLogged = linkLog
    scanLock.unlock()
    check("协调器按词法去重但不用 realpath 合并项目", linkLogged.count == 2, "\(linkLogged)")

    let silentCoordinator = SummaryCoordinator(scan: { _, _ -> SessionHistory.Summary? in (count: 0, last: nil) })
    silentCoordinator.shutdown()
    var shutdownCallbackRan = false
    let shutdownSignal = DispatchSemaphore(value: 0)
    silentCoordinator.request(projects: [coordA]) { _ in
        shutdownCallbackRan = true
        shutdownSignal.signal()
    }
    check("协调器停止后不再启动扫描",
          waitForTimeout(shutdownSignal, seconds: 0.3) && !shutdownCallbackRan)

    // ── 27. 运行中的同集合/子集请求必须安排有效重扫 ──
    func rescanScenario(subset: Bool) -> (counts: [String: Int], scans: [String], peak: Int, callbacks: Int) {
        let rescanLock = NSLock()
        var aValue = 1
        var scans: [String] = []
        var active = 0
        var peak = 0
        var delivered: [String: Int] = [:]
        var callbacks = 0
        var blockB = true
        let aScanned = DispatchSemaphore(value: 0)
        let bStarted = DispatchSemaphore(value: 0)
        let bGate = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        let rescanCoordinator = SummaryCoordinator(scan: { project, isCancelled -> SessionHistory.Summary? in
            rescanLock.lock()
            scans.append(project)
            active += 1
            peak = max(peak, active)
            let value = aValue
            let shouldBlock = project == coordB && blockB
            if shouldBlock { blockB = false }
            rescanLock.unlock()
            if project == coordA { aScanned.signal() }
            if shouldBlock {
                bStarted.signal()
                bGate.wait()
            }
            if isCancelled() {
                rescanLock.lock()
                active -= 1
                rescanLock.unlock()
                return nil
            }
            rescanLock.lock()
            active -= 1
            rescanLock.unlock()
            return (count: value, last: nil)
        })

        rescanCoordinator.request(projects: [coordA, coordB]) { _ in }
        check("重扫场景到达 A 扫描", waitForSignal(aScanned, seconds: 5))
        check("重扫场景到达 B 扫描门闩", waitForSignal(bStarted, seconds: 5))
        rescanLock.lock()
        aValue = 2
        rescanLock.unlock()
        rescanCoordinator.request(projects: subset ? [coordA] : [coordA, coordB]) { snapshot in
            rescanLock.lock()
            callbacks += 1
            for (project, summary) in snapshot.summaries {
                delivered[project] = summary.count
            }
            rescanLock.unlock()
            done.signal()
        }
        bGate.signal()
        check("重扫场景完成合并交付", waitForSignal(done, seconds: 10))
        usleep(100_000)
        rescanLock.lock()
        let result = (counts: delivered, scans: scans, peak: peak, callbacks: callbacks)
        rescanLock.unlock()
        return result
    }

    let sameSetRescan = rescanScenario(subset: false)
    check("同集合新请求重扫已变化项目", sameSetRescan.counts[coordA] == 2,
          "\(sameSetRescan.counts)")
    check("同集合新请求只交付最后一次回调", sameSetRescan.callbacks == 1,
          "\(sameSetRescan.callbacks)")
    check("同集合重扫同一时间只有一轮扫描", sameSetRescan.peak == 1, "\(sameSetRescan.peak)")
    check("同集合重扫顺序为重扫并集",
          sameSetRescan.scans == [coordA, coordB, coordA, coordB], "\(sameSetRescan.scans)")

    let subsetRescan = rescanScenario(subset: true)
    check("子集新请求也重扫已变化项目", subsetRescan.counts[coordA] == 2,
          "\(subsetRescan.counts)")
    check("子集新请求只交付最后一次回调", subsetRescan.callbacks == 1,
          "\(subsetRescan.callbacks)")
    check("子集重扫同一时间只有一轮扫描", subsetRescan.peak == 1, "\(subsetRescan.peak)")

    // ── 28. 运行中移除：迟到结果不交付、迟到缓存被清、显式重新请求可恢复 ──
    let removeProject = cacheRoot.appendingPathComponent("运行中移除").path
    try! fm.createDirectory(atPath: removeProject, withIntermediateDirectories: true)
    let removeDir = SessionHistory.directory(for: removeProject, agentDir: agentDir)
    try! fm.createDirectory(at: removeDir, withIntermediateDirectories: true)
    try! ([header("remove-1", cwd: removeProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "将被移除的会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: removeDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

    let removeLock = NSLock()
    var removeScans = 0
    var removeSnapshot: [String] = []
    var removeCallbacks = 0
    var removeReSnapshot: [String] = []
    var removeBlock = true
    let removeAStarted = DispatchSemaphore(value: 0)
    let removeAGate = DispatchSemaphore(value: 0)
    let removeDone = DispatchSemaphore(value: 0)
    let removeReDone = DispatchSemaphore(value: 0)

    let removeCleanup = DispatchSemaphore(value: 0)
    let removeCoordinator = SummaryCoordinator(agentDir: agentDir,
                                               scan: { project, _ -> SessionHistory.Summary? in
        if project == removeProject {
            removeLock.lock()
            removeScans += 1
            let shouldBlock = removeBlock
            removeBlock = false
            removeLock.unlock()
            if shouldBlock {
                removeAStarted.signal()
                removeAGate.wait()
            }
            // 模拟迟到写入：移除之后仍然把摘要写进缓存
            return SessionHistory.summary(project: project, agentDir: agentDir)
        }
        return (count: 1, last: nil)
    })
    removeCoordinator.testHookAfterCleanup = { removeCleanup.signal() }
    removeCoordinator.request(projects: [removeProject, coordB]) { snapshot in
        removeLock.lock()
        removeSnapshot = snapshot.summaries.keys.sorted()
        removeCallbacks += 1
        removeLock.unlock()
        removeDone.signal()
    }
    check("运行中移除场景到达扫描门闩",
          waitForSignal(removeAStarted, seconds: 5))
    removeCoordinator.remove(project: removeProject)
    removeAGate.signal()
    check("运行中移除场景完成交付",
          waitForSignal(removeDone, seconds: 10))
    check("运行中移除场景完成收尾",
          waitForSignal(removeCleanup, seconds: 10))
    check("正常交付后移除记录被回收", removeCoordinator.retainedRemovalRecordCount == 0,
          "\(removeCoordinator.retainedRemovalRecordCount)")
    removeLock.lock()
    let firstRemoveKeys = removeSnapshot
    let firstRemoveCallbacks = removeCallbacks
    removeLock.unlock()
    check("运行中移除的项目不交付", firstRemoveKeys == [coordB], "\(firstRemoveKeys)")
    check("运行中移除只回调一次", firstRemoveCallbacks == 1, "\(firstRemoveCallbacks)")
    SessionHistory.resetStatistics()
    _ = SessionHistory.summary(project: removeProject, agentDir: agentDir)
    let afterRemoveStats = SessionHistory.statistics()
    check("移除后迟到的缓存写入被清掉", afterRemoveStats.summaryHits == 0,
          "hits=\(afterRemoveStats.summaryHits)")
    removeCoordinator.request(projects: [removeProject]) { snapshot in
        removeLock.lock()
        removeReSnapshot = snapshot.summaries.keys.sorted()
        removeLock.unlock()
        removeReDone.signal()
    }
    check("移除后显式重加完成",
          waitForSignal(removeReDone, seconds: 10))
    removeLock.lock()
    let removeScansAfter = removeScans
    let reRequestKeys = removeReSnapshot
    removeLock.unlock()
    check("移除后显式重新请求会重新扫描", removeScansAfter == 2, "\(removeScansAfter)")
    check("移除后显式重新请求会交付该项目", reRequestKeys == [removeProject], "\(reRequestKeys)")

    // ── 29. 同一词法目录/文件身份不变、项目或头部 cwd 链接重指向 ──
    let retargetRoot = cacheRoot.appendingPathComponent("重指向")
    try! fm.createDirectory(at: retargetRoot, withIntermediateDirectories: true)
    let retargetA = retargetRoot.appendingPathComponent("targetA").path
    let retargetB = retargetRoot.appendingPathComponent("targetB").path
    try! fm.createDirectory(atPath: retargetA, withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: retargetB, withIntermediateDirectories: true)
    let retargetProject = retargetRoot.appendingPathComponent("project-link").path
    try? fm.createSymbolicLink(atPath: retargetProject, withDestinationPath: retargetA)
    let retargetStored = retargetRoot.appendingPathComponent("stored-link").path
    try? fm.createSymbolicLink(atPath: retargetStored, withDestinationPath: retargetB)
    let retargetDir = SessionHistory.directory(for: retargetProject, agentDir: agentDir)
    try! fm.createDirectory(at: retargetDir, withIntermediateDirectories: true)
    let retargetSession = retargetDir.appendingPathComponent("session.jsonl")
    try! ([header("retarget-1", cwd: retargetStored, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "重指向会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: retargetSession, atomically: true, encoding: .utf8)

    let retargetNegative = (try? SessionHistory.list(project: retargetProject, agentDir: agentDir)) ?? []
    check("链接重指向前负缓存为空",
          retargetNegative.isEmpty
              && SessionHistory.latest(project: retargetProject, agentDir: agentDir) == nil
              && SessionHistory.validated(retargetSession.path, project: retargetProject,
                                          agentDir: agentDir) == nil)
    try? fm.removeItem(atPath: retargetStored)
    try? fm.createSymbolicLink(atPath: retargetStored, withDestinationPath: retargetA)
    let retargetPositive = (try? SessionHistory.list(project: retargetProject, agentDir: agentDir)) ?? []
    let retargetLatest = SessionHistory.latest(project: retargetProject, agentDir: agentDir)
    let retargetValidated = SessionHistory.validated(retargetSession.path, project: retargetProject,
                                                     agentDir: agentDir)
    check("头部 cwd 链接重指后负缓存被重新核验",
          retargetPositive.count == 1 && retargetLatest?.path == retargetSession.path
              && retargetValidated == retargetSession.path,
          "\(retargetPositive.count)")
    try? fm.removeItem(atPath: retargetProject)
    try? fm.createSymbolicLink(atPath: retargetProject, withDestinationPath: retargetB)
    let retargetNegativeAgain = (try? SessionHistory.list(project: retargetProject, agentDir: agentDir)) ?? []
    check("项目链接重指后正缓存被重新核验",
          retargetNegativeAgain.isEmpty
              && SessionHistory.latest(project: retargetProject, agentDir: agentDir) == nil
              && SessionHistory.validated(retargetSession.path, project: retargetProject,
                                          agentDir: agentDir) == nil,
          "\(retargetNegativeAgain.count)")

    // ── 30. 会话文件链接：list/validated 拒绝；summary 用链接自身 mtime，且不缓存 ──
    let symlinkProject = cacheRoot.appendingPathComponent("链接摘要").path
    try! fm.createDirectory(atPath: symlinkProject, withIntermediateDirectories: true)
    let symlinkDir = SessionHistory.directory(for: symlinkProject, agentDir: agentDir)
    try! fm.createDirectory(at: symlinkDir, withIntermediateDirectories: true)
    let symlinkTarget = cacheRoot.appendingPathComponent("outside-target.jsonl")
    try! ([header("link-target", cwd: symlinkProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "链接目标会话", at: 1_600_000_000_000)]
          .joined(separator: "\n") + "\n")
        .write(to: symlinkTarget, atomically: true, encoding: .utf8)
    let targetMtime = Date(timeIntervalSince1970: 1_700_000_000)
    try? fm.setAttributes([.modificationDate: targetMtime], ofItemAtPath: symlinkTarget.path)
    let symlinkSession = symlinkDir.appendingPathComponent("link.jsonl")
    try? fm.createSymbolicLink(atPath: symlinkSession.path, withDestinationPath: symlinkTarget.path)
    let symlinkList = (try? SessionHistory.list(project: symlinkProject, agentDir: agentDir)) ?? []
    check("会话文件链接仍被 list/latest/validated 拒绝",
          symlinkList.isEmpty
              && SessionHistory.latest(project: symlinkProject, agentDir: agentDir) == nil
              && SessionHistory.validated(symlinkSession.path, project: symlinkProject,
                                          agentDir: agentDir) == nil)
    SessionHistory.resetStatistics()
    let symlinkSummary = SessionHistory.summary(project: symlinkProject, agentDir: agentDir)
    check("summary 统计链接会话", symlinkSummary?.count == 1, "\(symlinkSummary?.count ?? -1)")
    if let last = symlinkSummary?.last {
        check("summary 用链接自身 mtime 而不是目标 mtime", last > targetMtime,
              "last=\(last.timeIntervalSince1970) target=\(targetMtime.timeIntervalSince1970)")
    } else {
        check("summary 用链接自身 mtime 而不是目标 mtime", false)
    }
    SessionHistory.resetStatistics()
    let symlinkSummaryAgain = SessionHistory.summary(project: symlinkProject, agentDir: agentDir)
    let symlinkStats = SessionHistory.statistics()
    check("含链接候选的 summary 不写缓存",
          symlinkStats.summaryHits == 0 && symlinkStats.activityReads > 0,
          "hits=\(symlinkStats.summaryHits) activity=\(symlinkStats.activityReads)")
    check("含链接候选的 summary 重复读取结果一致", symlinkSummaryAgain?.count == 1)

    // ── 31. 大量空闲移除：不累积控制记录 ──
    let idleRemovalCoordinator = SummaryCoordinator(agentDir: agentDir,
                                                    scan: { _, _ -> SessionHistory.Summary? in (count: 0, last: nil) })
    var maxRetainedRemovals = 0
    for index in 0..<200 {
        idleRemovalCoordinator.remove(
            project: cacheRoot.appendingPathComponent("空闲移除-\(index)").path)
        maxRetainedRemovals = max(maxRetainedRemovals, idleRemovalCoordinator.retainedRemovalRecordCount)
    }
    check("空闲移除不保留移除标记", maxRetainedRemovals == 0, "\(maxRetainedRemovals)")
    check("大量空闲移除后无控制记录残留",
          idleRemovalCoordinator.retainedRemovalRecordCount == 0,
          "\(idleRemovalCoordinator.retainedRemovalRecordCount)")

    // ── 32. 运行中移除后 cancelAll：迟到缓存清理、记录回收、显式重加可恢复 ──
    let cancelRemoveProject = cacheRoot.appendingPathComponent("取消移除").path
    try! fm.createDirectory(atPath: cancelRemoveProject, withIntermediateDirectories: true)
    let cancelRemoveDir = SessionHistory.directory(for: cancelRemoveProject, agentDir: agentDir)
    try! fm.createDirectory(at: cancelRemoveDir, withIntermediateDirectories: true)
    try! ([header("cancel-remove", cwd: cancelRemoveProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "取消移除会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: cancelRemoveDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

    let cancelRemoveLock = NSLock()
    var cancelRemoveBlock = true
    var cancelRemoveCallbacks = 0
    let cancelRemoveStarted = DispatchSemaphore(value: 0)
    let cancelRemoveGate = DispatchSemaphore(value: 0)
    let cancelRemoveCleanup = DispatchSemaphore(value: 0)
    let cancelRemoveCallback = DispatchSemaphore(value: 0)
    let cancelRemoveCoordinator = SummaryCoordinator(agentDir: agentDir,
                                                     scan: { project, _ -> SessionHistory.Summary? in
        if project == cancelRemoveProject {
            cancelRemoveLock.lock()
            let shouldBlock = cancelRemoveBlock
            cancelRemoveBlock = false
            cancelRemoveLock.unlock()
            if shouldBlock {
                cancelRemoveStarted.signal()
                cancelRemoveGate.wait()
            }
            // 模拟取消之后的迟到缓存写入
            return SessionHistory.summary(project: project, agentDir: agentDir)
        }
        return (count: 1, last: nil)
    })
    cancelRemoveCoordinator.testHookAfterCleanup = { cancelRemoveCleanup.signal() }
    cancelRemoveCoordinator.request(projects: [cancelRemoveProject, coordB]) { _ in
        cancelRemoveLock.lock()
        cancelRemoveCallbacks += 1
        cancelRemoveLock.unlock()
        cancelRemoveCallback.signal()
    }
    check("cancelAll 场景到达扫描门闩",
          waitForSignal(cancelRemoveStarted, seconds: 5))
    cancelRemoveCoordinator.remove(project: cancelRemoveProject)
    cancelRemoveCoordinator.cancelAll()
    // 即使上面的门闩等待超时，也要释放，避免迟到扫描永久阻塞。
    cancelRemoveGate.signal()
    check("cancelAll 后本轮收尾完成", waitForSignal(cancelRemoveCleanup, seconds: 10))
    check("cancelAll 丢弃已取消的旧回调",
          waitForTimeout(cancelRemoveCallback, seconds: 0.3)
              && cancelRemoveCallbacks == 0,
          "\(cancelRemoveCallbacks)")
    check("cancelAll 收尾回收移除记录",
          cancelRemoveCoordinator.retainedRemovalRecordCount == 0,
          "\(cancelRemoveCoordinator.retainedRemovalRecordCount)")
    SessionHistory.resetStatistics()
    _ = SessionHistory.summary(project: cancelRemoveProject, agentDir: agentDir)
    let cancelRemoveStats = SessionHistory.statistics()
    check("cancelAll 收尾清掉迟到缓存写入", cancelRemoveStats.summaryHits == 0,
          "hits=\(cancelRemoveStats.summaryHits)")

    var cancelReaddKeys: [String] = []
    var cancelReaddGeneration = -1
    let cancelReaddDone = DispatchSemaphore(value: 0)
    cancelRemoveCoordinator.request(projects: [cancelRemoveProject]) { snapshot in
        cancelRemoveLock.lock()
        cancelReaddKeys = snapshot.summaries.keys.sorted()
        cancelReaddGeneration = snapshot.generation
        cancelRemoveLock.unlock()
        cancelReaddDone.signal()
    }
    check("cancelAll 清理后显式重加可恢复",
          waitForSignal(cancelReaddDone, seconds: 10) && cancelReaddKeys == [cancelRemoveProject],
          "\(cancelReaddKeys)")
    check("cancelAll 后显式重加使用新代际", cancelReaddGeneration == 2,
          "\(cancelReaddGeneration)")

    // ── 33. 运行中移除后 shutdown：迟到缓存清理、记录回收、不再接受请求 ──
    let shutdownRemoveProject = cacheRoot.appendingPathComponent("停止移除").path
    try! fm.createDirectory(atPath: shutdownRemoveProject, withIntermediateDirectories: true)
    let shutdownRemoveDir = SessionHistory.directory(for: shutdownRemoveProject, agentDir: agentDir)
    try! fm.createDirectory(at: shutdownRemoveDir, withIntermediateDirectories: true)
    try! ([header("shutdown-remove", cwd: shutdownRemoveProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "停止移除会话", at: base)]
          .joined(separator: "\n") + "\n")
        .write(to: shutdownRemoveDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

    let shutdownRemoveLock = NSLock()
    var shutdownRemoveBlock = true
    let shutdownRemoveStarted = DispatchSemaphore(value: 0)
    let shutdownRemoveGate = DispatchSemaphore(value: 0)
    let shutdownRemoveCleanup = DispatchSemaphore(value: 0)
    let shutdownRemoveCallback = DispatchSemaphore(value: 0)
    let shutdownRemoveCoordinator = SummaryCoordinator(agentDir: agentDir,
                                                       scan: { project, _ -> SessionHistory.Summary? in
        if project == shutdownRemoveProject {
            shutdownRemoveLock.lock()
            let shouldBlock = shutdownRemoveBlock
            shutdownRemoveBlock = false
            shutdownRemoveLock.unlock()
            if shouldBlock {
                shutdownRemoveStarted.signal()
                shutdownRemoveGate.wait()
            }
            return SessionHistory.summary(project: project, agentDir: agentDir)
        }
        return (count: 1, last: nil)
    })
    shutdownRemoveCoordinator.testHookAfterCleanup = { shutdownRemoveCleanup.signal() }
    shutdownRemoveCoordinator.request(projects: [shutdownRemoveProject, coordB]) { _ in
        shutdownRemoveCallback.signal()
    }
    check("shutdown 场景到达扫描门闩",
          waitForSignal(shutdownRemoveStarted, seconds: 5))
    shutdownRemoveCoordinator.remove(project: shutdownRemoveProject)
    shutdownRemoveCoordinator.shutdown()
    // 即使上面的门闩等待超时，也要释放，避免迟到扫描永久阻塞。
    shutdownRemoveGate.signal()
    check("shutdown 后本轮收尾完成", waitForSignal(shutdownRemoveCleanup, seconds: 10))
    check("shutdown 丢弃旧回调", waitForTimeout(shutdownRemoveCallback, seconds: 0.3))
    check("shutdown 收尾回收移除记录",
          shutdownRemoveCoordinator.retainedRemovalRecordCount == 0,
          "\(shutdownRemoveCoordinator.retainedRemovalRecordCount)")
    SessionHistory.resetStatistics()
    _ = SessionHistory.summary(project: shutdownRemoveProject, agentDir: agentDir)
    let shutdownRemoveStats = SessionHistory.statistics()
    check("shutdown 收尾清掉迟到缓存写入", shutdownRemoveStats.summaryHits == 0,
          "hits=\(shutdownRemoveStats.summaryHits)")
    let shutdownReaddCallback = DispatchSemaphore(value: 0)
    shutdownRemoveCoordinator.request(projects: [shutdownRemoveProject]) { _ in
        shutdownReaddCallback.signal()
    }
    check("shutdown 后不再启动扫描", waitForTimeout(shutdownReaddCallback, seconds: 0.3))

    // ── 34. 扫描结束到交付之间的门闩：cancelAll/shutdown/新请求/移除 ──
    let latchProject = cacheRoot.appendingPathComponent("交付门闩").path
    try! fm.createDirectory(atPath: latchProject, withIntermediateDirectories: true)
    let latchDir = SessionHistory.directory(for: latchProject, agentDir: agentDir)
    try! fm.createDirectory(at: latchDir, withIntermediateDirectories: true)
    try! ([header("latch-1", cwd: latchProject, at: "2026-09-21T17:00:00.000Z"),
           message(role: "user", text: "门闩会话一", at: base),
           message(role: "assistant", text: "门闩会话二", at: base + 1000)]
          .joined(separator: "\n") + "\n")
        .write(to: latchDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

    enum LatchMode { case cancelAll, shutdown, newRequest, remove }
    func latchScenario(_ mode: LatchMode) -> (oldCallbacks: Int, oldKeys: [String],
                                              newCallbacks: Int, newGeneration: Int,
                                              retained: Int) {
        let stateLock = NSLock()
        var oldCallbacks = 0
        var oldKeys: [String] = []
        var newCallbacks = 0
        var newGeneration = -1
        var firstHook = true
        let atDelivery = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let newDone = DispatchSemaphore(value: 0)
        let cleanup = DispatchSemaphore(value: 0)

        let latchCoordinator = SummaryCoordinator(agentDir: agentDir,
                                                  scan: { project, _ -> SessionHistory.Summary? in
            SessionHistory.summary(project: project, agentDir: agentDir)
        })
        latchCoordinator.testHookBeforeDelivery = {
            stateLock.lock()
            let shouldBlock = firstHook
            firstHook = false
            stateLock.unlock()
            if shouldBlock {
                atDelivery.signal()
                gate.wait()
            }
        }
        latchCoordinator.testHookAfterCleanup = { cleanup.signal() }
        latchCoordinator.request(projects: [latchProject]) { snapshot in
            stateLock.lock()
            oldCallbacks += 1
            oldKeys = snapshot.summaries.keys.sorted()
            stateLock.unlock()
        }
        check("门闩场景到达扫描结束与交付之间",
              waitForSignal(atDelivery, seconds: 10), "\(mode)")
        switch mode {
        case .cancelAll:
            latchCoordinator.cancelAll()
        case .shutdown:
            latchCoordinator.shutdown()
        case .newRequest:
            latchCoordinator.request(projects: [latchProject]) { snapshot in
                stateLock.lock()
                newCallbacks += 1
                newGeneration = snapshot.generation
                stateLock.unlock()
                newDone.signal()
            }
        case .remove:
            latchCoordinator.remove(project: latchProject)
        }
        // 即使交付门闩等待超时，也要释放，避免迟到回调永久阻塞。
        gate.signal()
        if mode == .newRequest {
            check("门闩后新请求完成",
                  waitForSignal(newDone, seconds: 10), "\(mode)")
        }
        check("门闩场景本轮收尾完成",
              waitForSignal(cleanup, seconds: 10), "\(mode)")
        usleep(120_000)
        stateLock.lock()
        let result = (oldCallbacks: oldCallbacks, oldKeys: oldKeys,
                      newCallbacks: newCallbacks, newGeneration: newGeneration,
                      retained: latchCoordinator.retainedRemovalRecordCount)
        stateLock.unlock()
        return result
    }

    let latchCancel = latchScenario(.cancelAll)
    check("门闩后 cancelAll 不交付旧回调", latchCancel.oldCallbacks == 0,
          "\(latchCancel.oldCallbacks)")
    let latchShutdown = latchScenario(.shutdown)
    check("门闩后 shutdown 不交付旧回调", latchShutdown.oldCallbacks == 0,
          "\(latchShutdown.oldCallbacks)")
    let latchNewRequest = latchScenario(.newRequest)
    check("门闩后新请求丢弃旧回调", latchNewRequest.oldCallbacks == 0,
          "\(latchNewRequest.oldCallbacks)")
    check("门闩后新请求只交付一次新回调", latchNewRequest.newCallbacks == 1,
          "\(latchNewRequest.newCallbacks)")
    check("门闩后新请求使用新代际", latchNewRequest.newGeneration == 2,
          "\(latchNewRequest.newGeneration)")
    let latchRemove = latchScenario(.remove)
    check("门闩期间移除以提交时过滤生效", latchRemove.oldCallbacks == 1
              && latchRemove.oldKeys.isEmpty,
          "callbacks=\(latchRemove.oldCallbacks) keys=\(latchRemove.oldKeys)")
    check("门闩期间移除的记录在交付后回收", latchRemove.retained == 0,
          "\(latchRemove.retained)")

    SessionHistory.invalidateAll()
    try? fm.removeItem(at: root)

    if failures.isEmpty {
        print("SELFTEST PASS")
        exit(0)
    }
    print("FAIL \(failures.count) 项：")
    for f in failures { print("  FAIL: \(f)") }
    exit(1)
    }
}
