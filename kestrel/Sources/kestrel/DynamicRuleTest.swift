import AppKit
import WebKit

/// The last hypothesis about ad blocking: does WebKit honour *dynamic* declarativeNetRequest
/// rules, even though it ignores manifest-declared static rulesets?
///
///     kestrel dnrtest
///
/// uBO Lite ships 56 static rulesets, six enabled by default, and blocks nothing here even
/// though `hasContentModificationRules` reports true. Static rulesets and dynamic rules go
/// through different API surfaces, so "accepted but not applied" might be true of only one
/// of them. This builds a minimal Manifest V3 add-on that adds a single dynamic rule at
/// startup and then asks whether the request it names actually fails.
///
/// If dynamic rules work, an add-on *can* block here and the finding is narrower than
/// BROKEN.md #7 currently states. If they do not, the entry stands.
enum DynamicRuleTest {

    private static let target = "https://www.google-analytics.com/analytics.js"

    static func run() {
        guard #available(macOS 15.4, *) else {
            print("WebKit's extension runtime needs macOS 15.4."); exit(0)
        }
        MainActor.assumeIsolated { go() }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func go() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }
        print("Dynamic declarativeNetRequest rules\n")

        // --- a minimal MV3 add-on whose only job is to add one dynamic rule ---
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-dnr-\(getpid())")
        let src = tmp.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        write("""
        {
          "manifest_version": 3,
          "name": "Kestrel DNR Test",
          "version": "1.0",
          "description": "Adds one dynamic blocking rule.",
          "permissions": ["declarativeNetRequest", "storage"],
          "host_permissions": ["<all_urls>"],
          "background": { "service_worker": "bg.js" }
        }
        """, to: src.appendingPathComponent("manifest.json"))

        write("""
        var api = typeof browser !== 'undefined' ? browser : chrome;
        var rule = {
          id: 1,
          priority: 1,
          action: { type: 'block' },
          condition: { urlFilter: 'google-analytics.com', resourceTypes: ['script'] }
        };
        function install() {
          try {
            api.declarativeNetRequest.updateDynamicRules(
              { removeRuleIds: [1], addRules: [rule] },
              function () { api.storage.local.set({ installed: true }); }
            );
          } catch (e) {
            api.storage.local.set({ installed: false, error: String(e) });
          }
        }
        install();
        api.runtime.onInstalled && api.runtime.onInstalled.addListener(install);
        """, to: src.appendingPathComponent("bg.js"))

        let xpi = tmp.appendingPathComponent("dnr-test.xpi")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", src.path, xpi.path]
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try? zip.run(); zip.waitUntilExit()

        guard let ext = try? ExtensionStore.install(from: xpi) else {
            check("packed and installed the test add-on", false)
            finish(failures + 1)
        }
        func done(_ n: Int) -> Never { ExtensionStore.remove(ext); finish(n) }
        check("packed and installed the test add-on", true, "MV\(ext.manifestVersion)")

        let browser = BrowserWindowController()
        defer { browser.window.close() }
        let runtime = ExtensionRuntime.shared
        runtime.browser = browser
        browser.openTab(url: URL(string: "https://example.com/")!)

        var loadError: String?
        wait(25) { done in runtime.load(ext) { e in loadError = e; done() } }
        check("WebKit loaded it", loadError == nil, loadError ?? "")
        guard loadError == nil, let ctx = runtime.contexts[ext.id] else { done(failures + 1) }

        wait(25) { d in ctx.loadBackgroundContent { _ in d() } }
        settle(8)
        print("  hasContentModificationRules: \(ctx.hasContentModificationRules)")

        // --- control first: same probe, no rule, in a tab of its own ---
        let control = probeTarget(browser: browser)
        check("the probe URL loads without a rule", control == "loaded", control)
        guard control == "loaded" else {
            print("\n  Offline, probably — this run cannot answer anything.")
            done(failures)
        }

        // --- and with the dynamic rule installed ---
        let result = probeTarget(browser: browser)
        print("\n  with a dynamic rule blocking it: \(result)")

        if result == "blocked" {
            print("""

            Dynamic rules ARE honoured. BROKEN.md #7 is too broad: an add-on can block here
            if it installs its rules dynamically. uBO Lite's static rulesets are the part
            WebKit ignores.
            """)
        } else {
            print("""

            Dynamic rules are not honoured either, so both declarativeNetRequest surfaces
            are accepted and ignored. BROKEN.md #7 stands: no add-on can block in this
            browser, and WKContentRuleList compiled by the browser itself is the only
            mechanism that works.
            """)
        }
        done(failures)
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func probeTarget(browser: BrowserWindowController) -> String {
        browser.openTab(url: URL(string: "https://example.com/")!)
        guard let wv = browser.currentTab?.webView else { return "no tab" }
        wv.load(URLRequest(url: URL(string: "https://example.com/")!))
        settle(5)
        wait(6) { done in
            wv.evaluateJavaScript("""
            (function () {
              window.__p = 'pending';
              var s = document.createElement('script');
              s.src = '\(target)';
              s.onload = function () { window.__p = 'loaded'; };
              s.onerror = function () { window.__p = 'blocked'; };
              document.head.appendChild(s);
              return 'go';
            })()
            """) { _, _ in done() }
        }
        var elapsed = 0.0
        while elapsed < 12 {
            var v: String?
            wait(3) { done in
                wv.evaluateJavaScript("window.__p") { r, _ in v = r as? String; done() }
            }
            if let v, v != "pending" { return v }
            settle(0.5); elapsed += 0.5
        }
        return "timed out"
    }

    private static func write(_ s: String, to url: URL) {
        try? s.data(using: .utf8)?.write(to: url)
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
        print("\n\(failures == 0 ? "run complete" : "\(failures) check(s) failed")")
        exit(failures == 0 ? 0 : 1)
    }
}
