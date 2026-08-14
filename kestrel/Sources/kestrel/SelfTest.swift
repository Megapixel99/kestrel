import AppKit
import WebKit

/// Headless checks for the features that can be verified without a user driving the UI.
enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — " + detail)")
            if !ok { failures += 1 }
        }
        print("Kestrel self-test\n")

        // --- QR ---
        let qr = QRCode.image(for: "https://example.com/some/path?q=1")
        check("QR encodes a URL", qr != nil,
              qr.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")

        // --- about:memory rendering, which runs on the tick ---
        let manyTabs = (0..<24).map { i -> Tab in
            let t = Tab(id: i, url: URL(string: "https://example.com/\(i)")!, title: "Tab \(i)")
            t.cachedBytes = Int64(i) * 8_000_000
            return t
        }
        let sched = Scheduler(budgetBytes: 1_200 * 1024 * 1024, perTabCapBytes: 0, keepLive: 3)
        let renderStart = Date()
        for _ in 0..<40 {
            _ = AboutMemory.html(tabs: manyTabs, scheduler: sched, foregroundId: 0)
        }
        let renderMs = Date().timeIntervalSince(renderStart) * 1000 / 40
        check("rendering about:memory is cheap enough for the tick",
              renderMs < 5, String(format: "%.2f ms per render, 24 tabs", renderMs))

        // --- session writes must not block the tick ---
        // saveSession() runs on a timer, on the main thread, and JSON-encodes every tab
        // including its interactionState blob. That is the same shape as the bug in
        // DEBUGGING.md §2, where the instrumentation cost more than the thing it measured.
        // 24 tabs with realistic 60 KB session images is an ordinary heavy session.
        let blob = Data(repeating: 0x41, count: 60 * 1024)
        let heavy = (0..<24).map { i -> Store.SessionTab in
            Store.SessionTab(url: "https://example.com/\(i)", title: "Tab \(i)",
                             interactionState: blob, pinned: false,
                             scrollX: 0, scrollY: 0, formValues: [:], containerID: nil)
        }
        let saveStart = Date()
        Store.saveSession(heavy)
        Store.flush()
        let saveMs = Date().timeIntervalSince(saveStart) * 1000
        // The threshold is the point. 52 ms was what this cost on the main thread before
        // the encode and write moved off it — three dropped frames every tick. A limit
        // loose enough to pass the old code would not have caught anything.
        check("saving a 24-tab session does not block the main thread",
              saveMs < 10, String(format: "%.1f ms on the main thread for %d KB",
                                  saveMs, 24 * 60))

        // ...and it still has to arrive. An async write that never lands is worse than a
        // slow one, because nothing complains until the session is gone.
        let syncStart = Date()
        Store.saveSession(heavy, waitForIt: true)
        let syncMs = Date().timeIntervalSince(syncStart) * 1000
        let written = Store.loadSession()
        check("...and a waited write is on disk when it returns",
              written.count == heavy.count,
              String(format: "%d tabs, %.0f ms when waited", written.count, syncMs))

        // --- reading a tab's memory must never spawn a subprocess ---
        // /usr/bin/footprint costs ~226 ms. currentBytes used to call it on every read,
        // roughly 8 times per UI tick, which dropped a quarter of frames while scrolling.
        let perfTab = Tab(id: 99, url: URL(string: "https://example.com")!)
        perfTab.cachedBytes = 123 * 1024 * 1024
        let t0 = Date()
        var acc: Int64 = 0
        for _ in 0..<1000 { acc &+= perfTab.currentBytes }
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        check("1000 currentBytes reads are free (no process spawn)",
              elapsedMs < 50 && acc > 0,
              String(format: "%.2f ms for 1000 reads", elapsedMs))
        check("currentBytes returns the cached sample",
              perfTab.currentBytes == 123 * 1024 * 1024)

        // --- tab row shows which tab is active ---
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        let rowTab = Tab(id: 0, url: URL(string: "https://example.com")!)
        row.configure(rowTab, isCurrent: false)
        let unselected = row.isCurrent
        row.configure(rowTab, isCurrent: true)
        check("tab row reflects selection", !unselected && row.isCurrent,
              "no highlight meant clicks looked like no-ops")

        // --- reload must re-render the new tab page, not about:blank ---
        let ntabReload = Tab(id: 700, url: NewTabPage.url())
        check("new tab page is detected for reload",
              NewTabPage.isNewTab(ntabReload.url))
        check("about:blank is treated as the new tab page, so reload re-renders it",
              NewTabPage.isNewTab(URL(string: "about:blank")))
        check("a real page reloads normally",
              !NewTabPage.isNewTab(URL(string: "https://example.com/page")))

        // --- loading state drives the spinner ---
        let spinTab = Tab(id: 701, url: URL(string: "https://example.com")!)
        check("a tab starts not loading", !spinTab.isLoading)
        spinTab.isLoading = true
        let item = TabStripView.Item(id: spinTab.id, title: spinTab.title,
                                     state: spinTab.state, bytes: 0, isCurrent: true,
                                     pinned: false, isLoading: spinTab.isLoading)
        check("tab strip item carries the loading flag", item.isLoading)

        // --- user agent ---
        check("UA carries a Safari product token",
              UserAgent.applicationName.contains("Safari/")
                && UserAgent.applicationName.contains("Version/"),
              UserAgent.applicationName)
        check("UA version comes from the installed Safari",
              !UserAgent.safariVersion.isEmpty, "Safari \(UserAgent.safariVersion)")

        // --- layout preference round-trips ---
        let origVertical = Prefs.verticalTabs
        Prefs.verticalTabs = true
        check("vertical tabs preference persists", Prefs.verticalTabs)
        Prefs.verticalTabs = false
        check("horizontal tabs preference persists", !Prefs.verticalTabs)
        Prefs.verticalTabs = origVertical

        // --- the new tab page must not become the tab's identity ---
        let ntab = Tab(id: 600, url: NewTabPage.url())
        check("new tab is titled 'New Tab', not a data URL", ntab.title == "New Tab",
              ntab.title)
        check("new tab url is a sentinel, not a percent-encoded document",
              !ntab.url.absoluteString.hasPrefix("data:")
                && ntab.url.absoluteString.count < 40, ntab.url.absoluteString)
        check("about:blank is recognised as the new tab page",
              NewTabPage.isNewTab(URL(string: "about:blank")))
        check("a real page is not mistaken for the new tab page",
              !NewTabPage.isNewTab(URL(string: "https://example.com")))

        // --- tab switching: the exact bug that broke the UI ---
        // A tab that is already LIVE but detached must re-attach when re-selected.
        // promote() short-circuits on `target > state`, so this needs ensureAttached.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let win = NSWindow(contentRect: container.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = container
        var switchTabs: [Tab] = []
        for i in 0..<3 {
            let t = Tab(id: i, url: URL(string: "https://example\(i).invalid/")!)
            t.promote(to: .live, in: container)
            switchTabs.append(t)
        }
        func show(_ tab: Tab) {
            for other in switchTabs where other.id != tab.id {
                other.webView?.removeFromSuperview()
            }
            tab.promote(to: .live, in: container)
            tab.ensureAttached(to: container)
        }
        show(switchTabs[0])
        check("tab 0 attached after first select",
              switchTabs[0].webView?.superview === container)
        show(switchTabs[2])
        check("switching to tab 2 attaches it",
              switchTabs[2].webView?.superview === container)
        check("tab 0 detached after switching away",
              switchTabs[0].webView?.superview == nil)
        show(switchTabs[0])
        check("switching BACK to an already-LIVE tab re-attaches it",
              switchTabs[0].webView?.superview === container,
              "this is the bug that broke tab switching")
        check("exactly one web view attached at a time",
              container.subviews.filter { $0 is WKWebView }.count == 1,
              "\(container.subviews.filter { $0 is WKWebView }.count) attached")

        print("\n\(failures == 0 ? "all checks passed" : "\(failures) FAILURES")")
        exit(failures == 0 ? 0 : 1)
    }
}
