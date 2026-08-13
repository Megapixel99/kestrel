import Foundation

/// Bookmarks, history and session state, persisted as JSON under ~/.kestrel/.
///
/// Session restore matters more here than in most browsers: the COLD rung already
/// serialises a tab's scroll position and form state into a session image, so restoring
/// a window is the same mechanism applied across a restart rather than a new one.
enum Store {

    struct Bookmark: Codable, Equatable {
        var url: String
        var title: String
        var added: Date
    }

    struct HistoryEntry: Codable {
        var url: String
        var title: String
        var visited: Date
        var visits: Int
    }

    struct SessionTab: Codable {
        var url: String
        var title: String
        var interactionState: Data?     // the COLD session image, reused across restarts
        var pinned: Bool
        // interactionState covers scroll and back/forward history for a *live* tab and
        // carries no form contents at all, so both are stored explicitly.
        var scrollX: Double = 0
        var scrollY: Double = 0
        var formValues: [String: String] = [:]
    }

    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func load<T: Decodable>(_ name: String, _ fallback: T) -> T {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return v
    }
    private static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - bookmarks

    static var bookmarks: [Bookmark] = load("bookmarks.json", []) {
        didSet { save(bookmarks, "bookmarks.json") }
    }

    static func isBookmarked(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url.absoluteString }
    }

    @discardableResult
    static func toggleBookmark(_ url: URL, title: String) -> Bool {
        if let i = bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
            bookmarks.remove(at: i)
            return false
        }
        bookmarks.append(Bookmark(url: url.absoluteString, title: title, added: Date()))
        return true
    }

    // MARK: - history

    static var history: [HistoryEntry] = load("history.json", []) {
        didSet { if history.count % 10 == 0 { save(history, "history.json") } }
    }

    static func recordVisit(_ url: URL, title: String) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let s = url.absoluteString
        if let i = history.firstIndex(where: { $0.url == s }) {
            history[i].visits += 1
            history[i].visited = Date()
            history[i].title = title.isEmpty ? history[i].title : title
        } else {
            history.append(HistoryEntry(url: s, title: title, visited: Date(), visits: 1))
        }
        // Bounded: history is a convenience, not an archive.
        if history.count > 5000 {
            history.sort { $0.visited > $1.visited }
            history.removeLast(history.count - 4000)
        }
    }

    static func flush() {
        save(history, "history.json")
        save(bookmarks, "bookmarks.json")
    }

    /// Smart location bar: bookmarks first, then history, ranked by visits and recency.
    static func suggestions(for text: String, limit: Int = 8) -> [(String, String)] {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var out: [(String, String, Double)] = []
        for b in bookmarks where b.url.lowercased().contains(q)
                                 || b.title.lowercased().contains(q) {
            out.append((b.url, b.title, 1_000_000))          // bookmarks always win
        }
        for h in history where h.url.lowercased().contains(q)
                                || h.title.lowercased().contains(q) {
            let age = max(1, Date().timeIntervalSince(h.visited) / 3600)
            out.append((h.url, h.title, Double(h.visits) * 100 / age))
        }
        var seen = Set<String>()
        return out.sorted { $0.2 > $1.2 }
            .filter { seen.insert($0.0).inserted }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    // MARK: - session

    static func saveSession(_ tabs: [SessionTab]) { save(tabs, "session.json") }
    static func loadSession() -> [SessionTab] { load("session.json", []) }
}
