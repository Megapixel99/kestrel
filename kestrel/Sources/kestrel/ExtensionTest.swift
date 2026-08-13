import AppKit
import WebKit

/// Proves a WebExtension actually runs, rather than that one loaded without error.
///
/// Loading is the easy half and the misleading half — `controller.load()` succeeds for an
/// extension whose content script never fires, which is exactly the failure mode the ad
/// blocker had (DEBUGGING.md §3). So this builds a real add-on on disk in the Firefox
/// format, packs it as an `.xpi`, installs it through the same path the UI uses, and then
/// checks the page for a DOM node only the content script could have created.
enum ExtensionTest {

    static func run() {
        guard #available(macOS 15.4, *) else {
            print("SKIP  WebKit's extension runtime needs macOS 15.4; this is "
                  + ProcessInfo.processInfo.operatingSystemVersionString)
            exit(0)
        }
        MainActor.assumeIsolated { runAvailable() }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func runAvailable() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
            if !ok { failures += 1 }
        }

        // --- build a Firefox add-on, as an .xpi ---
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kestrel-exttest-\(getpid())")
        let src = tmp.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        write(manifest, to: src.appendingPathComponent("manifest.json"))
        write(contentScript, to: src.appendingPathComponent("content.js"))
        write(background, to: src.appendingPathComponent("background.js"))
        write("<html><body><h1 id=\"opts\">kestrel-options-page</h1></body></html>",
              to: src.appendingPathComponent("options.html"))

        let xpi = tmp.appendingPathComponent("kestrel-test.xpi")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", src.path, xpi.path]
        zip.standardOutput = Pipe(); zip.standardError = Pipe()
        try? zip.run(); zip.waitUntilExit()
        check("packed a .xpi", zip.terminationStatus == 0)

        // --- install it the way the UI does ---
        var installed: ExtensionStore.Installed?
        do { installed = try ExtensionStore.install(from: xpi) }
        catch { check("installed the .xpi", false, error.localizedDescription) }
        guard let ext = installed else { finish(failures + 1) }
        // Not `defer`: finish() calls exit(), which does not run deferred blocks, so the
        // first version of this test left its add-on installed in ~/.kestrel/extensions
        // and it showed up in the real UI.
        func finishAndClean(_ n: Int) -> Never {
            ExtensionStore.remove(ext)
            finish(n)
        }

        check("unpacked and read the manifest", ext.name == "Kestrel Test Add-on",
              "name = \(ext.name)")
        check("read manifest version", ext.manifestVersion == 2)
        check("read declared permissions", Set(ext.apiPermissions).contains("storage"))
        check("read host permissions", ext.hostPatterns == ["<all_urls>"])

        // The compatibility report is the honest half of this feature: it has to notice
        // the Gecko-only key this manifest deliberately includes.
        check("flagged the Gecko-only manifest key",
              ExtensionStore.gaps(in: ext).contains("sidebar panel"),
              ExtensionStore.gaps(in: ext).joined(separator: ", "))

        // --- load it into WebKit's runtime ---
        let runtime = ExtensionRuntime.shared
        var loadError: String? = "not attempted"
        wait(seconds: 10) { done in
            runtime.load(ext) { err in loadError = err; done() }
        }
        check("WebKit loaded the extension", loadError == nil, loadError ?? "")
        guard loadError == nil, let ctx = runtime.contexts[ext.id] else {
            finishAndClean(failures + 1)
        }

        check("granted the declared permissions", ctx.hasAccessToAllHosts)
        check("extension declares injected content", ctx.hasInjectedContent)

        // --- and the part that actually matters: does the content script run? ---
        // Through a real window and a real tab, not a bare web view: WebKit only injects
        // into a web view the runtime can trace back to a registered tab, and the whole
        // point of the exercise is the path the browser actually takes.
        let browser = BrowserWindowController()
        defer { browser.window.close() }
        runtime.browser = browser
        browser.openTab(url: URL(string: "https://example.com/")!)
        guard let tab = browser.currentTab, let wv = tab.webView else {
            check("opened a tab for the extension to see", false)
            finishAndClean(failures + 1)
        }
        ctx.didOpenWindow(browser)
        ctx.didFocusWindow(browser)
        ctx.didOpenTab(tab)
        ctx.didActivateTab(tab, previousActiveTab: nil)

        // A base URL rather than a file:// page: `<all_urls>` deliberately excludes
        // file://, so a local page is invisible to content scripts in every browser.
        wv.loadHTMLString("<html><body><h1>kestrel</h1></body></html>",
                          baseURL: URL(string: "https://example.com/"))

        var marker: String?
        wait(seconds: 15) { done in
            poll(wv, every: 0.4, until: 14) { value in
                marker = value
                done()
            }
        }
        check("the content script ran in the page", marker == "kestrel-content-script-ran",
              marker ?? "no marker element appeared")

        // The background script answers a message from the content script; a reply proves
        // the two halves of the extension are talking, not just that a file was injected.
        var reply: String?
        wait(seconds: 8) { done in
            wv.evaluateJavaScript(
                "document.getElementById('kestrel-test')?.dataset.reply ?? ''") { v, _ in
                reply = v as? String
                done()
            }
        }
        check("the background script replied to it", reply == "pong",
              reply.map { $0.isEmpty ? "no reply" : $0 } ?? "no reply")

        // The options page lives at webkit-extension://…, which only loads in a web view
        // built from the extension's own configuration — WebKit cancels the navigation in
        // any other. A plain tab showed nothing at all, with no error.
        var optionsText: String?
        if let optionsURL = ctx.optionsPageURL {
            check("the extension has an options page", true, optionsURL.lastPathComponent)
            let opened = browser.openExtensionPage(optionsURL)
            check("opened it in a tab of its own", opened)
            if opened, let ov = browser.currentTab?.webView {
                wait(seconds: 15) { done in
                    poll(ov, every: 0.4, until: 14, script:
                         "document.getElementById('opts')?.textContent ?? ''") { v in
                        optionsText = v; done()
                    }
                }
            }
            check("the options page rendered", optionsText == "kestrel-options-page",
                  optionsText ?? "blank")
        } else {
            check("the extension has an options page", false, "optionsPageURL was nil")
        }

        runtime.unload(ext.id)
        finishAndClean(failures)
    }

    // MARK: - the add-on under test

    private static let manifest = """
    {
      "manifest_version": 2,
      "name": "Kestrel Test Add-on",
      "version": "1.0",
      "description": "Injects a marker element and pings its background script.",
      "permissions": ["storage", "<all_urls>"],
      "background": { "scripts": ["background.js"], "persistent": false },
      "content_scripts": [
        { "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end" }
      ],
      "options_ui": { "page": "options.html", "open_in_tab": true },
      "sidebar_action": { "default_panel": "panel.html", "default_title": "Nope" },
      "browser_specific_settings": { "gecko": { "id": "test@kestrel" } }
    }
    """

    /// Standard WebExtension code — `browser.*` with a `chrome.*` fallback, exactly what
    /// a real Firefox add-on ships.
    private static let contentScript = """
    (function () {
      var api = typeof browser !== 'undefined' ? browser : chrome;
      var el = document.createElement('div');
      el.id = 'kestrel-test';
      el.textContent = 'kestrel-content-script-ran';
      el.style.display = 'none';
      document.documentElement.appendChild(el);
      api.runtime.sendMessage({ ping: true }, function (response) {
        el.dataset.reply = (response && response.pong) ? 'pong' : 'no-reply';
      });
    })();
    """

    private static let background = """
    (function () {
      var api = typeof browser !== 'undefined' ? browser : chrome;
      api.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
        if (msg && msg.ping) { sendResponse({ pong: true }); return true; }
      });
    })();
    """

    // MARK: - helpers

    private static func write(_ s: String, to url: URL) {
        try? s.data(using: .utf8)?.write(to: url)
    }

    /// Polls the page for the marker instead of waiting a fixed interval: content script
    /// timing is not something to guess at, and a fixed sleep is how a flaky test starts.
    @MainActor
    private static func poll(_ wv: WKWebView, every: TimeInterval, until deadline: TimeInterval,
                             script: String =
                                "document.getElementById('kestrel-test')?.textContent ?? ''",
                             found: @escaping (String?) -> Void) {
        var elapsed: TimeInterval = 0
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { t in
            elapsed += every
            wv.evaluateJavaScript(script) { v, _ in
                let s = v as? String ?? ""
                if !s.isEmpty {
                    t.invalidate(); timer = nil; found(s)
                } else if elapsed >= deadline {
                    t.invalidate(); timer = nil; found(nil)
                }
            }
        }
        _ = timer
    }

    private static func wait(seconds: TimeInterval, _ body: (@escaping () -> Void) -> Void) {
        var done = false
        body { done = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func finish(_ failures: Int) -> Never {
        print("\n\(failures == 0 ? "Firefox add-ons load and run" : "\(failures) check(s) failed")")
        exit(failures == 0 ? 0 : 1)
    }
}
