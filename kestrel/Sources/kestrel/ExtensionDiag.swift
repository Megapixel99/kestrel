import AppKit
import WebKit

/// Reports what an installed add-on actually got, as opposed to what it asked for.
///
///     kestrel extdiag darkreader-4.9.129 https://example.com/
///
/// Written because three add-ons misbehaved in three different-looking ways — Dark Reader
/// saying "This page is protected by browser", an ad blocker blocking nothing, a password
/// manager finding no site — and a guess about the cause turned out to be wrong. The
/// project has been here before (DEBUGGING.md §7): attribute first.
enum ExtensionDiag {

    static func run(args: [String]) {
        guard #available(macOS 15.4, *) else {
            print("WebKit's extension runtime needs macOS 15.4."); exit(0)
        }
        MainActor.assumeIsolated { diagnose(args) }
    }

    @available(macOS 15.4, *)
    @MainActor
    private static func diagnose(_ args: [String]) {
        let installed = ExtensionStore.installed()
        guard !installed.isEmpty else { print("no add-ons installed"); exit(1) }
        let wanted = args.first
        let targets = wanted.map { w in installed.filter { $0.id.contains(w) } } ?? installed
        guard !targets.isEmpty else {
            print("no add-on matching \(wanted ?? "")\navailable: "
                  + installed.map(\.id).joined(separator: ", "))
            exit(1)
        }
        let pageURL = URL(string: args.count > 1 ? args[1] : "https://example.com/")!

        let browser = BrowserWindowController()
        defer { browser.window.close() }
        let runtime = ExtensionRuntime.shared
        runtime.browser = browser
        browser.openTab(url: pageURL)
        guard let tab = browser.currentTab, let wv = tab.webView else {
            print("no tab"); exit(1)
        }

        for ext in targets {
            print("\n=== \(ext.name) \(ext.version) (MV\(ext.manifestVersion)) ===")
            print("manifest asks for: " + ext.permissions.sorted().joined(separator: ", "))

            var err: String?
            wait(20) { done in runtime.load(ext) { e in err = e; done() } }
            guard err == nil, let ctx = runtime.contexts[ext.id] else {
                print("LOAD FAILED: \(err ?? "unknown")")
                continue
            }

            print("granted API perms:  "
                  + ctx.currentPermissions.map(\.rawValue).sorted().joined(separator: ", "))
            print("granted patterns:   "
                  + ctx.currentPermissionMatchPatterns.map(\.string).sorted()
                        .joined(separator: ", "))
            print("access to all hosts: \(ctx.hasAccessToAllHosts)")
            print("access to this page: \(ctx.hasAccess(to: pageURL))")
            print("has injected content: \(ctx.hasInjectedContent)")
            print("injects into this page: \(ctx.hasInjectedContent(for: pageURL))")
            print("content rules: \(ctx.hasContentModificationRules)")
            print("options page: \(ctx.optionsPageURL?.lastPathComponent ?? "none")")
            print("unsupported APIs it was told about: "
                  + (ctx.unsupportedAPIs.isEmpty ? "none"
                     : ctx.unsupportedAPIs.sorted().joined(separator: ", ")))

            // The background page is where most add-ons decide what to do. Forcing it
            // surfaces load errors that otherwise only appear the first time it wakes.
            var bgError: String?
            wait(20) { done in
                ctx.loadBackgroundContent { e in bgError = e?.localizedDescription; done() }
            }
            print("background: \(bgError ?? "loaded")")

            // A real navigation, not loadHTMLString: an add-on that waits on load events
            // or fetches its own resources behaves differently on a synthetic document.
            wv.load(URLRequest(url: pageURL))
            settle(8)

            // What the add-on sees when it asks the browser about the current tab. This
            // is the question behind every one of the three symptoms.
            print("tabs the add-on can see: \(ctx.openTabs.count), "
                  + "windows: \(ctx.openWindows.count), "
                  + "focused: \(ctx.focusedWindow == nil ? "none" : "yes")")
            print("action for tab: "
                  + (ctx.action(for: tab).map { "\($0.label) popup=\($0.presentsPopup)" }
                     ?? "none"))

            // Static analysis says it *would* inject. This asks the page whether it did.
            var probe: String?
            wait(15) { done in
                wv.evaluateJavaScript("""
                (function () {
                  var dr = document.querySelectorAll('style.darkreader').length;
                  var st = getComputedStyle(document.documentElement);
                  return dr + ' darkreader styles, background ' + st.backgroundColor
                       + ', filter ' + st.filter;
                })()
                """) { v, e in
                    probe = (v as? String) ?? e?.localizedDescription
                    done()
                }
            }
            print("in the page: \(probe ?? "no answer")")

            // What user agent the add-on's own pages see. Add-ons written for Firefox
            // branch on this: Dark Reader's canInjectScript() takes a per-browser path,
            // and a UA it does not recognise means "protected page, do nothing".
            if let popup = ctx.action(for: tab)?.popupWebView {
                var ua: String?
                wait(15) { done in
                    popup.evaluateJavaScript("navigator.userAgent") { v, e in
                        ua = (v as? String) ?? e?.localizedDescription
                        done()
                    }
                }
                print("UA inside the add-on: \(ua ?? "no answer")")
            }

            if ctx.errors.isEmpty {
                print("runtime errors: none")
            } else {
                print("runtime errors:")
                for e in ctx.errors.prefix(8) { print("  - \(e.localizedDescription)") }
            }
            runtime.unload(ext.id)
        }
        exit(0)
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
