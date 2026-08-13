import AppKit
import WebKit

/// Proves the content blocker actually blocks in a live web view.
///
/// Written after the blocker silently did nothing: rules compiled fine, but the tabs
/// were created before compilation finished, so no rule list was ever attached. A test
/// that only checks "the JSON compiles" would have passed throughout.
enum AdBlockTest {
    final class Recorder: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var finished = false
        var loaded: [String] = []
        var failed: [String] = []
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { finished = true }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { finished = true }
        func userContentController(_ c: WKUserContentController,
                                   didReceive m: WKScriptMessage) {
            guard let body = m.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let url = body["url"] as? String else { return }
            if kind == "load" { loaded.append(url) } else { failed.append(url) }
        }
    }

    static func run() {
        print("Ad blocker end-to-end test\n")
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — " + detail)")
            if !ok { fails += 1 }
        }

        // Compile first and wait -- the bug under test was doing this asynchronously.
        var compiled = false
        ContentBlocker.compile { compiled = $0 != nil }
        settle(until: { compiled }, timeout: 60)
        check("blocklist compiled", compiled, "\(ContentBlocker.ruleCount) rules")
        guard compiled else { print("\naborting"); exit(1) }

        let cfg = WKWebViewConfiguration()
        let rec = Recorder()
        cfg.userContentController.add(rec, name: "probe")
        ContentBlocker.apply(to: cfg)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let wv = WKWebView(frame: win.contentLayoutRect, configuration: cfg)
        win.contentView?.addSubview(wv)
        wv.navigationDelegate = rec

        // One blocked third-party host, one first-party ad path, one benign control.
        let page = """
        <!doctype html><html><body>
        <div class="ad-container">should be hidden</div>
        <div id="keep">visible</div>
        <script>
        function probe(url) {
          return fetch(url, {mode:'no-cors'})
            .then(() => webkit.messageHandlers.probe.postMessage({kind:'load', url}))
            .catch(() => webkit.messageHandlers.probe.postMessage({kind:'fail', url}));
        }
        Promise.all([
          probe('https://doubleclick.net/pagead/test.js'),
          probe('https://www.google-analytics.com/analytics.js'),
          probe('/pong/get'),
          probe('https://example.com/')
        ]).then(() => { window.__done = true; });
        </script></body></html>
        """
        wv.loadHTMLString(page, baseURL: URL(string: "https://test.invalid/")!)
        settle(until: { rec.finished }, timeout: 30)
        settle(seconds: 6)

        let blockedHit = rec.failed.contains { $0.contains("doubleclick") }
        let analyticsHit = rec.failed.contains { $0.contains("google-analytics") }
        let firstPartyHit = rec.failed.contains { $0.contains("/pong/get") }
        check("third-party ad host blocked", blockedHit,
              "doubleclick — loaded:\(rec.loaded.count) failed:\(rec.failed.count)")
        check("analytics host blocked", analyticsHit, "google-analytics")
        check("first-party ad path blocked", firstPartyHit,
              "/pong/get — the MDN case that third-party rules miss")

        // Cosmetic hiding.
        var adDisplay = "?", keepDisplay = "?"
        var d1 = false, d2 = false
        wv.evaluateJavaScript("getComputedStyle(document.querySelector('.ad-container')).display") { r, _ in
            adDisplay = r as? String ?? "nil"; d1 = true
        }
        wv.evaluateJavaScript("getComputedStyle(document.getElementById('keep')).display") { r, _ in
            keepDisplay = r as? String ?? "nil"; d2 = true
        }
        settle(until: { d1 && d2 }, timeout: 15)
        check("ad container hidden by cosmetic rule", adDisplay == "none", ".ad-container = \(adDisplay)")
        check("non-ad content untouched", keepDisplay != "none", "#keep = \(keepDisplay)")

        print("\n\(fails == 0 ? "ad blocking works" : "\(fails) FAILURES")")
        exit(fails == 0 ? 0 : 1)
    }

    static func settle(seconds: Double) {
        let d = Date().addingTimeInterval(seconds)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    static func settle(until cond: () -> Bool, timeout: Double) {
        let d = Date().addingTimeInterval(timeout)
        while !cond() && Date() < d {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
