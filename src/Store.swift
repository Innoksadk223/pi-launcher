// 项目列表存储
// 格式：每行一条，前缀 F=常用 / R=最近，制表符后为绝对路径。
// 文件不存在或为空都视为「还没有记录」，是正常情况，不是错误。

import Foundation

enum Store {
    static let maxRecent = 15

    /// 默认数据文件位置
    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PI Project Launcher/projects.txt")
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // ── 纯解析（可测试，不碰文件系统）──────────────────
    /// 把文本解析成 (favorites, recents)。`exists` 决定某个路径是否被接受。
    static func parse(_ text: String, exists: (String) -> Bool = isDirectory)
        -> (favorites: [String], recents: [String]) {
        var favorites: [String] = []
        var recents: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }          // 坏行直接跳过
            let kind = parts[0]
            let path = String(parts[1])
            guard path.hasPrefix("/"), exists(path) else { continue }
            if kind == "F" {
                if !favorites.contains(path) { favorites.append(path) }
            } else if kind == "R" {
                if !recents.contains(path) { recents.append(path) }
            }
        }
        return (favorites, recents)
    }

    /// 序列化为文件内容（末尾带换行；空列表得到空文本）
    static func serialize(favorites: [String], recents: [String]) -> String {
        var lines: [String] = []
        for p in favorites { lines.append("F\t\(p)") }
        for p in recents { lines.append("R\t\(p)") }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// 最近列表：新项置顶、去重、按上限截断
    static func pushRecent(_ path: String, into recents: [String], limit: Int = maxRecent) -> [String] {
        var updated = [path]
        for item in recents where item != path && updated.count < limit {
            updated.append(item)
        }
        return updated
    }

    // ── 文件读写 ──────────────────────────────────────

    static func load(from fileURL: URL = defaultFileURL) -> (favorites: [String], recents: [String]) {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return ([], []) }        // 首次使用：正常返回空列表，不报错
        return parse(text)
    }

    @discardableResult
    static func save(favorites: [String], recents: [String], to fileURL: URL = defaultFileURL) -> Bool {
        let body = serialize(favorites: favorites, recents: recents)
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 原子替换：先写临时文件再改名，避免中途失败留下半截数据
            let tmp = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp")
            try Data(body.utf8).write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    // ── 常用状态切换（纯逻辑，可测试）──────────────────

    /// 切换常用。取消常用时项目必须降级到「最近」，不能直接从列表消失。
    static func togglingFavorite(_ path: String, favorites: [String], recents: [String])
        -> (favorites: [String], recents: [String], madeFavorite: Bool) {
        var newFavorites = favorites
        var newRecents = recents
        let wasFavorite = favorites.contains(path)
        if wasFavorite {
            newFavorites.removeAll { $0 == path }
            if !newRecents.contains(path) {
                newRecents = pushRecent(path, into: newRecents)
            }
        } else {
            newFavorites.append(path)
        }
        return (newFavorites, newRecents, !wasFavorite)
    }

    /// 仅加入常用：已存在时不重复添加。与 togglingFavorite 一致，不改动「最近」列表
    /// （重复项由展示层去重）。added 用于区分「新加入」与「本来就在常用里」。
    static func addingFavorite(_ path: String, favorites: [String], recents: [String])
        -> (favorites: [String], recents: [String], added: Bool) {
        guard !favorites.contains(path) else { return (favorites, recents, false) }
        return (favorites + [path], recents, true)
    }

    /// 从「最近」里移除一项。常用项不走这里（取消星标即可，会降级到最近）。
    /// 移除是显式动作：项目不会被自动加回来，除非再次打开。
    static func removingRecent(_ path: String, favorites: [String], recents: [String])
        -> (favorites: [String], recents: [String]) {
        (favorites, recents.filter { $0 != path })
    }
}
