import AppKit
import WebKit

/// Does an ad blocker actually block? Measured against real tracker URLs, with a control.
///
///     kestrel blocktest ubolite
///
/// Written after a Manifest V2 blocker was found to load cleanly, be granted every
/// permission it asked for, run its background page without error — and block nothing,
/// because WebKit grants `webRequestBlocking` without honouring it. Nothing in the
/// extension API reports that. The only way to know is to ask for something that ought to
/// be blocked and see whether it arrives.
///
/// A control run is the point. Without one, "the request failed" could be a network
/// problem, a dead URL, or a blocker doing its job, and the three are indistinguishable.
enum BlockTest {

    /// Script URLs that any competent blocker's default lists cover, and that load fine
    /// otherwise. Script tags rather than `fetch`: a fetch failure could be CORS, which
    /// would make a blocker look effective when it is not.
    private static let probes = [
        ("Google Analytics",   "https://www.google-analytics.com/analytics.js"),
        ("Google Tag Manager", "https://www.googletagmanager.com/gtag/js?id=UA-1"),
        ("DoubleClick",        "https://securepubads.g.doubleclick.net/tag/js/gpt.js"),
        ("Google Ads",         "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"),
        ("Scorecard Research", "https://sb.scorecardresearch.com/beacon.js"),
    ]

    static func run(args: [String]) {
        guard #available(macOS 15.4, *) else {
            print("WebKit's extension runtime needs macOS 15.4."); exit(0)
        }
        MainActor.assumeIsolated { go(args) }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func go(_ args: [String]) -> Never {
        let installed = ExtensionStore.installed()
        guard let wanted = args.first,
              let ext = installed.first(where: { $0.id.contains(wanted) }) else {
            print("usage: kestrel blocktest <add-on>\navailable: "
                  + installed.map(\.id).joined(separator: ", "))
            exit(1)
        }

        let browser = BrowserWindowController()
        defer { browser.window.close() }
        ExtensionRuntime.shared.browser = browser

        // --- does the probe detect blocking at all? ---
        // A rule list compiled here, by us, blocking one probe. If the probe cannot see
        // this, it cannot see anything, and the rest of the run means nothing. Same
        // discipline as reintroducing a bug to check a test fails.
        let selfCheck = probes[0]
        var ruleList: WKContentRuleList?
        wait(20) { done in
            let json = """
            [{"trigger": {"url-filter": "google-analytics\\\\.com"},
              "action": {"type": "block"}}]
            """
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "kestrel-blocktest-selfcheck", encodedContentRuleList: json
            ) { list, _ in ruleList = list; done() }
        }
        if let ruleList {
            browser.openTab(url: URL(string: "https://example.com/")!)
            if let wv = browser.currentTab?.webView {
                wv.configuration.userContentController.add(ruleList)
                wv.load(URLRequest(url: URL(string: "https://example.com/")!))
                settle(5)
                let r = probe(wv, name: selfCheck.0, url: selfCheck.1)
                print("self-check — our own rule blocking \(selfCheck.0): \(r)")
                if r != "blocked" {
                    print("""

                    The probe cannot detect blocking that is definitely happening, so this
                    run cannot say anything about the add-on. Stopping.
                    """)
                    exit(1)
                }
            }
        }

        // --- control: the same probes with no blocker loaded at all ---
        print("Control — no add-on loaded\n")
        let control = measure(browser: browser, label: "control")

        // --- then with the blocker ---
        print("\nLoading \(ext.name) \(ext.version) (MV\(ext.manifestVersion))…")
        var loadError: String?
        wait(30) { done in
            ExtensionRuntime.shared.load(ext) { e in loadError = e; done() }
        }
        guard loadError == nil, let ctx = ExtensionRuntime.shared.contexts[ext.id] else {
            print("failed to load: \(loadError ?? "unknown")")
            exit(1)
        }
        // Declarative rules are compiled by WebKit when the context loads; the background
        // may also enable rulesets at runtime, so give it a moment before judging.
        wait(30) { done in ctx.loadBackgroundContent { _ in done() } }
        // uBOL ships six enabled rulesets — EasyList and EasyPrivacy among them — and
        // WebKit has to compile tens of thousands of rules before any of them bite. How
        // long that takes is the question this argument exists to answer.
        let patience = args.count > 1 ? (Double(args[1]) ?? 20) : 20
        print("waiting \(Int(patience))s for rules to compile…")
        settle(patience)
        print("declares content modification rules: \(ctx.hasContentModificationRules)\n")

        let blocked = measure(browser: browser, label: "with \(ext.name)")

        // Does the rule reach a web view built from the *controller's* configuration
        // rather than one of ours with the controller merely attached? Kestrel's tabs
        // construct their own WKWebViewConfiguration; if declarative rules are installed
        // into the controller's configuration, our tabs would never receive them and no
        // add-on could ever block, whatever its manifest version.
        let ctrlCfg = ExtensionRuntime.shared.controller.configuration.webViewConfiguration
                   ?? WKWebViewConfiguration()
        ctrlCfg.webExtensionController = ExtensionRuntime.shared.controller
        let ctrlView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700),
                                 configuration: ctrlCfg)
        let host = NSWindow(contentRect: ctrlView.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.contentView?.addSubview(ctrlView)
        ctrlView.load(URLRequest(url: URL(string: "https://example.com/")!))
        settle(6)
        let viaController = probe(ctrlView, name: probes[0].0, url: probes[0].1)
        print("\nsame probe in a web view from the controller's own configuration: "
              + viaController)
        host.close()

        // --- verdict ---
        print("\n" + pad("probe", 20) + pad("control", 12) + "with blocker")
        print(String(repeating: "-", count: 52))
        var stopped = 0
        for (name, _) in probes {
            let before = control[name] ?? "?"
            let after = blocked[name] ?? "?"
            if before == "loaded" && after == "blocked" { stopped += 1 }
            print(pad(name, 20) + pad(before, 12) + after)
        }
        let reachable = probes.filter { control[$0.0] == "loaded" }.count
        print("""

        \(stopped) of \(reachable) reachable trackers blocked.
        """)
        if reachable == 0 {
            print("""
            Nothing loaded in the control either, so this run proves nothing — the machine
            is probably offline. Re-run with a network.
            """)
        } else if stopped == 0 {
            print("""
            The add-on blocked nothing. If it is Manifest V2 it cannot: WebKit grants
            webRequestBlocking without honouring it, and declarativeNetRequest is the only
            blocking mechanism the runtime implements.
            """)
        } else if stopped < reachable {
            print("Partial. Some rulesets may not be enabled — check the add-on's own UI.")
        } else {
            print("Every reachable tracker was blocked.")
        }
        exit(stopped > 0 || reachable == 0 ? 0 : 1)
    }

    /// Loads a page and tries each probe as a script tag, reporting load or failure.
    @available(macOS 15.4, *)
    @MainActor
    private static func measure(browser: BrowserWindowController,
                                label: String) -> [String: String] {
        browser.openTab(url: URL(string: "https://example.com/")!)
        guard let wv = browser.currentTab?.webView else { return [:] }
        wv.load(URLRequest(url: URL(string: "https://example.com/")!))
        settle(5)

        var results: [String: String] = [:]
        for (name, url) in probes {
            results[name] = probe(wv, name: name, url: url)
            print("  \(pad(name, 20)) \(results[name]!)")
        }
        return results
    }

    @MainActor
    private static func probe(_ wv: WKWebView, name: String, url: String) -> String {
        wait(6) { done in
            wv.evaluateJavaScript("""
            (function () {
              window.__probe = 'pending';
              var s = document.createElement('script');
              s.src = '\(url)';
              s.onload = function () { window.__probe = 'loaded'; };
              s.onerror = function () { window.__probe = 'blocked'; };
              document.head.appendChild(s);
              return 'started';
            })()
            """) { _, _ in done() }
        }
        var elapsed = 0.0
        while elapsed < 10 {
            var v: String?
            wait(3) { done in
                wv.evaluateJavaScript("window.__probe") { r, _ in v = r as? String; done() }
            }
            if let v, v != "pending" { return v }
            settle(0.5); elapsed += 0.5
        }
        return "timed out"
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
