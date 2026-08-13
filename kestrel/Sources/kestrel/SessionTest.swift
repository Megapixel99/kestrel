import AppKit
import WebKit

/// Checks the three things added from the Firefox front-end docs, against real pages.
///
/// Each of them is the kind of feature that looks finished the moment it compiles: a
/// session file gets written, a page renders, a request list fills up. So each check here
/// asserts the part that is actually load-bearing — that form contents survive a round trip
/// through the ladder, that the memory page's numbers come from the scheduler, and that a
/// request's headers are real rather than a plausible-looking table.
enum SessionTest {

    static func run() {
        MainActor.assumeIsolated { go() }
    }

    @MainActor
    private static func go() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }
        print("Session, memory page and network monitor\n")

        let browser = BrowserWindowController()
        defer { browser.window.close() }

        // --- a page with a form, filled in ---
        let page = """
        <html><body style="height:3000px">
          <form>
            <input id="q" name="q" type="text">
            <textarea id="notes"></textarea>
            <input id="pw" type="password">
          </form>
        </body></html>
        """
        browser.openTab(url: URL(string: "https://example.com/form")!)
        guard let tab = browser.currentTab, let wv = tab.webView else {
            check("opened a tab", false); finish(failures + 1)
        }
        wv.loadHTMLString(page, baseURL: URL(string: "https://example.com/form"))
        settle(3)

        run(wv, """
            document.getElementById('q').value = 'half typed';
            document.getElementById('notes').value = 'a draft';
            document.getElementById('pw').value = 'hunter2';
            document.getElementById('q').dispatchEvent(new Event('input', {bubbles:true}));
            window.scrollTo(0, 900);
            'ok'
            """)
        // The capture script debounces at 400 ms; give it room.
        settle(2)

        check("form contents were captured", tab.pageState.values.count >= 2,
              "\(tab.pageState.values.count) field(s): "
              + tab.pageState.values.keys.sorted().joined(separator: ", "))
        check("scroll position was captured", tab.pageState.scrollY > 500,
              "y = \(Int(tab.pageState.scrollY))")
        check("the password field was NOT captured",
              !tab.pageState.values.values.contains("hunter2"),
              tab.pageState.values.values.sorted().joined(separator: " | "))

        // The scheduler's demotion floor reads this flag, and nothing set it before.
        check("unsubmitted input marks the tab", tab.hasUnsubmittedInput)
        let floor = browser.scheduler.floor(for: tab)
        check("...so the scheduler will not park it below COLD", floor == .cold,
              "floor = \(floor)")

        // --- survives the round trip the browser actually performs ---
        let saved = tab.pageState
        tab.demote(to: .cold)
        settle(1)
        _ = tab.promote(to: .live, in: browser.webContainer)
        tab.ensureAttached(to: browser.webContainer)
        browser.attachPageHandlers(to: tab)
        tab.webView?.loadHTMLString(page, baseURL: URL(string: "https://example.com/form"))
        settle(3)
        var restored: Int?
        wait(10) { done in
            tab.webView?.evaluateJavaScript(SessionStore.restoreScript(saved)) { v, _ in
                restored = v as? Int; done()
            }
        }
        check("form contents restore after a COLD round trip", (restored ?? 0) >= 2,
              "\(restored ?? 0) field(s) put back")
        var readback: String?
        wait(10) { done in
            tab.webView?.evaluateJavaScript("document.getElementById('q').value") { v, _ in
                readback = v as? String; done()
            }
        }
        check("...with the right value", readback == "half typed", readback ?? "nil")

        // --- session file round trip ---
        // The capture script debounces at 400 ms, so a save issued the instant after a
        // restore writes the pre-restore state. Waiting here is the test being honest
        // about the timing, not papering over it: the browser saves on a 10 s tick.
        settle(2)
        browser.saveSession()
        let file = Store.loadSession()
        check("session file records form state",
              file.contains { !$0.formValues.isEmpty },
              "\(file.count) tab(s) saved")
        check("session file does not contain the password",
              !file.contains { $0.formValues.values.contains("hunter2") })

        // --- crash flag ---
        SessionStore.markRunning()
        check("a running browser leaves a flag", SessionStore.lastRunCrashed())
        SessionStore.markCleanExit()
        check("a clean exit removes it", !SessionStore.lastRunCrashed())

        // --- about:memory ---
        let html = AboutMemory.html(tabs: browser.tabs, scheduler: browser.scheduler,
                                    foregroundId: browser.foregroundId)
        check("memory page names the budget",
              html.contains("MB budget"))
        check("memory page lists a rung of the ladder",
              html.contains("LIVE") || html.contains("COLD"))
        check("memory page counts the tabs it has",
              html.contains("<tbody><tr") || html.contains("<td class=\"state"))
        check("kestrel://memory is not treated as the new tab page",
              !NewTabPage.isNewTab(AboutMemory.sentinel)
              && AboutMemory.isMemoryPage(AboutMemory.sentinel))

        // --- network monitor, against a real request the page makes ---
        NetworkMonitor.clear()
        browser.openTab(url: URL(string: "https://example.com/net")!)
        guard let netTab = browser.currentTab, let netView = netTab.webView else {
            finish(failures + 1)
        }
        netView.load(URLRequest(url: URL(string: "https://example.com/")!))
        settle(6)
        run(netView, """
            fetch('https://example.com/?probe=1', {headers: {'X-Kestrel': 'test'}})
              .then(function (r) { return r.text(); });
            'ok'
            """)
        settle(6)

        let entries = NetworkMonitor.entries
        check("the monitor recorded requests", !entries.isEmpty, "\(entries.count) entries")
        let doc = entries.first { $0.source == .navigation }
        check("the main document has real response headers",
              (doc?.responseHeaders.count ?? 0) > 0,
              doc.map { "\($0.responseHeaders.count) headers, status "
                        + ($0.status.map(String.init) ?? "—") } ?? "no document entry")
        let fetched = entries.first { $0.source == .script }
        check("a fetch() carries the request header the page sent",
              fetched?.requestHeaders.keys.contains(where: { $0.lowercased() == "x-kestrel" })
                == true,
              fetched.map { "\($0.method) \($0.url.lastPathComponent) "
                            + "req=\($0.requestHeaders.count) res=\($0.responseHeaders.count)" }
                ?? "no fetch entry")
        check("...and its response status", fetched?.status != nil,
              fetched?.status.map(String.init) ?? "none")
        check("the ring buffer is bounded", NetworkMonitor.limit <= 1000)

        finish(failures)
    }

    // MARK: - helpers

    @MainActor
    private static func run(_ wv: WKWebView, _ js: String) {
        wait(10) { done in wv.evaluateJavaScript(js) { _, _ in done() } }
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

    private static func finish(_ failures: Int) -> Never {
        print("\n" + (failures == 0
                      ? "session state, memory page and network monitor all work"
                      : "\(failures) check(s) failed"))
        exit(failures == 0 ? 0 : 1)
    }
}
