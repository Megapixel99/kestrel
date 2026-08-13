import AppKit
import WebKit

/// A/B: enable() once at document-start (the old behaviour) vs enable() again once the
/// document's stylesheets exist (the fix). Same page, same settings, same moment.
enum DarkAB {
    final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done = true }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!,
                     withError e: Error) { done = true }
    }

    static func run(url urlString: String) {
        guard let url = URL(string: urlString),
              let lib = try? String(contentsOf: DarkReaderBridge.libraryURL, encoding: .utf8)
        else { print("Dark Reader not installed"); exit(1) }

        let earlyOnly = """
        \(lib)
        ;(function(){ try { DarkReader.enable({brightness:100,contrast:90,sepia:10,grayscale:0}); } catch(e){} })();
        """
        let deferred = """
        \(lib)
        ;(function(){
          var o = {brightness:100,contrast:90,sepia:10,grayscale:0};
          function a(){ try { DarkReader.enable(o); } catch(e){} }
          a();
          if (document.readyState !== 'complete') {
            document.addEventListener('DOMContentLoaded', a, {once:true});
            window.addEventListener('load', a, {once:true});
          }
          setTimeout(a, 1200);
        })();
        """
        print("Comparing on \(urlString)\n")
        let a = probe(url: url, script: earlyOnly)
        let b = probe(url: url, script: deferred)

        let keys = ["themedRules", "accentCount", "checkboxSize", "distinctColors"]
        print("\(pad("measurement", 20))\(pad("enable() at start", 22))\(pad("+ re-apply on load", 22))")
        print(String(repeating: "-", count: 64))
        for k in keys {
            print(pad(k, 20) + pad("\(a[k] ?? "?")", 22) + pad("\(b[k] ?? "?")", 22))
        }
        let ac = (a["distinctColors"] as? Int) ?? 0
        let bc = (b["distinctColors"] as? Int) ?? 0
        print("\n\(bc > ac ? "the re-apply themes more of the page" : "no measurable difference")"
              + " (\(ac) -> \(bc) distinct colours)")
        exit(0)
    }

    private static func probe(url: URL, script: String) -> [String: Any] {
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = UserAgent.applicationName
        cfg.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let wv = WKWebView(frame: win.contentLayoutRect, configuration: cfg)
        win.contentView?.addSubview(wv)
        let nav = Nav(); wv.navigationDelegate = nav
        wv.load(URLRequest(url: url))
        var t = Date().addingTimeInterval(45)
        while !nav.done && Date() < t { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        t = Date().addingTimeInterval(6)   // past the 1200ms re-apply
        while Date() < t { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

        var out: [String: Any] = [:]
        var done = false
        wv.evaluateJavaScript("""
        (function () {
          let themed = 0;
          for (const sh of document.styleSheets) {
            try {
              if ((sh.ownerNode && sh.ownerNode.classList &&
                   sh.ownerNode.classList.contains('darkreader')) ||
                  (sh.ownerNode && sh.ownerNode.id &&
                   sh.ownerNode.id.indexOf('dark-reader') === 0)) themed += sh.cssRules.length;
            } catch (e) {}
          }
          const colors = new Set();
          let accent = 0;
          for (const el of Array.from(document.querySelectorAll('body *')).slice(0, 900)) {
            const cs = getComputedStyle(el);
            colors.add(cs.backgroundColor);
            colors.add(cs.color);
            // A saturated colour means an accent survived rather than being flattened.
            const m = cs.backgroundColor.match(/\\d+/g);
            if (m && m.length >= 3) {
              const [r,g,b] = m.map(Number);
              if (Math.max(r,g,b) - Math.min(r,g,b) > 40) accent++;
            }
          }
          const cb = document.querySelector('.mdc-checkbox__background, .mdc-checkbox');
          return {
            themedRules: themed,
            accentCount: accent,
            distinctColors: colors.size,
            checkboxSize: cb ? Math.round(cb.getBoundingClientRect().width) : 0
          };
        })();
        """) { r, _ in out = (r as? [String: Any]) ?? [:]; done = true }
        t = Date().addingTimeInterval(20)
        while !done && Date() < t { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return out
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
    }
}
