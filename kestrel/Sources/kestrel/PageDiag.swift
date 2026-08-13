import AppKit
import WebKit

/// Loads a URL in four configurations and reports what each one changes, so a rendering
/// complaint can be attributed instead of guessed at.
///
/// Read-only: it inspects computed styles and element visibility. It never types into
/// the page, and it does not touch form values.
enum PageDiag {
    static func run(urlString: String) {
        guard let url = URL(string: urlString) else { exit(2) }
        print("Diagnosing \(urlString)\n")

        var compiled = false
        ContentBlocker.compile { compiled = $0 != nil }
        settle(until: { compiled }, timeout: 60)

        // The UA comparison first: a server that sniffs can serve different CSS
        // entirely, which no amount of client-side inspection would explain.
        useRealUA = false
        let stock = probe(url: url, blocker: false, dark: false)
        useRealUA = true
        let real = probe(url: url, blocker: false, dark: false)
        print("  stylesheets  stock UA: \(stock["sheets"] ?? "?")   "
              + "with Safari token: \(real["sheets"] ?? "?")")
        print("  rules        stock UA: \(stock["rules"] ?? "?")   "
              + "with Safari token: \(real["rules"] ?? "?")")
        print("  body classes stock UA: \(stock["bodyClass"] ?? "?")")
        print("               real  UA: \(real["bodyClass"] ?? "?")\n")

        let configs: [(String, Bool, Bool)] = [
            ("baseline (no blocker, no dark)", false, false),
            ("blocker only", true, false),
            ("dark only", false, true),
            ("blocker + dark", true, true),
        ]
        var results: [String: [String: Any]] = [:]
        for (name, blocker, dark) in configs {
            print("  loading: \(name)")
            results[name] = probe(url: url, blocker: blocker, dark: dark)
        }

        print("\n\(pad("configuration", 32))\(pad("hidden", 9))\(pad("inputs", 8))"
              + "\(pad("checkbox", 22))\(pad("visible?", 9))")
        print(String(repeating: "-", count: 82))
        for (name, _, _) in configs {
            let r = results[name] ?? [:]
            print(pad(name, 32)
                  + pad("\(r["hiddenCount"] ?? "?")", 9)
                  + pad("\(r["inputCount"] ?? "?")", 8)
                  + pad("\(r["checkboxStyle"] ?? "?")", 22)
                  + pad("\(r["checkboxVisible"] ?? "?")", 9))
        }

        // Attribution: only elements hidden *in addition to* the baseline are ours.
        let base = Set((results["baseline (no blocker, no dark)"]?["hiddenSelectors"]
                        as? [String]) ?? [])
        let withBlocker = Set((results["blocker only"]?["hiddenSelectors"] as? [String]) ?? [])
        let extra = withBlocker.subtracting(base)
        print("\n  hidden by the blocker beyond what the page already hides: "
              + "\(extra.count)")
        for h in extra.sorted().prefix(10) { print("    \(h)") }

        let baseUA = results["baseline (no blocker, no dark)"]?["ua"] as? String ?? "?"
        print("\n  user agent: \(baseUA)")

        // Did dark mode change any form control?
        for key in ["baseline (no blocker, no dark)", "dark only"] {
            let r = results[key] ?? [:]
            print("  \(pad(key, 32)) checkbox bg=\(r["checkboxBG"] ?? "?") "
                  + "size=\(r["checkboxSize"] ?? "?")")
        }
        exit(0)
    }

    /// Set by run() so the same page can be compared with and without a real UA.
    static var useRealUA = true

    private static func probe(url: URL, blocker: Bool, dark: Bool) -> [String: Any] {
        let cfg = WKWebViewConfiguration()
        if useRealUA { cfg.applicationNameForUserAgent = UserAgent.applicationName }
        if blocker { ContentBlocker.apply(to: cfg) }
        if dark {
            cfg.userContentController.addUserScript(
                DarkReaderBridge.userScript() ?? DarkMode.script())
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let wv = WKWebView(frame: win.contentLayoutRect, configuration: cfg)
        win.contentView?.addSubview(wv)
        let waiter = NavWaiter()
        wv.navigationDelegate = waiter
        wv.load(URLRequest(url: url))
        settle(until: { waiter.finishedAt != nil }, timeout: 45)
        settle(seconds: 3.5)

        let js = """
        (function () {
          const out = {};
          const all = Array.from(document.querySelectorAll('body *'));
          out.inputCount = document.querySelectorAll('input').length;
          const hidden = all.filter(el => {
            const cs = getComputedStyle(el);
            return cs.display === 'none' && (el.textContent || '').trim().length > 0;
          });
          out.hiddenCount = hidden.length;
          out.hiddenSelectors = hidden.slice(0, 12).map(el =>
            el.tagName.toLowerCase()
            + (el.id ? '#' + el.id : '')
            + (el.className && typeof el.className === 'string'
               ? '.' + el.className.trim().split(/\\s+/).slice(0,2).join('.') : '')
            + ' — "' + (el.textContent || '').trim().slice(0, 40) + '"');
          const cb = document.querySelector('input[type=checkbox]');
          if (cb) {
            const cs = getComputedStyle(cb);
            const r = cb.getBoundingClientRect();
            out.checkboxStyle = cs.appearance + '/' + cs.opacity;
            out.checkboxVisible = (r.width > 1 && r.height > 1 && cs.display !== 'none'
                                   && cs.visibility !== 'hidden') ? 'yes' : 'NO';
          } else { out.checkboxStyle = 'none found'; out.checkboxVisible = '—'; }
          out.ua = navigator.userAgent;
          out.sheets = document.styleSheets.length;
          let rules = 0;
          for (const sh of document.styleSheets) {
            try { rules += sh.cssRules.length; } catch (e) { rules += -1; }
          }
          out.rules = rules;
          out.bodyClass = (document.body.className || '(none)').slice(0, 60);
          // The visible control on Material pages is a sibling, not the input itself.
          const mark = document.querySelector('.mdc-checkbox__background, .mdc-checkbox, '
                       + '.checkbox, label > span');
          if (mark) {
            const cs2 = getComputedStyle(mark);
            const r2 = mark.getBoundingClientRect();
            out.checkboxBG = cs2.backgroundColor + '/' + cs2.borderColor;
            out.checkboxSize = Math.round(r2.width) + 'x' + Math.round(r2.height);
          } else { out.checkboxBG = 'no marker'; out.checkboxSize = '—'; }
          return out;
        })();
        """
        var result: [String: Any] = [:]
        var done = false
        wv.evaluateJavaScript(js) { r, e in
            result = (r as? [String: Any]) ?? ["error": e?.localizedDescription ?? "?"]
            done = true
        }
        settle(until: { done }, timeout: 20)
        return result
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n - 1)) + " " : s + String(repeating: " ", count: n - s.count)
    }
    static func settle(seconds: Double) {
        let d = Date().addingTimeInterval(seconds)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    static func settle(until c: () -> Bool, timeout: Double) {
        let d = Date().addingTimeInterval(timeout)
        while !c() && Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
}
