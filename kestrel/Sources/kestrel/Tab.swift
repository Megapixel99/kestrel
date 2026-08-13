import AppKit
import WebKit

enum TabState: Int, Comparable, CustomStringConvertible {
    case stub = 0, cold = 1, warm = 2, live = 3
    static func < (a: TabState, b: TabState) -> Bool { a.rawValue < b.rawValue }
    var description: String {
        switch self {
        case .live: return "LIVE"; case .warm: return "WARM"
        case .cold: return "COLD"; case .stub: return "STUB"
        }
    }
}

/// One tab, and its position on the DESIGN.md §2 ladder.
///
/// Measured behaviour of each rung on WKWebView (see RESULTS-ENGINE.md):
///   LIVE  128 MB   full page
///   WARM  106 MB   detached + media suspended + timers cleared -- only 17% back,
///                  because a host app cannot compact WebKit's heap
///   COLD   39 MB   interactionState captured, page navigated away -- 70% back,
///                  restores in ~82 ms
///   STUB   ~0 MB   web view destroyed (but see the process-cache caveat)
final class Tab: NSObject {
    let id: Int
    var url: URL
    var title: String
    private(set) var state: TabState = .stub

    var webView: WKWebView?
    var pid: Int32?
    var sessionImage: Data?          // WKWebView.interactionState -- the COLD image
    var snapshot: NSImage?

    var lastUsed = Date()
    var uses = 0
    var pinned = false
    var audible = false
    var hasUnsubmittedInput = false

    /// Auto-refresh interval in seconds, nil = off. A tab on a refresh timer is a live
    /// dashboard: demoting it defeats the point, so it gets a LIVE floor in the
    /// scheduler -- and that costs real memory, which the UI shows.
    var refreshInterval: TimeInterval?
    var lastRefresh = Date()
    /// Seeded from the saved preference so a new tab opens dark when that is the default.
    var darkMode: Bool = Prefs.darkByDefault

    /// Last measured footprint while LIVE. Measured, never estimated -- DESIGN.md §2
    /// requires bytes_recoverable to come from real numbers.
    var measuredLiveBytes: Int64 = 0
    var lastRestoreMs: Double = 0

    /// Set from the navigation delegate; drives the tab-strip spinner.
    var isLoading = false
    var progress: Double = 0

    weak var host: NSView?

    /// Refreshed by the background sampler so tab creation never has to run `ps`
    /// synchronously on the main thread.
    static var lastKnownPids: Set<Int32> = []

    // NSObject because WKWebExtensionTab requires it: WebKit's extension runtime talks
    // to tabs through an Objective-C protocol.
    init(id: Int, url: URL, title: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
            ?? (NewTabPage.isNewTab(url) ? "New Tab" : (url.host ?? url.absoluteString))
        super.init()
    }

    /// Last sampled footprint. Reading this is free.
    ///
    /// It used to spawn /usr/bin/footprint on every read -- 226 ms a call, roughly
    /// eight reads per UI tick, i.e. more main-thread blocking than there was wall
    /// clock. That is what made scrolling stutter: a quarter of frames during a scroll
    /// were dropped. Sampling now happens on a background queue; the UI only ever reads
    /// the cache.
    var cachedBytes: Int64 = 0
    var currentBytes: Int64 { cachedBytes }

    /// Pure and thread-safe: does the expensive measurement without touching `self`.
    /// Call from a background queue, then assign the result to `cachedBytes` on main.
    func sampleFootprint() -> Int64 {
        guard let pid, state >= .cold, MemoryProbe.isAlive(pid) else { return 0 }
        return MemoryProbe.footprint(pid: pid) ?? 0
    }

    /// Synchronous measure-and-store, for headless code where blocking is fine.
    @discardableResult
    func measureNow() -> Int64 {
        cachedBytes = sampleFootprint()
        return cachedBytes
    }

    // MARK: - ladder transitions

    @discardableResult
    func promote(to target: TabState, in container: NSView) -> Double {
        guard target > state else { return 0 }
        let t0 = Date()
        switch target {
        case .live: makeLive(in: container)
        case .warm: makeLive(in: container); makeWarm()
        default: break
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        lastRestoreMs = ms
        return ms
    }

    func demote(to target: TabState) {
        guard target < state else { return }
        var s = state
        while s > target {
            switch s {
            case .live: makeWarm(); s = .warm
            case .warm: makeCold(); s = .cold
            case .cold: makeStub(); s = .stub
            case .stub: return
            }
        }
    }

    /// Ensure this tab's web view is in the given container.
    ///
    /// Separate from promote() on purpose: a tab that is already LIVE but detached from
    /// the view hierarchy (because another tab was shown) needs re-attaching without a
    /// state change. promote() short-circuits on `target > state`, so relying on it for
    /// this is what broke tab switching.
    func ensureAttached(to container: NSView) {
        guard let wv = webView else { return }
        if wv.superview !== container {
            wv.removeFromSuperview()
            wv.frame = container.bounds
            wv.autoresizingMask = [.width, .height]
            container.addSubview(wv)
        }
        wv.frame = container.bounds
    }

    /// An extension page — `webkit-extension://…/options.html` — can only load in a web
    /// view built from its own context's configuration. WebKit cancels the navigation
    /// otherwise, which is what made an add-on's options page come up blank. When this is
    /// set the tab uses it verbatim and skips the page-facing injections: dark mode and
    /// userscripts have no business inside an extension's own UI.
    var extensionConfig: WKWebViewConfiguration?

    private func makeLive(in container: NSView) {
        if webView == nil, let cfg = extensionConfig {
            cfg.applicationNameForUserAgent = UserAgent.applicationName
            let wv = WKWebView(frame: container.bounds, configuration: cfg)
            wv.autoresizingMask = [.width, .height]
            webView = wv
            container.addSubview(wv)
            loadCurrent(into: wv)
        } else if webView == nil {
            let before = Tab.lastKnownPids
            let cfg = WKWebViewConfiguration()
            cfg.processPool = WKProcessPool()
            // Declarative blocking + userscripts are attached per web view, so a tab
            // restored from COLD comes back with them already applied.
            // WKWebView's stock UA stops after "(KHTML, like Gecko)" — no product
            // token at all — so sniffers cannot identify it and sites like Google Meet
            // refuse outright. Appending the Safari token completes it, which is
            // accurate: this really is WebKit.
            cfg.applicationNameForUserAgent = UserAgent.applicationName
            ContentBlocker.apply(to: cfg)
            // Extensions attach per configuration, so a tab restored from COLD comes
            // back with the same add-ons the rest of the window has.
            if #available(macOS 15.4, *) {
                MainActor.assumeIsolated {
                    ExtensionRuntime.apply(to: cfg)
                    ExtensionWeb.attach(to: cfg)
                }
            }
            for script in UserScriptStore.loadAll()
            where Prefs.isScriptEnabled(script.name) {
                cfg.userContentController.addUserScript(script.wrapped())
            }
            if darkMode && !Prefs.isDarkExcluded(host: url.host) {
                // At document start so a restored dark tab never flashes light.
                cfg.userContentController.addUserScript(
                    DarkReaderBridge.userScript() ?? DarkMode.script())
            }
            let wv = WKWebView(frame: container.bounds, configuration: cfg)
            wv.autoresizingMask = [.width, .height]
            webView = wv
            container.addSubview(wv)
            if let sessionImage { wv.interactionState = sessionImage }
            loadCurrent(into: wv)
            // Identify the new WebContent process so we can measure this tab. Both the
            // `ps` call and the diff run off the main thread; only the assignment
            // hops back.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                let after = Set(MemoryProbe.webContentPids())
                Tab.lastKnownPids = after
                let found = after.subtracting(before).first
                DispatchQueue.main.async { if let found { self?.pid = found } }
            }
        } else if state == .cold, let wv = webView {
            if let sessionImage { wv.interactionState = sessionImage }
            loadCurrent(into: wv)
        }
        if let wv = webView, wv.superview == nil {
            wv.frame = container.bounds
            wv.autoresizingMask = [.width, .height]
            container.addSubview(wv)
        }
        if #available(macOS 12.0, *) { webView?.setAllMediaPlaybackSuspended(false) }
        state = .live
        host = container
    }

    private func makeWarm() {
        guard let wv = webView else { state = .warm; return }
        if let bytes = pid.flatMap({ MemoryProbe.footprint(pid: $0) }), bytes > 0 {
            measuredLiveBytes = bytes
        }
        captureSnapshot(from: wv)
        wv.removeFromSuperview()
        if #available(macOS 12.0, *) { wv.setAllMediaPlaybackSuspended(true) }
        // Everything a host app can do to quiesce a page short of destroying it.
        wv.evaluateJavaScript(
            "for (let i = 1; i < 99999; i++) { clearInterval(i); clearTimeout(i); }",
            completionHandler: nil)
        state = .warm
    }

    private func makeCold() {
        guard let wv = webView else { state = .cold; return }
        sessionImage = wv.interactionState as? Data
        // Navigating away beats destroying the view: measured 39 MB vs 59 MB, because
        // WebKit's process cache keeps the process either way and a blank page is the
        // cheapest thing it can be holding.
        wv.load(URLRequest(url: URL(string: "about:blank")!))
        state = .cold
    }

    private func makeStub() {
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
        pid = nil
        state = .stub
    }

    /// file:// needs loadFileURL with explicit read access; plain load() is blocked.
    private func loadCurrent(into wv: WKWebView) {
        if NewTabPage.isNewTab(url) {
            // Loaded as a string so the document has no URL of its own; the address bar
            // stays empty and the <title> supplies the tab name.
            wv.loadHTMLString(NewTabPage.html, baseURL: nil)
        } else if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    /// Reload if the refresh interval has elapsed. Returns true if it fired.
    @discardableResult
    func refreshIfDue(now: Date = Date()) -> Bool {
        guard let interval = refreshInterval, state == .live, let wv = webView,
              now.timeIntervalSince(lastRefresh) >= interval else { return false }
        lastRefresh = now
        wv.reload()
        return true
    }

    func toggleDarkMode(_ done: ((Bool) -> Void)? = nil) {
        darkMode.toggle()
        // Prefers the real Dark Reader library when it is installed; falls back to the
        // built-in filter mode otherwise.
        webView?.evaluateJavaScript(DarkReaderBridge.effectiveToggleJS()) { result, _ in
            done?(result as? Bool ?? self.darkMode)
        }
    }

    private func captureSnapshot(from wv: WKWebView) {
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 320
        wv.takeSnapshot(with: cfg) { [weak self] image, _ in
            if let image { self?.snapshot = image }
        }
    }
}
