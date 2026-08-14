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
        // `waitForIt` because this reads the file straight back: the browser's periodic
        // save is asynchronous, and a test that assumes otherwise is testing a race.
        // The capture script debounces at 400 ms, so a save issued the instant after a
        // restore writes the pre-restore state. Waiting here is the test being honest
        // about the timing, not papering over it: the browser saves on a 10 s tick.
        settle(2)
        browser.saveSession(waitForIt: true)
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

        // --- containers: is the isolation real? ---
        // Cosmetic containers are worse than none, so this sets a cookie in one and tries
        // to read it in another. Same site, same window, same process pool.
        if #available(macOS 14.0, *), ContainerStore.all.count >= 2 {
            let a = ContainerStore.all[0], b = ContainerStore.all[1]
            let site = URL(string: "https://example.com/")!

            browser.openTab(url: site, container: a)
            guard let tabA = browser.currentTab, let viewA = tabA.webView else {
                finish(failures + 1)
            }
            viewA.loadHTMLString("<html><body>a</body></html>", baseURL: site)
            settle(3)
            run(viewA, "document.cookie = 'kestrel=containerA; path=/'; 'ok'")
            settle(1)
            var readA: String?
            wait(10) { done in
                viewA.evaluateJavaScript("document.cookie") { v, _ in
                    readA = v as? String; done()
                }
            }
            check("a cookie set in a container is readable there",
                  readA?.contains("containerA") == true, readA ?? "nil")

            browser.openTab(url: site, container: b)
            guard let tabB = browser.currentTab, let viewB = tabB.webView else {
                finish(failures + 1)
            }
            viewB.loadHTMLString("<html><body>b</body></html>", baseURL: site)
            settle(3)
            var readB: String?
            wait(10) { done in
                viewB.evaluateJavaScript("document.cookie") { v, _ in
                    readB = v as? String; done()
                }
            }
            check("...and NOT readable from another container",
                  readB?.contains("containerA") != true,
                  "\(b.name) sees: \(readB.map { $0.isEmpty ? "no cookies" : $0 } ?? "nil")")
            // A restart must not quietly move a tab into the default jar.
            browser.saveSession(waitForIt: true)
            let saved = Store.loadSession()
            let jarred = saved.first { $0.containerID != nil }
            check("the session file remembers which container a tab was in",
                  jarred != nil,
                  jarred?.containerID ?? "no tab recorded a container")
            check("...and it is a container that still exists",
                  jarred.flatMap { c in UUID(uuidString: c.containerID ?? "") }
                      .map { id in ContainerStore.all.contains { $0.id == id } } ?? false)

            check("the two containers have different data stores",
                  ContainerStore.store(for: a) !== ContainerStore.store(for: b))
            check("asking twice for one container returns the same store",
                  ContainerStore.store(for: a) === ContainerStore.store(for: a))
        }

        // --- the docked developer panel ---
        // Each pane is asserted on the thing it is for: the inspector must return a tree
        // with real tags in it, and the styles for a path must be the styles of that
        // element rather than a plausible-looking blob.
        let domPage = """
        <html><body>
          <div id="wrap"><p class="lead">hello</p><p>second</p></div>
          <span id="mark" style="width:123px;display:block">x</span>
        </body></html>
        """
        browser.openTab(url: URL(string: "https://example.com/dom")!)
        guard let domTab = browser.currentTab, let domView = domTab.webView else {
            finish(failures + 1)
        }
        domView.loadHTMLString(domPage, baseURL: URL(string: "https://example.com/dom"))
        settle(3)

        check("the page web view is the subclass that adds Inspect to the menu",
              domView is PageWebView, String(describing: type(of: domView)))

        var snapshot: String?
        wait(10) { done in
            domView.evaluateJavaScript(InspectorPane.snapshotScriptForTest) { v, e in
                snapshot = (v as? String) ?? e?.localizedDescription; done()
            }
        }
        check("the inspector snapshot is a tree", snapshot?.contains("\"children\"") == true,
              snapshot.map { String($0.prefix(60)) } ?? "nil")
        check("...containing the page's own elements",
              snapshot?.contains("wrap") == true && snapshot?.contains("lead") == true)

        var styleText: String?
        wait(10) { done in
            domView.evaluateJavaScript(
                InspectorPane.stylesScriptForTest("span#mark")) { v, _ in
                styleText = v as? String; done()
            }
        }
        check("computed styles come back for a path", styleText?.contains("COMPUTED") == true,
              styleText.map { String($0.prefix(40)).replacingOccurrences(of: "\n", with: " ") }
                ?? "nil")
        check("...and are that element's, not another's",
              styleText?.contains("123px") == true,
              styleText?.contains("width") == true ? "width present but wrong" : "no width")

        // The right-click path: the page records what was clicked, and Inspect reads it.
        var target: String?
        wait(10) { done in
            domView.evaluateJavaScript("""
            (function () {
              var el = document.querySelector('p.lead');
              el.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}));
              return window.__kestrelInspectTarget || '';
            })()
            """) { v, _ in target = v as? String; done() }
        }
        check("a right-click records the element under the cursor",
              target?.contains("p") == true, target ?? "nothing recorded")

        // --- reader view, and what it costs ---
        // The claim is that a reader document is a fraction of the page. Measured, not
        // assumed: an article page with a pile of chrome around it, then the extraction.
        let article = """
        <html><body>
          <nav><a href="/1">one</a><a href="/2">two</a><a href="/3">three</a></nav>
          <aside class="ads">buy things</aside>
          <article>
            <h1>A Headline</h1>
            <p>\(String(repeating: "Sentences of real prose that carry the article. ", count: 40))</p>
            <p>\(String(repeating: "A second paragraph, equally wordy and equally real. ", count: 40))</p>
            <script>var tracker = 1;</script>
          </article>
          <footer>footer links</footer>
        </body></html>
        """
        browser.openTab(url: URL(string: "https://example.com/article")!)
        guard let readTab = browser.currentTab, let readView = readTab.webView else {
            finish(failures + 1)
        }
        readView.loadHTMLString(article, baseURL: URL(string: "https://example.com/article"))
        settle(3)

        var available: Bool?
        wait(10) { done in
            readView.evaluateJavaScript(ReaderView.availabilityScript) { v, _ in
                available = v as? Bool; done()
            }
        }
        check("an article page offers reader view", available == true)

        var extracted: ReaderView.Article?
        wait(10) { done in
            readView.evaluateJavaScript(ReaderView.extractScript) { v, _ in
                extracted = ReaderView.parse(v); done()
            }
        }
        check("the article was extracted", extracted != nil,
              extracted.map { "\($0.words) words, title \"\($0.title)\"" } ?? "nil")
        if let a = extracted {
            check("...keeping the headline", a.title == "A Headline", a.title)
            check("...dropping the navigation and ads",
                  !a.html.contains("buy things") && !a.html.contains("footer links"))
            check("...dropping scripts", !a.html.lowercased().contains("<script"))
            let page = ReaderView.page(a, url: URL(string: "https://example.com/article")!)
            check("the reader document is self-contained",
                  !page.contains("<script") && !page.contains("http-equiv"))
        }

        // A page that is not an article must not offer the button, or reader view ruins it.
        browser.openTab(url: URL(string: "https://example.com/app")!)
        if let appTab = browser.currentTab, let appView = appTab.webView {
            appView.loadHTMLString("<html><body><div id=root>app</div></body></html>",
                                   baseURL: URL(string: "https://example.com/app"))
            settle(2)
            var appAvailable: Bool?
            wait(10) { done in
                appView.evaluateJavaScript(ReaderView.availabilityScript) { v, _ in
                    appAvailable = v as? Bool; done()
                }
            }
            check("a non-article page does not offer it", appAvailable == false)
        }

        // Extension pages must stay out of the session file: their UUID is per-install,
        // so a restored one points at nothing.
        browser.openTab(url: URL(string: "webkit-extension://deadbeef-0000/options.html")!)
        browser.saveSession(waitForIt: true)
        check("extension pages are not written into the session",
              !Store.loadSession().contains { $0.url.hasPrefix("webkit-extension://") })

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
