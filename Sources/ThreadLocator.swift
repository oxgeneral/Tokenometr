import Foundation
import SQLite3

struct LocatedThread {
    let id: String
    let name: String
    let reasoningEffort: String?
}

struct ThreadLocator {
    let home: URL

    func latest() -> LocatedThread? {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let candidates = files.filter { $0.lastPathComponent.range(of: #"^state_\d+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { version($0) > version($1) }
        guard let path = candidates.first else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let queries = [
            "SELECT id, title, reasoning_effort FROM threads WHERE archived=0 AND thread_source='user' AND source IN ('vscode','appServer') ORDER BY updated_at DESC LIMIT 1",
            "SELECT id, title FROM threads WHERE archived=0 AND thread_source='user' AND source IN ('vscode','appServer') ORDER BY updated_at DESC LIMIT 1",
            "SELECT id, title, reasoning_effort FROM threads WHERE archived=0 AND source IN ('vscode','appServer') ORDER BY updated_at DESC LIMIT 1",
            "SELECT id, title FROM threads WHERE archived=0 AND source IN ('vscode','appServer') ORDER BY updated_at DESC LIMIT 1"
        ]
        for query in queries {
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK { break }
            sqlite3_finalize(statement); statement = nil
        }
        guard let statement = statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let id = sqlite3_column_text(statement, 0) else { return nil }
        let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "Codex"
        let effort = sqlite3_column_count(statement) > 2
            ? sqlite3_column_text(statement, 2).map { String(cString: $0) } : nil
        return LocatedThread(id: String(cString: id), name: title, reasoningEffort: effort?.isEmpty == false ? effort : nil)
    }

    private func version(_ url: URL) -> Int { Int(url.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "0") ?? 0 }
}
