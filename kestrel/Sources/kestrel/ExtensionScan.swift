import AppKit
import WebKit

/// Reports, for a directory of real `.xpi` files, which Firefox add-ons WebKit's runtime
/// will actually load and what each one loses on the way.
///
///     kestrel extscan ~/Library/Application\\ Support/Firefox/Profiles/*/extensions
///
/// This exists because "Firefox add-ons work" is a claim, and the honest version of it is
/// a table. Parsing manifests would only tell us what an add-on asks for; this hands each
/// one to `WKWebExtension` and reports what WebKit says back.
enum ExtensionScan {

    static func run(paths: [String]) {
        guard #available(macOS 15.4, *) else {
            print("WebKit's extension runtime needs macOS 15.4.")
            exit(0)
        }
        MainActor.assumeIsolated { scan(paths) }
    }

    private struct Row {
        let file: String
        var name = "?"
        var version = ""
        var mv = 0
        var loaded = false
        var error: String?
        var gaps: [String] = []
        var hosts = 0
        var hasBackground = false
        var hasContentScripts = false
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func scan(_ paths: [String]) {
        let fm = FileManager.default
        var xpis: [URL] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: nil)) ?? []
                xpis += items.filter { $0.pathExtension == "xpi" || $0.pathExtension == "zip" }
            } else {
                xpis.append(url)
            }
        }
        guard !xpis.isEmpty else {
            print("no .xpi files found in: \(paths.joined(separator: ", "))")
            exit(1)
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-extscan-\(getpid())")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        print("Scanning \(xpis.count) add-on(s) with WebKit's extension runtime\n")
        var rows: [Row] = []
        for xpi in xpis.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var row = Row(file: xpi.deletingPathExtension().lastPathComponent)
            let dest = work.appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", xpi.path, dest.path]
            unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
            try? unzip.run(); unzip.waitUntilExit()

            if let d = try? Data(contentsOf: dest.appendingPathComponent("manifest.json")),
               let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let ext = ExtensionStore.Installed(id: row.file, dir: dest, manifest: m)
                row.name = ext.name
                row.version = ext.version
                row.mv = ext.manifestVersion
                row.gaps = ExtensionStore.gaps(in: ext)
                row.hosts = ext.hostPatterns.count
                row.hasBackground = m["background"] != nil
                row.hasContentScripts = m["content_scripts"] != nil
            } else {
                row.error = "no readable manifest.json"
                rows.append(row)
                continue
            }

            var done = false
            Task { @MainActor in
                do {
                    _ = try await WKWebExtension(resourceBaseURL: dest)
                    row.loaded = true
                } catch {
                    row.error = shorten(error.localizedDescription)
                }
                done = true
            }
            let deadline = Date().addingTimeInterval(20)
            while !done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            if !done { row.error = "timed out" }
            rows.append(row)
        }

        report(rows)
    }

    private static func shorten(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 68 ? String(one.prefix(65)) + "…" : one
    }

    private static func report(_ rows: [Row]) {
        let nameW = min(34, max(12, rows.map(\.name.count).max() ?? 12))
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
        }
        print(pad("add-on", nameW) + "  ver      MV  loads  notes")
        print(String(repeating: "-", count: nameW + 40))
        for r in rows {
            let note: String
            if let e = r.error { note = e }
            else if r.gaps.isEmpty { note = "" }
            else { note = "no " + r.gaps.joined(separator: ", ") }
            print(pad(r.name, nameW) + "  "
                  + pad(r.version, 7) + "  "
                  + pad(r.mv == 0 ? "?" : "\(r.mv)", 2) + "  "
                  + pad(r.loaded ? "yes" : "NO", 5) + "  " + note)
        }

        let loaded = rows.filter(\.loaded)
        let clean = loaded.filter { $0.gaps.isEmpty }
        print("\n\(loaded.count)/\(rows.count) load — \(clean.count) with nothing missing, "
              + "\(loaded.count - clean.count) with Gecko-only pieces that will not run.")
        let mv2 = rows.filter { $0.mv == 2 }.count
        print("\(mv2) are Manifest V2, \(rows.count - mv2) V3. "
              + "WebKit accepts both; Chrome no longer accepts V2.")
        if !rows.filter({ $0.error != nil }).isEmpty {
            print("\nRejections are WebKit's own parser, verbatim — not a Kestrel check.")
        }
        exit(0)
    }
}
