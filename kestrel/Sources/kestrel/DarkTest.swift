import AppKit
import WebKit

/// End-to-end check that the Dark Reader bridge actually works in a live page.
///
/// Worth its own mode: the library is a ~340 KB blob inlined into a WKUserScript, and
/// a failure there is silent -- the page simply stays light.
enum DarkTest {
    static func run() {
        print("Dark Reader end-to-end test\n")
        print("  library: \(DarkReaderBridge.version)")
        guard DarkReaderBridge.isAvailable else {
            print("  not installed — nothing to test"); exit(1)
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: win.contentLayoutRect)
        win.contentView = container
        let wv = WKWebView(frame: container.bounds)
        container.addSubview(wv)

        let page = """
        <!doctype html><html><head><style>
          body { background: #ffffff; color: #111111; font-family: system-ui; }
          .card { background: #f5f5f5; border: 1px solid #dddddd; padding: 20px; }
        </style></head><body><div class="card"><h1>Hello</h1><p>Light page.</p></div>
        <img id="pic" width="80" height="60"
             src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%20width='80'%20height='60'%3E%3Crect%20width='80'%20height='60'%20fill='%23ff0000'/%3E%3C/svg%3E">
        </body></html>
        """
        let waiter = NavWaiter()
        wv.navigationDelegate = waiter
        wv.loadHTMLString(page, baseURL: URL(string: "https://example.invalid/"))
        settle(until: { waiter.finishedAt != nil }, timeout: 20)
        settle(seconds: 1.0)

        func bg(_ label: String) -> String {
            var out = "?"
            var done = false
            wv.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") { r, _ in
                out = r as? String ?? "nil"; done = true
            }
            settle(until: { done }, timeout: 10)
            print("  body background \(label): \(out)")
            return out
        }

        let before = bg("before")

        var toggled: Any?
        var done = false
        wv.evaluateJavaScript(DarkReaderBridge.effectiveToggleJS()) { r, e in
            toggled = r ?? e.map { "error: \($0.localizedDescription)" as Any }
            done = true
        }
        settle(until: { done }, timeout: 30)
        settle(seconds: 1.5)
        print("  toggle returned: \(toggled ?? "nil")")

        var drDefined = false
        var d2 = false
        wv.evaluateJavaScript("typeof DarkReader !== 'undefined'") { r, _ in
            drDefined = (r as? Bool) ?? false; d2 = true
        }
        settle(until: { d2 }, timeout: 10)

        let after = bg("after")

        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — " + detail)")
            if !ok { fails += 1 }
        }
        check("DarkReader is defined in the page", drDefined)
        check("toggle reported enabled", (toggled as? Bool) == true, "\(toggled ?? "nil")")
        check("page background actually changed", before != after, "\(before) -> \(after)")
        check("background is now dark", isDark(after), after)

        print("\n\(fails == 0 ? "Dark Reader works end to end" : "\(fails) FAILURES")")
        exit(fails == 0 ? 0 : 1)
    }

    /// rgb(r, g, b) -> luma below mid?
    static func isDark(_ css: String) -> Bool {
        let nums = css.split(whereSeparator: { !"0123456789".contains($0) })
                      .compactMap { Double($0) }
        guard nums.count >= 3 else { return false }
        return (0.299 * nums[0] + 0.587 * nums[1] + 0.114 * nums[2]) < 128
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
