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
        write("""
              <html><body style="width:220px;margin:0">
                <div id="pop" style="padding:14px">kestrel-popup-rendered</div>
              </body></html>
              """, to: src.appendingPathComponent("popup.html"))

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

        // --- the browser's real order: a tab exists first, the add-on loads second ---
        // A web view's extension controller cannot be set after creation, so a tab opened
        // before any add-on loaded must still have been given one. It was not, for months:
        // every add-on was dead in the first tab of every launch and in every tab open when
        // one was installed. Creating the window here, before the load, is what makes this
        // test able to fail.
        let browser = BrowserWindowController()
        defer { browser.window.close() }
        browser.openTab(url: URL(string: "https://example.com/")!)

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
        runtime.browser = browser
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

        // Can the add-on see the browser at all? Every symptom of the tab events never
        // being forwarded looks like something else: Dark Reader reports "This page is
        // protected by browser", an ad blocker blocks nothing, a password manager finds
        // no matching site. All of them are tabs.query() coming back empty.
        var tabsSeen: String?
        wait(seconds: 10) { done in
            poll(wv, every: 0.5, until: 9,
                 script: "document.getElementById('kestrel-test')?.dataset.tabs ?? ''") { v in
                tabsSeen = v; done()
            }
        }
        check("the add-on can see the open tab", tabsSeen?.contains("example.com") == true,
              tabsSeen ?? "tabs.query returned nothing")

        // And a tab opened after the add-on loaded, which is the case that was broken:
        // tabs were announced once at load and never again.
        browser.openTab(url: URL(string: "https://example.org/")!)
        browser.currentTab?.webView?.loadHTMLString(
            "<html><body>second</body></html>", baseURL: URL(string: "https://example.org/"))
        var tabsAfter: String?
        wait(seconds: 12) { done in
            poll(wv, every: 0.5, until: 11,
                 script: "document.getElementById('kestrel-test')?.dataset.tabs ?? ''",
                 matching: "example.org") { v in tabsAfter = v; done() }
        }
        check("a tab opened later shows up too",
              tabsAfter?.contains("example.org") == true,
              tabsAfter ?? "never appeared")

        // What a content script's `sender` carries. Add-ons key their per-tab state on
        // it — Dark Reader's canAccessTab() is literally `Boolean(tabs[tab.id])`,
        // populated only from sender.tab.id — so a missing field disables the add-on
        // with a message about the page being protected.
        var senderInfo: String?
        wait(seconds: 12) { done in
            poll(wv, every: 0.5, until: 11,
                 script: "document.getElementById('kestrel-test')?.dataset.sender ?? ''") { v in
                senderInfo = v; done()
            }
        }
        check("the background sees which tab a message came from",
              senderInfo?.contains("tab=true") == true, senderInfo ?? "no sender info")
        check("...including the tab's URL",
              senderInfo?.contains("url=https://example.com") == true, senderInfo ?? "")
        check("...and a frame id",
              senderInfo?.contains("frame=none") == false, senderInfo ?? "")

        // The direction that actually delivers work. A content script that can talk to
        // its background but cannot be talked *to* looks exactly like Dark Reader here:
        // injected, permitted, and doing nothing to the page.
        var pushed: String?
        wait(seconds: 12) { done in
            poll(wv, every: 0.5, until: 11,
                 script: "document.getElementById('kestrel-test')?.dataset.push ?? ''") { v in
                pushed = v; done()
            }
        }
        check("the background can message the content script back",
              pushed == "received", pushed ?? "tabs.sendMessage never arrived")

        var portState: String?
        wait(seconds: 12) { done in
            poll(wv, every: 0.5, until: 11,
                 script: "document.getElementById('kestrel-test')?.dataset.port ?? ''") { v in
                portState = v; done()
            }
        }
        check("runtime.connect ports work", portState == "acked",
              portState ?? "no reply over the port")

        // The popup: WebKit rendering the add-on's own HTML. This had no coverage at all
        // because it looks like it needs a click — but the action hands over its web view,
        // and a popup that renders blank or collapses to nothing is exactly what a headless
        // check can see.
        if let action = ctx.action(for: tab) {
            check("the add-on declares a popup", action.presentsPopup)
            if let popup = action.popupWebView {
                var text: String?
                wait(seconds: 12) { done in
                    poll(popup, every: 0.4, until: 11,
                         script: "document.getElementById('pop')?.textContent ?? ''") { v in
                        text = v; done()
                    }
                }
                check("the popup rendered its own HTML", text == "kestrel-popup-rendered",
                      text ?? "blank")

                var size: String?
                wait(seconds: 8) { done in
                    popup.evaluateJavaScript(
                        "document.body.scrollWidth + 'x' + document.body.scrollHeight") { v, _ in
                        size = v as? String; done()
                    }
                }
                let dims = (size ?? "0x0").split(separator: "x").compactMap { Int($0) }
                check("...at a usable size", dims.count == 2 && dims[0] > 40 && dims[1] > 10,
                      size ?? "no answer")
            } else {
                check("the popup has a web view", false)
            }
        } else {
            check("the add-on has a toolbar action", false)
        }

        // A popup wider than the space to the right of its button used to hang off the
        // side of the window: AppKit constrains a popover to the screen, not to the window.
        if let action = ctx.action(for: tab), let pop = action.popupPopover {
            browser.window.setContentSize(NSSize(width: 1000, height: 700))
            browser.window.layoutIfNeeded()
            browser.refreshExtensionButtons()

            if let button = browser.extensionBar.subviews.first {
                let rect = runtime.anchorRect(for: pop, in: button)
                // Where the popover will centre itself, in window coordinates.
                let centre = button.convert(NSPoint(x: rect.midX, y: 0), to: nil).x
                // contentSize reads 0x0 for a real add-on popup, which is why the
                // positioning assumes a width; the test has to use the same figure or it
                // is testing something the browser never does.
                let assumed = ExtensionRuntime.assumedPopupWidth
                let left = centre - assumed / 2
                let right = centre + assumed / 2
                let content = browser.window.contentLayoutRect
                check("a wide popup is kept inside the window",
                      left >= content.minX - 1 && right <= content.maxX + 1,
                      "popup spans \(Int(left))…\(Int(right)) in a window "
                      + "\(Int(content.minX))…\(Int(content.maxX))")
            } else {
                check("the add-on has a toolbar button to anchor to", false)
            }
        }

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
      "permissions": ["storage", "tabs", "<all_urls>"],
      "background": { "scripts": ["background.js"], "persistent": false },
      "content_scripts": [
        { "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end" }
      ],
      "browser_action": { "default_popup": "popup.html", "default_title": "Kestrel Test" },
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
      api.runtime.onMessage.addListener(function (m) {
        if (m && m.fromBackground) {
          var n = document.getElementById('kestrel-test');
          if (n) n.dataset.push = 'received';
        }
      });
      el.id = 'kestrel-test';
      el.textContent = 'kestrel-content-script-ran';
      el.style.display = 'none';
      document.documentElement.appendChild(el);
      api.runtime.sendMessage({ ping: true }, function (response) {
        el.dataset.reply = (response && response.pong) ? 'pong' : 'no-reply';
      });
      // Polled, not asked once: the point is whether tabs opened *after* this script
      // ran are visible to the extension.
      setInterval(function () {
        api.runtime.sendMessage({ tabs: true }, function (r) {
          if (r) el.dataset.tabs = String(r.count) + '|' + r.urls;
        });
        api.runtime.sendMessage({ pushToTab: true }, function () {});
      try {
        var port = api.runtime.connect({ name: 'kestrel-port' });
        port.onMessage.addListener(function (m) {
          if (m && m.ack) {
            var n = document.getElementById('kestrel-test');
            if (n) n.dataset.port = 'acked';
          }
        });
        port.postMessage({ hello: true });
      } catch (e) {
        var n0 = document.getElementById('kestrel-test');
        if (n0) n0.dataset.port = 'threw: ' + e;
      }
        api.runtime.sendMessage({ sender: true }, function (r) {
          if (r) el.dataset.sender = 'tab=' + r.hasTab + ' id=' + r.tabId
                                   + ' url=' + r.tabURL + ' frame=' + r.frameId
                                   + ' doc=' + r.docId;
        });
      }, 500);
    })();
    """

    private static let background = """
    (function () {
      var api = typeof browser !== 'undefined' ? browser : chrome;
      // Long-lived ports. Dark Reader's Firefox build wires its UI to the background
      // with runtime.onConnect rather than one-shot messages.
      api.runtime.onConnect.addListener(function (port) {
        port.onMessage.addListener(function (m) {
          if (m && m.hello) port.postMessage({ ack: true });
        });
      });
      api.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
        // Background -> content script. Dark Reader delivers its theme this way: the
        // content script announces itself, the background answers with tabs.sendMessage.
        if (msg && msg.pushToTab && sender && sender.tab) {
          api.tabs.sendMessage(sender.tab.id, { fromBackground: true });
          sendResponse({ sent: true });
          return true;
        }
        if (msg && msg.ping) { sendResponse({ pong: true }); return true; }
        if (msg && msg.sender) {
          // Dark Reader's TabManager.addFrame() keys its per-tab state on
          // sender.tab.id / frameId / documentId. Without them canAccessTab() is
          // false for every tab and the popup says the page is protected.
          sendResponse({
            hasTab: !!(sender && sender.tab),
            tabId: sender && sender.tab ? sender.tab.id : 'none',
            tabURL: sender && sender.tab ? (sender.tab.url || 'no-url') : 'none',
            frameId: (sender && sender.frameId !== undefined) ? sender.frameId : 'none',
            docId: (sender && sender.documentId) ? 'yes' : 'none',
            url: (sender && sender.url) || 'none'
          });
          return true;
        }
        if (msg && msg.tabs) {
          api.tabs.query({}, function (tabs) {
            sendResponse({ count: tabs.length,
                           urls: tabs.map(function (t) { return t.url || '?'; }).join(' ') });
          });
          return true;
        }
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
                             matching: String? = nil,
                             found: @escaping (String?) -> Void) {
        var elapsed: TimeInterval = 0
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { t in
            elapsed += every
            wv.evaluateJavaScript(script) { v, _ in
                let s = v as? String ?? ""
                let hit = matching.map { s.contains($0) } ?? !s.isEmpty
                if hit {
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
