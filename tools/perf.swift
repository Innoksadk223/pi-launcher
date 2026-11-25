// 会话读取性能采样工具（样本有上限、只写自己的临时目录、采样后退出，不常驻）。
//
// 用法：
//   swiftc -O -o /tmp/perf tools/perf.swift src/SessionHistory.swift
//   /tmp/perf [--root <目录>] [--runs 5] [--projects 4] [--files 30] [--kilobytes 128]
//             [--output <json>] [--keep]
//
// 口径：
//   * 所有耗时都用 ProcessInfo.systemUptime 在本机实测；没有测量结果就不输出耗时。
//   * 同一进程内重复采样；文件系统热缓存，行顺序与集合遍历会带来运行间差异。
//   * fixture 是本工具新建的合成 JSONL（只有标题、填充正文和时间戳），不含真实会话正文。
//   * 每个 fixture 文件的 i == 1 故意做成「mtime 更旧、尾部活动最新」，用来观察排序口径。
//   * 样本总量上限 100 MiB；超限直接失败，不写出任何耗时。
//   * 默认结束即删掉本次新建的 fixture；--keep 时保留并在输出里给出路径。

import Foundation
import Dispatch

@main
struct PerfTool {
    struct Options {
        var root: URL?
        var runs = 5
        var projects = 4
        var files = 30
        var kilobytes = 128
        var output: URL?
        var keep = false
    }

    struct Fixture {
        let root: URL
        let agentDir: URL
        let projectPaths: [String]
        let fileCount: Int
        let byteCount: Int
        let mtimeOutOfOrder: Int
    }

    enum PerfError: Error, CustomStringConvertible {
        case fixtureTooLarge(Int)

        var description: String {
            switch self {
            case let .fixtureTooLarge(bytes):
                return "fixture 需要 \(bytes) 字节，超过 \(PerfTool.maximumFixtureBytes) 字节上限"
            }
        }
    }

    static let maximumFixtureBytes = 100 * 1024 * 1024
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func main() {
        let options = parseOptions(CommandLine.arguments)
        do {
            try run(options)
        } catch {
            fail("采样失败：\(error)")
        }
    }

    // ── 参数 ──────────────────────────────────────────

    static func parseOptions(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--root":
                index += 1
                guard index < arguments.count else { usage("--root 缺少目录") }
                options.root = URL(fileURLWithPath: arguments[index])
            case "--runs":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    usage("--runs 需要整数")
                }
                options.runs = value
            case "--projects":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    usage("--projects 需要整数")
                }
                options.projects = value
            case "--files":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    usage("--files 需要整数")
                }
                options.files = value
            case "--kilobytes":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    usage("--kilobytes 需要整数")
                }
                options.kilobytes = value
            case "--output":
                index += 1
                guard index < arguments.count else { usage("--output 缺少文件路径") }
                options.output = URL(fileURLWithPath: arguments[index])
            case "--keep":
                options.keep = true
            case "--help", "-h":
                usage("")
            default:
                usage("未知参数 \(argument)")
            }
            index += 1
        }
        guard options.runs >= 1, options.runs <= 20 else { usage("--runs 范围 1...20") }
        guard options.projects >= 1, options.projects <= 8 else { usage("--projects 范围 1...8") }
        guard options.files >= 1, options.files <= 40 else { usage("--files 范围 1...40（候选上限）") }
        guard options.kilobytes >= 1, options.kilobytes <= 1024 else { usage("--kilobytes 范围 1...1024") }
        return options
    }

    static func usage(_ message: String) -> Never {
        if !message.isEmpty {
            FileHandle.standardError.write(Data(("perf: " + message + "\n").utf8))
        }
        let text = "用法：perf [--root <目录>] [--runs N] [--projects N] [--files N] "
            + "[--kilobytes N] [--output <json>] [--keep]\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("perf: " + message + "\n").utf8))
        exit(2)
    }

    // ── 主流程 ────────────────────────────────────────

    static func run(_ options: Options) throws {
        let fileManager = FileManager.default
        let base = options.root ?? fileManager.temporaryDirectory.appendingPathComponent("pi-launcher-perf")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("fixture-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let agentDir = root.appendingPathComponent("agent")
        let fixture: Fixture
        do {
            fixture = try makeFixture(options, root: root, agentDir: agentDir)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
        defer {
            if !options.keep {
                try? fileManager.removeItem(at: fixture.root)
            }
        }

        var targets: [String] = []
        var targetIndex = 0
        while targets.count < 10 {
            targets.append(fixture.projectPaths[targetIndex % fixture.projectPaths.count])
            targetIndex += 1
        }
        let uniqueTargets = SummaryCoordinator.dedupe(targets)
        let firstProject = fixture.projectPaths[0]
        let validatedPath = SessionHistory.directory(for: firstProject, agentDir: agentDir)
            .appendingPathComponent("f0.jsonl").path

        var rows: [[String: Any]] = []
        for runIndex in 1...options.runs {
            rows.append(measure("list-cold", run: runIndex, prepare: { SessionHistory.invalidateAll() }) {
                let items = (try? SessionHistory.list(project: firstProject, agentDir: agentDir)) ?? []
                return "count=\(items.count) first=\(items.first?.title ?? "nil")"
            })
            rows.append(measure("list-warm", run: runIndex) {
                let items = (try? SessionHistory.list(project: firstProject, agentDir: agentDir)) ?? []
                return "count=\(items.count) first=\(items.first?.title ?? "nil")"
            })
            rows.append(measure("latest-warm", run: runIndex) {
                guard let item = SessionHistory.latest(project: firstProject, agentDir: agentDir) else {
                    return "nil"
                }
                return "file=\(URL(fileURLWithPath: item.path).lastPathComponent) path=\(item.path)"
            })
            rows.append(measure("validated-warm", run: runIndex) {
                SessionHistory.validated(validatedPath, project: firstProject, agentDir: agentDir) ?? "nil"
            })
            rows.append(measure("summary-cold-10-targets", run: runIndex,
                                prepare: { SessionHistory.invalidateAll() }) {
                targets.map { project -> String in
                    let value = SessionHistory.summary(project: project, agentDir: agentDir)
                    return "\(value?.count ?? -1)"
                }.joined(separator: ",")
            })
            rows.append(measure("summary-warm-10-targets", run: runIndex) {
                targets.map { project -> String in
                    let value = SessionHistory.summary(project: project, agentDir: agentDir)
                    return "\(value?.count ?? -1)"
                }.joined(separator: ",")
            })
            rows.append(measureCoordinator("coordinator-cold-10-targets", run: runIndex,
                                           targets: targets, agentDir: agentDir,
                                           prepare: { SessionHistory.invalidateAll() }))
            rows.append(measureCoordinator("coordinator-warm-10-targets", run: runIndex,
                                           targets: targets, agentDir: agentDir,
                                           prepare: {}))
        }

        let latestRows = rows.filter { $0["operation"] as? String == "latest-warm" }
        let validatedRows = rows.filter { $0["operation"] as? String == "validated-warm" }
        let coldCoordinatorRows = rows.filter { $0["operation"] as? String == "coordinator-cold-10-targets" }
        let latestNoCounts = latestRows.allSatisfy { row in
            guard let statistics = row["statistics"] as? [String: Any] else { return false }
            return (statistics["messageCountReads"] as? Int) == 0
                && (statistics["countHits"] as? Int) == 0
        }
        let validatedNoCounts = validatedRows.allSatisfy { row in
            guard let statistics = row["statistics"] as? [String: Any] else { return false }
            return (statistics["messageCountReads"] as? Int) == 0
                && (statistics["countHits"] as? Int) == 0
        }
        let coordinatorListings = coldCoordinatorRows.compactMap { row -> Int? in
            guard let statistics = row["statistics"] as? [String: Any] else { return nil }
            return statistics["directoryListings"] as? Int
        }
        let coldListRow = rows.first { $0["operation"] as? String == "list-cold" }
        let coldListResult = (coldListRow?["result"] as? String) ?? ""

        let fixtureInfo: [String: Any] = [
            "root": fixture.root.path,
            "removedAfterRun": !options.keep,
            "projects": options.projects,
            "filesPerProject": options.files,
            "fillerKilobytes": options.kilobytes,
            "files": fixture.fileCount,
            "bytes": fixture.byteCount,
            "mtimeOutOfOrderFiles": fixture.mtimeOutOfOrder,
            "summaryTargets": targets.count,
            "uniqueSummaryTargets": uniqueTargets.count
        ]
        let environmentInfo: [String: Any] = [
            "compiledWith": "swiftc -O tools/perf.swift src/SessionHistory.swift",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount
        ]
        let observations: [String: Any] = [
            "latestAndValidatedDidNotCountMessages": latestNoCounts && validatedNoCounts,
            "coordinatorColdDirectoryListings": coordinatorListings,
            "expectedUniqueSummaryTargets": uniqueTargets.count,
            "coldListResult": coldListResult
        ]

        let document: [String: Any] = [
            "tool": "tools/perf.swift",
            "generatedAt": isoFormatter.string(from: Date()),
            "method": [
                "所有耗时用 ProcessInfo.systemUptime 在本机实测；未测量的字段不填。",
                "缓存清空与 fixture 准备在计时之外；计时只包住被测操作。",
                "同一进程内重复采样；文件系统热缓存，行顺序与集合遍历会带来运行间差异。",
                "fixture 为本工具新建的合成 JSONL，不含任何真实会话正文。",
                "统计来自 SessionHistory.statistics()：属性读取、头部扫描、尾部读取、计数读取与缓存命中次数。"
            ],
            "limits": [
                "不同进程的冷启动、真实 PI 会话和终端耗时不在本工具范围。",
                "合成样本不能代表真实项目的文件大小、目录数量与内容分布。",
                "样本总量上限 \(maximumFixtureBytes) 字节；超限时工具直接失败，不输出任何耗时。",
                "summary 仍按原规则读取目录成员属性；它不代表历史页的读取成本。"
            ],
            "fixture": fixtureInfo,
            "environment": environmentInfo,
            "observations": observations,
            "rows": rows,
            "aggregates": aggregate(rows)
        ]

        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        if let output = options.output {
            try data.write(to: output, options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // ── fixture ───────────────────────────────────────

    static func makeFixture(_ options: Options, root: URL, agentDir: URL) throws -> Fixture {
        let fileManager = FileManager.default
        let filler = String(repeating: "z", count: options.kilobytes * 1024)
        var projectPaths: [String] = []
        var fileCount = 0
        var byteCount = 0
        var mtimeOutOfOrder = 0

        for projectIndex in 0..<options.projects {
            let projectURL = root.appendingPathComponent("projects/p\(projectIndex)")
            try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            projectPaths.append(projectURL.path)
            let sessions = SessionHistory.directory(for: projectURL.path, agentDir: agentDir)
            try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
            for fileIndex in 0..<options.files {
                let startMS = 1_760_000_000_000.0
                    + Double(projectIndex) * 10_000_000.0
                    + Double(fileIndex) * 1_000.0
                let outOfOrder = fileIndex == 1
                let lastMS = outOfOrder ? startMS + 900_000.0 : startMS
                let body = [
                    headerLine(id: "perf-\(projectIndex)-\(fileIndex)", cwd: projectURL.path, at: startMS),
                    messageLine(id: "u-\(projectIndex)-\(fileIndex)", role: "user",
                                text: "性能样本 \(projectIndex)-\(fileIndex)", at: startMS),
                    messageLine(id: "a-\(projectIndex)-\(fileIndex)", role: "assistant",
                                text: filler, at: startMS + 1),
                    messageLine(id: "z-\(projectIndex)-\(fileIndex)", role: "assistant",
                                text: "样本结束", at: lastMS)
                ].joined(separator: "\n") + "\n"
                let bytes = body.utf8.count
                guard byteCount + bytes <= maximumFixtureBytes else {
                    throw PerfError.fixtureTooLarge(byteCount + bytes)
                }
                let url = sessions.appendingPathComponent("f\(fileIndex).jsonl")
                try body.write(to: url, atomically: true, encoding: .utf8)
                byteCount += bytes
                fileCount += 1
                if outOfOrder { mtimeOutOfOrder += 1 }
                let mtimeMS = outOfOrder ? startMS - 600_000.0 : startMS
                try fileManager.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: mtimeMS / 1000)],
                    ofItemAtPath: url.path)
            }
        }
        return Fixture(root: root, agentDir: agentDir, projectPaths: projectPaths,
                       fileCount: fileCount, byteCount: byteCount, mtimeOutOfOrder: mtimeOutOfOrder)
    }

    static func jsonScalar(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let text = String(data: data, encoding: .utf8)!
        return String(text.dropFirst().dropLast())
    }

    static func headerLine(id: String, cwd: String, at milliseconds: Double) -> String {
        let iso = isoFormatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        return "{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\",\"timestamp\":\"\(iso)\",\"cwd\":\(jsonScalar(cwd))}"
    }

    static func messageLine(id: String, role: String, text: String, at milliseconds: Double) -> String {
        let iso = isoFormatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
        return "{\"type\":\"message\",\"id\":\"\(id)\",\"message\":{\"role\":\"\(role)\","
            + "\"content\":\(jsonScalar(text)),\"timestamp\":\(milliseconds)},\"timestamp\":\"\(iso)\"}"
    }

    // ── 采样 ──────────────────────────────────────────

    static func statsDictionary(_ statistics: SessionHistory.Statistics) -> [String: Any] {
        return [
            "directoryListings": statistics.directoryListings,
            "attributeReads": statistics.attributeReads,
            "stabilityAttributeReads": statistics.stabilityAttributeReads,
            "headScans": statistics.headScans,
            "activityReads": statistics.activityReads,
            "messageCountReads": statistics.messageCountReads,
            "metadataHits": statistics.metadataHits,
            "metadataMisses": statistics.metadataMisses,
            "countHits": statistics.countHits,
            "summaryHits": statistics.summaryHits,
            "cacheStores": statistics.cacheStores,
            "cachedEntries": statistics.cachedEntries,
            "cachedDirectories": statistics.cachedDirectories,
            "cachedSummaries": statistics.cachedSummaries,
            "largestDirectoryEntryCount": statistics.largestDirectoryEntryCount
        ]
    }

    static func measure(_ operation: String, run: Int,
                        prepare: () -> Void = {},
                        work: () -> String) -> [String: Any] {
        prepare()
        SessionHistory.resetStatistics()
        let start = ProcessInfo.processInfo.systemUptime
        let result = work()
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return [
            "operation": operation,
            "run": run,
            "milliseconds": milliseconds,
            "result": result,
            "statistics": statsDictionary(SessionHistory.statistics())
        ]
    }

    static func measureCoordinator(_ operation: String, run: Int, targets: [String],
                                   agentDir: URL, prepare: () -> Void) -> [String: Any] {
        prepare()
        SessionHistory.resetStatistics()
        let coordinator = SummaryCoordinator(agentDir: agentDir)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var delivered: [String] = []
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.request(projects: targets) { snapshot in
            lock.lock()
            delivered = snapshot.summaries.keys.sorted()
            lock.unlock()
            done.signal()
        }
        var timedOut = false
        switch done.wait(timeout: .now() + 60) {
        case .success:
            break
        case .timedOut:
            timedOut = true
            coordinator.cancelAll()
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let statistics = SessionHistory.statistics()
        lock.lock()
        let keys = delivered
        lock.unlock()
        return [
            "operation": operation,
            "run": run,
            "milliseconds": milliseconds,
            "timedOut": timedOut,
            "result": timedOut ? "timeout" : "count=\(keys.count)",
            "deliveredProjects": keys,
            "statistics": statsDictionary(statistics)
        ]
    }

    static func aggregate(_ rows: [[String: Any]]) -> [[String: Any]] {
        var grouped: [String: [Double]] = [:]
        for row in rows {
            guard let operation = row["operation"] as? String,
                  let milliseconds = row["milliseconds"] as? Double else { continue }
            grouped[operation, default: []].append(milliseconds)
        }
        return grouped.keys.sorted().map { operation -> [String: Any] in
            let values = (grouped[operation] ?? []).sorted()
            let median = values.isEmpty ? 0 : values[values.count / 2]
            return [
                "operation": operation,
                "samples": values.count,
                "minMilliseconds": values.first ?? 0,
                "medianMilliseconds": median,
                "maxMilliseconds": values.last ?? 0
            ]
        }
    }
}
