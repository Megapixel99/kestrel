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
        // The page must update in place: reloading it every tick threw away the scroll
        // position. This asserts the updater exists, runs, and changes what is on screen
        // without the document being replaced.
        browser.openTab(url: AboutMemory.sentinel)
        if let memTab = browser.currentTab, let memView = memTab.webView {
            browser.refreshMemoryPages()      // loads the shell
            settle(2)
            var hasUpdater: String?
            wait(10) { done in
                memView.evaluateJavaScript("typeof updateMemory") { v, _ in
                    hasUpdater = v as? String; done()
                }
            }
            check("the memory page ships an in-place updater", hasUpdater == "function",
                  hasUpdater ?? "nil")

            // Mark the document, tick, and check the mark survived: a reload would wipe it.
            wait(10) { d in
                memView.evaluateJavaScript("window.__kestrelMark = 'kept'; 'ok'") { _, _ in d() }
            }
            browser.refreshMemoryPages()      // should update, not reload
            settle(2)
            var mark: String?
            wait(10) { done in
                memView.evaluateJavaScript("window.__kestrelMark || 'gone'") { v, _ in
                    mark = v as? String; done()
                }
            }
            check("...and a tick updates it without reloading the document",
                  mark == "kept", mark ?? "nil")

            var shown: String?
            wait(10) { done in
                memView.evaluateJavaScript(
                    "document.getElementById('rows').children.length + ' rows'") { v, _ in
                    shown = v as? String; done()
                }
            }
            check("...with the tab table filled in", shown?.hasSuffix("rows") == true
                  && shown != "0 rows", shown ?? "nil")
        }

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
        // A path that restarts at an id must still be findable in the tree.
        var idPath: String?
        wait(10) { done in
            domView.evaluateJavaScript("""
            (function () {
              var el = document.getElementById('mark');
              el.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}));
              return window.__kestrelInspectTarget || '';
            })()
            """) { v, _ in idPath = v as? String; done() }
        }
        check("selection survives an id restart in the path",
              idPath == "span#mark", idPath ?? "nil")

        check("a right-click records the element under the cursor",
              target?.contains("p") == true, target ?? "nothing recorded")

        // --- does the memory readout survive a process swap? ---
        // WebKit swaps the WebContent process on cross-site navigation, and a tab's pid is
        // found once, when its web view is created. From a screen recording: one tab walked
        // from home.apu.edu to a Jira board and the readout went 37 → 399 → 159 → 0 MB with
        // a heavy page on screen. The budget cannot enforce anything it reads as zero.
        browser.openTab(url: URL(string: "https://example.com/")!)
        if let mTab = browser.currentTab, let mView = mTab.webView {
            mView.load(URLRequest(url: URL(string: "https://example.com/")!))
            settle(6)
            browser.sampleMemory()
            settle(4)
            let firstPid = mTab.pid
            let firstBytes = mTab.cachedBytes
            check("a live tab reports a footprint", firstBytes > 0,
                  "\(firstBytes / 1_048_576) MB, pid \(firstPid.map(String.init) ?? "none")")

            // Cross-site navigation does not reliably swap the process here — Kestrel
            // gives each tab its own WKProcessPool — so navigating and hoping is a test
            // that cannot fail for the reason it was written. The recovery is exercised
            // directly instead: point the tab at a pid that is definitely dead and see
            // whether the browser finds the live one again.
            mView.load(URLRequest(url: URL(string: "https://www.apple.com/")!))
            settle(8)
            browser.sampleMemory()
            settle(4)

            let deadPid: Int32 = 999_999      // outside any plausible live range
            mTab.pid = deadPid
            mTab.cachedBytes = 0
            browser.sampleMemory()
            settle(5)

            // The contract is not "recovery always succeeds" — reclaiming is only safe
            // when one orphaned tab meets exactly one unclaimed process, and guessing
            // beyond that put a tab on another's process in an earlier version. What must
            // always hold is that the browser never reports a confident zero it cannot
            // stand behind.
            let recovered = mTab.pid != nil && mTab.pid != deadPid
            check("a dead process is either replaced or admitted, never reported as 0",
                  recovered || !mTab.footprintKnown,
                  recovered
                    ? "recovered pid \(mTab.pid.map(String.init) ?? "?")"
                    : "marked unmeasured (pid \(mTab.pid.map(String.init) ?? "none"))")
            check("...and a stale pid is never kept",
                  mTab.pid != deadPid,
                  mTab.pid.map(String.init) ?? "none")

            // The deeper failure the recording exposed: a tab that cannot be measured
            // rendered as "0 MB", indistinguishable from one that costs nothing, and the
            // budget counted it as free. Unknown must look like unknown.
            mTab.pid = nil
            mTab.footprintKnown = false
            let html = AboutMemory.html(tabs: browser.tabs, scheduler: browser.scheduler,
                                        foregroundId: browser.foregroundId)
            check("unmeasured is not zero on the memory page",
                  html.contains(">?</td>"),
                  html.contains(">?</td>") ? "renders ?" : "still rendering a number")
            let payload = AboutMemory.payload(tabs: browser.tabs,
                                              scheduler: browser.scheduler,
                                              foregroundId: browser.foregroundId)
            check("...and not zero in the live update payload",
                  payload.contains("\"mb\":\"?\""),
                  String(payload.prefix(80)))
        }

        // --- what a scroll-triggered form scan costs ---
        // Scroll shares the debounced path with input, so scrolling a form-heavy page
        // runs a full querySelectorAll and reads every field. Scrolling cannot change a
        // form value, so the work is entirely wasted.
        var formPage = "<html><body style=\"height:6000px\">"
        for i in 0..<400 { formPage += "<input id=\"f\(i)\" value=\"v\(i)\">" }
        formPage += "</body></html>"
        browser.openTab(url: URL(string: "https://example.com/forms")!)
        if let fTab = browser.currentTab, let fView = fTab.webView {
            fView.loadHTMLString(formPage, baseURL: URL(string: "https://example.com/forms"))
            settle(3)
            var scanMs: String?
            wait(15) { done in
                fView.evaluateJavaScript("""
                (function () {
                  var t = performance.now();
                  for (var run = 0; run < 20; run++) {
                    var values = {}, fields = document.querySelectorAll('input, textarea, select');
                    for (var i = 0; i < fields.length; i++) {
                      var el = fields[i], type = (el.type || '').toLowerCase();
                      if (type === 'password' || type === 'hidden' || type === 'file') continue;
                      var v = el.value;
                      if (v) values['#' + el.id] = String(v);
                    }
                  }
                  return ((performance.now() - t) / 20).toFixed(2);
                })()
                """) { v, _ in scanMs = v as? String; done() }
            }
            check("a form scan is cheap on its own",
                  (Double(scanMs ?? "99") ?? 99) < 3,
                  "\(scanMs ?? "?") ms for 400 fields")

            // The real question: does scrolling cause one?
            NetworkMonitor.clear()
            fTab.pageState = SessionStore.PageState()
            wait(10) { d in
                fView.evaluateJavaScript(
                    "window.scrollTo(0, 2000); 'ok'") { _, _ in d() }
            }
            settle(2)
            check("scrolling reports a scroll position",
                  fTab.pageState.scrollY > 1000,
                  "y = \(Int(fTab.pageState.scrollY))")
            check("...without re-reading every form field",
                  fTab.pageState.values.isEmpty,
                  "\(fTab.pageState.values.count) field(s) collected on a scroll")
        }

        // --- what the network capture costs the page ---
        // The fetch/XHR wrappers and the PerformanceObserver are injected into every page
        // on every load, panel open or not, and every observed resource becomes an IPC
        // message to the browser. A page like the one in the screenshot that prompted this
        // made 244 requests.
        NetworkMonitor.clear()
        // Capture off is the default; the panel turns it on. Measure both.
        check("network capture is off until something opens the panel",
              !NetworkMonitor.isCapturing)
        // "Off" has to mean untouched, not merely quiet: a wrapper that runs and then
        // discards the result still costs the page every request.
        NetworkMonitor.setCapturing(false, tabs: browser.tabs)
        browser.openTab(url: URL(string: "https://example.com/net-quiet")!)
        if let qTab = browser.currentTab, let qView = qTab.webView {
            qView.loadHTMLString("<html><body>quiet</body></html>",
                                 baseURL: URL(string: "https://example.com/net-quiet"))
            settle(2)
            var wrapped: String?
            wait(10) { done in
                qView.evaluateJavaScript(
                    "/native code/.test(String(window.fetch)) ? 'native' : 'wrapped'") { v, _ in
                    wrapped = v as? String; done()
                }
            }
            check("with capture off, fetch is left alone", wrapped == "native",
                  wrapped ?? "nil")
        }

        browser.openTab(url: URL(string: "https://example.com/net-cost")!)
        if let nTab = browser.currentTab, let nView = nTab.webView {
            nView.loadHTMLString("<html><body>cost</body></html>",
                                 baseURL: URL(string: "https://example.com/net-cost"))
            settle(2)
            NetworkMonitor.setCapturing(true, tabs: browser.tabs)
            settle(1)
            // 300 same-origin requests to a URL that 404s fast, wrapped vs unwrapped.
            let script = """
            (function () {
              window.__origFetchForTest = window.__origFetchForTest || null;
              window.__t = {};
              function run(label, done) {
                var n = 300, start = performance.now(), left = n;
                for (var i = 0; i < n; i++) {
                  fetch('/nothing-' + i).catch(function () {}).then(function () {
                    if (--left === 0) { window.__t[label] = performance.now() - start; done(); }
                  });
                }
              }
              var saved = window.fetch;
              run('wrapped', function () {
                // Restore the untouched fetch and repeat.
                window.fetch = window.__origFetchForTest || saved;
                run('bare', function () { window.__t.ready = true; });
              });
              return 'started';
            })()
            """
            wait(10) { d in nView.evaluateJavaScript(script) { _, _ in d() } }
            var timings: String?
            wait(40) { done in
                pollPage(nView, every: 1.0, until: 35,
                     script: "window.__t && window.__t.ready ? "
                           + "(Math.round(window.__t.wrapped) + '/' + Math.round(window.__t.bare)) : ''"
                ) { v in timings = v; done() }
            }
            let parts = (timings ?? "").split(separator: "/").compactMap { Double($0) }
            // Reported, not asserted. This is a network measurement: the same code gave
            // +42%, +27% and +15% on three consecutive runs, so a threshold here fails at
            // random and teaches everyone to ignore the suite. The structural checks above
            // and below are the ones that can actually be wrong.
            if parts.count == 2 {
                let overheadPct = parts[1] > 0 ? (parts[0] - parts[1]) / parts[1] * 100 : 0
                print(String(format: "  NOTE  capture overhead: %.0f ms wrapped vs %.0f ms "
                                   + "bare (%+.0f%%), 300 requests",
                             parts[0], parts[1], overheadPct))
            } else {
                print("  NOTE  capture overhead: not measured (\(timings ?? "no answer"))")
            }
            check("every request was captured", NetworkMonitor.entries.count >= 300,
                  "\(NetworkMonitor.entries.count) entries recorded")
        }

        // --- what the inspector's DOM walk actually costs ---
        // The panel re-walks the document on a throttle I picked without measuring, which
        // is the same guess that produced the last two findings. A page with a few thousand
        // nodes is ordinary; the walk runs in the page's own process, so an expensive one
        // steals from the page rather than from the browser.
        var heavy = "<html><body>"
        for i in 0..<1200 {
            heavy += "<div class=\"row r\(i % 7)\"><span>cell \(i)</span>"
                   + "<a href=\"/\(i)\">link</a></div>"
        }
        heavy += "</body></html>"
        browser.openTab(url: URL(string: "https://example.com/heavy")!)
        if let hTab = browser.currentTab, let hView = hTab.webView {
            hView.loadHTMLString(heavy, baseURL: URL(string: "https://example.com/heavy"))
            settle(3)
            var walkMs: Double = 0
            var nodes = 0
            for _ in 0..<5 {
                let t = Date()
                var json: String?
                wait(15) { done in
                    hView.evaluateJavaScript(InspectorPane.snapshotScriptForTest) { v, _ in
                        json = v as? String; done()
                    }
                }
                walkMs += Date().timeIntervalSince(t) * 1000
                nodes = max(nodes, (json?.components(separatedBy: "\"path\"").count ?? 1) - 1)
            }
            walkMs /= 5
            check("the inspector's DOM walk is cheap enough to repeat",
                  walkMs < 60,
                  String(format: "%.0f ms for %d nodes on a 3600-element page",
                         walkMs, nodes))
        }

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

    @MainActor
    private static func pollPage(_ wv: WKWebView, every: TimeInterval, until deadline: TimeInterval,
                             script: String, found: @escaping (String?) -> Void) {
        var elapsed: TimeInterval = 0
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { t in
            elapsed += every
            wv.evaluateJavaScript(script) { v, _ in
                let s = v as? String ?? ""
                if !s.isEmpty { t.invalidate(); timer = nil; found(s) }
                else if elapsed >= deadline { t.invalidate(); timer = nil; found(nil) }
            }
        }
        _ = timer
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
