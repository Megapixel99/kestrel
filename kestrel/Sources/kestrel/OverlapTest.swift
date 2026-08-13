import AppKit
import WebKit

/// Detects visually overlapping text blocks — the objective signature of "the CSS is
/// off" — and compares a page with and without dark mode.
enum OverlapTest {
    final class Nav: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done = true }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!,
                     withError e: Error) { done = true }
    }

    static func run(url urlString: String) {
        guard let url = URL(string: urlString) else { exit(2) }
        print("Checking layout on \(urlString)\n")
        var compiled = false
        ContentBlocker.compile { compiled = $0 != nil }
        var t0 = Date().addingTimeInterval(60)
        while !compiled && Date() < t0 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

        // Four cells: dark and the ad blocker are the only two things Kestrel adds.
        let light = probe(url: url, dark: false, blocker: false)
        let dark = probe(url: url, dark: true, blocker: false)
        let blocked = probe(url: url, dark: false, blocker: true)
        let both = probe(url: url, dark: true, blocker: true)

        print("\(pad("measurement", 20))\(pad("clean", 12))\(pad("dark", 12))"
              + "\(pad("blocker", 12))\(pad("both", 12))")
        print(String(repeating: "-", count: 68))
        for k in ["overlaps", "offscreen", "zeroSize", "textNodes"] {
            print(pad(k, 20) + pad("\(light[k] ?? "?")", 12) + pad("\(dark[k] ?? "?")", 12)
                  + pad("\(blocked[k] ?? "?")", 12) + pad("\(both[k] ?? "?")", 12))
        }
        let lo = (light["overlaps"] as? Int) ?? 0
        let dp = (dark["overlaps"] as? Int) ?? 0
        print("")
        if dp > lo {
            print("dark mode introduces \(dp - lo) overlapping text blocks — excluding the "
                  + "site should fix it")
        } else if dp == lo && lo > 0 {
            print("the overlap is present with and without dark mode: \(lo) blocks. "
                  + "Dark mode is NOT the cause here.")
        } else {
            print("no extra overlap from dark mode")
        }
        if let samples = dark["samples"] as? [String], !samples.isEmpty {
            print("\noverlapping pairs (dark):")
            for s in samples.prefix(6) { print("  \(s)") }
        }
        if let samples = light["samples"] as? [String], !samples.isEmpty {
            print("\noverlapping pairs (light):")
            for s in samples.prefix(6) { print("  \(s)") }
        }
        exit(0)
    }

    private static func probe(url: URL, dark: Bool, blocker: Bool) -> [String: Any] {
        let cfg = WKWebViewConfiguration()
        cfg.applicationNameForUserAgent = UserAgent.applicationName
        if blocker { ContentBlocker.apply(to: cfg) }
        if dark, let s = DarkReaderBridge.userScript() {
            cfg.userContentController.addUserScript(s)
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 950),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let wv = WKWebView(frame: win.contentLayoutRect, configuration: cfg)
        win.contentView?.addSubview(wv)
        let nav = Nav(); wv.navigationDelegate = nav
        wv.load(URLRequest(url: url))
        var t = Date().addingTimeInterval(45)
        while !nav.done && Date() < t { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        t = Date().addingTimeInterval(6)
        while Date() < t { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }

        var out: [String: Any] = [:]
        var done = false
        wv.evaluateJavaScript("""
        (function () {
          // Leaf elements that contain their own text, which is what a reader sees.
          const els = Array.from(document.querySelectorAll('body *')).filter(el => {
            if (!el.firstChild) return false;
            const own = Array.from(el.childNodes)
              .filter(n => n.nodeType === 3 && n.textContent.trim().length > 6);
            if (!own.length) return false;
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0')
              return false;
            const r = el.getBoundingClientRect();
            return r.width > 30 && r.height > 8;
          }).slice(0, 260);

          let overlaps = 0, offscreen = 0, zeroSize = 0;
          const samples = [];
          const rects = els.map(e => [e, e.getBoundingClientRect()]);
          for (const [el, r] of rects) {
            if (r.right < 0 || r.left > window.innerWidth + 200) offscreen++;
            if (r.width < 1 || r.height < 1) zeroSize++;
          }
          for (let i = 0; i < rects.length; i++) {
            for (let j = i + 1; j < rects.length; j++) {
              const [ea, a] = rects[i], [eb, b] = rects[j];
              if (ea.contains(eb) || eb.contains(ea)) continue;   // nesting is normal
              const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left);
              const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
              // Require a substantial overlap so ordinary adjacency does not count.
              if (ox > 40 && oy > 12) {
                overlaps++;
                if (samples.length < 8) {
                  samples.push('"' + (ea.textContent || '').trim().slice(0, 28) + '" x "'
                               + (eb.textContent || '').trim().slice(0, 28) + '"');
                }
              }
            }
          }
          return { overlaps, offscreen, zeroSize, textNodes: els.length, samples };
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
