import AppKit

/// Importing bookmarks and history from the browsers already on this Mac.
///
/// Firefox documents Migration as a front-end component, and it is the one feature that
/// makes a new browser usable on day one — an address bar that suggests nothing is an
/// address bar that does nothing.
///
/// Everything here reads files the user already owns, on disk, read-only. Chrome's
/// bookmarks are JSON. Safari's are a binary plist. Firefox's are SQLite, and rather than
/// link a SQLite dependency for one feature, `places.sqlite` is read through the `sqlite3`
/// binary that ships with macOS — against a *copy*, because Firefox holds a lock on the
/// live file and reading it underneath a running browser is how you corrupt a profile.
enum Migration {

    struct Source {
        let name: String
        let bookmarks: () -> [Store.Bookmark]
        let history: () -> [Store.HistoryEntry]
        let available: () -> Bool
    }

    static var sources: [Source] {
        [
            Source(name: "Firefox",
                   bookmarks: { firefoxPlaces(historyInstead: false).0 },
                   history: { firefoxPlaces(historyInstead: true).1 },
                   available: { firefoxProfile() != nil }),
            Source(name: "Chrome",
                   bookmarks: { chromeBookmarks() },
                   history: { [] },
                   available: { FileManager.default.fileExists(atPath: chromeBookmarkFile.path) }),
            Source(name: "Safari",
                   bookmarks: { safariBookmarks() },
                   history: { [] },
                   available: { FileManager.default.fileExists(atPath: safariBookmarkFile.path) }),
        ]
    }

    // MARK: - Firefox

    private static func firefoxProfile() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        let profiles = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // The most recently touched profile is the one in use.
        return profiles
            .filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("places.sqlite").path) }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a < b
            }
    }

    /// Returns (bookmarks, history). Reads a copy: `places.sqlite` is locked while Firefox
    /// runs, and a WAL-mode database read in place can be both stale and damaging.
    private static func firefoxPlaces(historyInstead: Bool) -> ([Store.Bookmark],
                                                                [Store.HistoryEntry]) {
        guard let profile = firefoxProfile() else { return ([], []) }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-places-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = profile.appendingPathComponent("places.sqlite" + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(
                at: src, to: tmp.appendingPathComponent("places.sqlite" + suffix))
        }
        let db = tmp.appendingPathComponent("places.sqlite").path
        guard FileManager.default.fileExists(atPath: db) else { return ([], []) }

        let sql = historyInstead
            ? """
              SELECT p.url, IFNULL(p.title,''), p.visit_count,
                     IFNULL(p.last_visit_date,0)/1000000
              FROM moz_places p
              WHERE p.url LIKE 'http%' AND p.visit_count > 0
              ORDER BY p.last_visit_date DESC LIMIT 2000;
              """
            : """
              SELECT p.url, IFNULL(b.title, IFNULL(p.title,''))
              FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id
              WHERE b.type = 1 AND p.url LIKE 'http%';
              """
        guard let out = shell("/usr/bin/sqlite3", ["-separator", "\u{1}", db, sql]) else {
            return ([], [])
        }

        var marks: [Store.Bookmark] = []
        var visits: [Store.HistoryEntry] = []
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "\u{1}")
            guard f.count >= 2, let url = URL(string: f[0]) else { continue }
            if historyInstead {
                let count = f.count > 2 ? Int(f[2]) ?? 1 : 1
                let when = f.count > 3 ? Double(f[3]) ?? 0 : 0
                visits.append(Store.HistoryEntry(url: f[0], title: f[1],
                                                 visited: Date(timeIntervalSince1970: when),
                                                 visits: count))
            } else {
                _ = url
                marks.append(Store.Bookmark(url: f[0], title: f[1], added: Date()))
            }
        }
        return (marks, visits)
    }

    // MARK: - Chrome

    private static var chromeBookmarkFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
    }

    private static func chromeBookmarks() -> [Store.Bookmark] {
        guard let d = try? Data(contentsOf: chromeBookmarkFile),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let roots = j["roots"] as? [String: Any] else { return [] }
        var out: [Store.Bookmark] = []
        func walk(_ node: Any) {
            guard let n = node as? [String: Any] else { return }
            if let type = n["type"] as? String, type == "url",
               let url = n["url"] as? String, url.hasPrefix("http") {
                out.append(Store.Bookmark(url: url, title: n["name"] as? String ?? url,
                                          added: Date()))
            }
            (n["children"] as? [Any])?.forEach(walk)
        }
        roots.values.forEach(walk)
        return out
    }

    // MARK: - Safari

    private static var safariBookmarkFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    private static func safariBookmarks() -> [Store.Bookmark] {
        // Safari's own folder is protected by TCC; if the read is refused this simply
        // returns nothing rather than pretending Safari has no bookmarks.
        guard let d = try? Data(contentsOf: safariBookmarkFile),
              let plist = try? PropertyListSerialization.propertyList(
                from: d, format: nil) as? [String: Any] else { return [] }
        var out: [Store.Bookmark] = []
        func walk(_ node: Any) {
            guard let n = node as? [String: Any] else { return }
            if let type = n["WebBookmarkType"] as? String, type == "WebBookmarkTypeLeaf",
               let url = n["URLString"] as? String, url.hasPrefix("http") {
                let title = (n["URIDictionary"] as? [String: Any])?["title"] as? String
                out.append(Store.Bookmark(url: url, title: title ?? url, added: Date()))
            }
            (n["Children"] as? [Any])?.forEach(walk)
        }
        walk(plist)
        return out
    }

    // MARK: - applying

    /// Merges into the store, skipping anything already there. Returns what was added.
    @discardableResult
    static func importFrom(_ source: Source) -> (bookmarks: Int, history: Int) {
        let existingMarks = Set(Store.bookmarks.map(\.url))
        let newMarks = source.bookmarks().filter { !existingMarks.contains($0.url) }
        if !newMarks.isEmpty { Store.bookmarks.append(contentsOf: newMarks) }

        let existingHistory = Set(Store.history.map(\.url))
        let newHistory = source.history().filter { !existingHistory.contains($0.url) }
        if !newHistory.isEmpty { Store.history.append(contentsOf: newHistory) }

        Store.flush()
        return (newMarks.count, newHistory.count)
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
