import AppKit
import WebKit

/// What a Firefox add-on costs in memory, measured rather than assumed.
///
///     kestrel extmem ~/Library/Application\\ Support/Firefox/Profiles/*/extensions
///
/// This is here because of the question that started the project. The controlled Firefox
/// vs Chrome comparison in RESULTS.md carried one confound nobody could rule out: Firefox
/// had more extensions installed. An add-on's background page is a whole web context, so
/// the cost is not obviously small — and it is not a cost the tab ladder can reclaim,
/// because a background page belongs to no tab.
///
/// Each add-on is loaded on its own, its background content forced to run, and the total
/// footprint of every WebKit process re-measured. The delta is what that add-on costs.
enum ExtensionMemory {

    static func run(paths: [String]) {
        guard #available(macOS 15.4, *) else {
            print("WebKit's extension runtime needs macOS 15.4.")
            exit(0)
        }
        MainActor.assumeIsolated { measure(paths) }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func measure(_ paths: [String]) {
        let fm = FileManager.default
        var xpis: [URL] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: nil)) ?? []
                xpis += items.filter { $0.pathExtension == "xpi" }
            } else { xpis.append(url) }
        }
        guard !xpis.isEmpty else { print("no .xpi files found"); exit(1) }

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-extmem-\(getpid())")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Every WebContent process on the machine belongs to somebody, and most of them
        // are not ours — Safari and any other WebKit app are running too. Recording the
        // pid set before the browser exists is what makes the rest of this measurement
        // about Kestrel. The first version skipped this and reported a 723 MB "baseline"
        // that was mostly other applications, with one add-on scoring -3 MB.
        foreign = Set(MemoryProbe.webContentPids())

        // A window with one real tab, so the extensions have something to attach to and
        // the baseline includes the browser rather than pretending it is free.
        let browser = BrowserWindowController()
        defer { browser.window.close() }
        let runtime = ExtensionRuntime.shared
        runtime.browser = browser
        browser.openTab(url: URL(string: "https://example.com/")!)
        browser.currentTab?.webView?.loadHTMLString(
            "<html><body>baseline</body></html>", baseURL: URL(string: "https://example.com/"))
        settle(3)

        let baseline = total()
        print("baseline: browser + 1 tab = \(mb(baseline)) MB across "
              + "\(ours().count) web process(es) of ours "
              + "(\(foreign.count) others on this Mac ignored)\n")
        print("add-on                              after    delta    procs background")
        print(String(repeating: "-", count: 79))

        var previous = baseline
        var rows: [(String, Int64)] = []
        for xpi in xpis.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let dest = work.appendingPathComponent(UUID().uuidString)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", xpi.path, dest.path]
            unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
            try? unzip.run(); unzip.waitUntilExit()

            guard let d = try? Data(contentsOf: dest.appendingPathComponent("manifest.json")),
                  let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            let ext = ExtensionStore.Installed(id: xpi.lastPathComponent, dir: dest,
                                               manifest: m)
            let wantsBackground = m["background"] != nil

            var loaded = false
            var backgroundRan = false
            wait(20) { done in
                Task { @MainActor in
                    do {
                        let webExt = try await WKWebExtension(resourceBaseURL: dest)
                        let ctx = WKWebExtensionContext(for: webExt)
                        ctx.uniqueIdentifier = UUID().uuidString
                        for p in ext.apiPermissions {
                            ctx.setPermissionStatus(.grantedExplicitly,
                                                    for: WKWebExtension.Permission(p))
                        }
                        for pattern in ext.hostPatterns {
                            let s = pattern == "<all_urls>" ? "*://*/*" : pattern
                            if let mp = try? WKWebExtension.MatchPattern(string: s) {
                                ctx.setPermissionStatus(.grantedExplicitly, for: mp)
                            }
                        }
                        try runtime.controller.load(ctx)
                        loaded = true
                        ctx.didOpenWindow(browser)
                        ctx.didFocusWindow(browser)
                        for t in browser.tabs { ctx.didOpenTab(t) }
                        // A background page is lazy. Forcing it is the whole point: an
                        // add-on that has not woken up yet costs nothing and would make
                        // this benchmark say extensions are free.
                        if wantsBackground {
                            ctx.loadBackgroundContent { error in
                                backgroundRan = (error == nil)
                                done()
                            }
                        } else { done() }
                    } catch { done() }
                }
            }
            guard loaded else { continue }
            settle(2)

            let now = total()
            let delta = now - previous
            previous = now
            rows.append((ext.name, delta))
            print(pad(ext.name, 34) + "  " + pad("\(mb(now)) MB", 8)
                  + " " + pad("\(delta >= 0 ? "+" : "")\(mb(delta)) MB", 8)
                  + " " + pad("\(ours().count)", 4)
                  + " " + (wantsBackground ? (backgroundRan ? "ran" : "failed to start")
                                           : "none"))
        }

        let totalCost = previous - baseline
        print(String(repeating: "-", count: 79))
        print("\(rows.count) add-ons: \(mb(totalCost)) MB on top of a "
              + "\(mb(baseline)) MB browser — \(mb(totalCost / Int64(max(1, rows.count)))) MB each on average.")
        if let worst = rows.max(by: { $0.1 < $1.1 }) {
            print("Most expensive: \(worst.0) at \(mb(worst.1)) MB.")
        }
        print("""

        Read the total, not the rows. Each add-on is measured as a delta from the one
        before it, and WebKit reclaims memory on its own schedule, so individual rows go
        negative. The total is stable across runs; the rows are not.

        This memory belongs to no tab, so the ladder cannot reclaim it: a background page
        is not a page anyone is looking at, and demoting it would break the add-on. It is
        a fixed addition to the floor, which is exactly what a memory budget has to know.
        """)
        exit(0)
    }

    // MARK: - helpers

    /// WebContent processes that did not exist before this run, plus the app itself.
    /// An extension's background page is its own web content process, so it has to be
    /// counted; every other app's renderers must not be.
    private static var foreign: Set<Int32> = []

    private static func ours() -> Set<Int32> {
        Set(MemoryProbe.webContentPids()).subtracting(foreign)
    }

    private static func total() -> Int64 {
        MemoryProbe.footprintOf(ours()) + MemoryProbe.selfFootprint()
    }

    private static func mb(_ b: Int64) -> String {
        String(format: "%.0f", Double(b) / 1024 / 1024)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    private static func settle(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func wait(_ seconds: TimeInterval, _ body: (@escaping () -> Void) -> Void) {
        var done = false
        body { done = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
