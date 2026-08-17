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

    /// Whether `cachedBytes` means anything.
    ///
    /// A tab whose content process cannot be identified reported **0 MB**, which is
    /// indistinguishable from a tab that genuinely costs nothing — and the budget
    /// counted it as free. It took a screen recording to notice a Jira board reading zero.
    /// Unknown and zero are different facts and the UI now says which it has.
    var footprintKnown = true
    var sessionImage: Data?          // WKWebView.interactionState -- the COLD image
    var snapshot: NSImage?

    var lastUsed = Date()
    var uses = 0
    var pinned = false
    var audible = false
    /// Set from the page's own report. The scheduler's "unsubmitted input" demotion
    /// floor reads this, and until SessionStore started filling it in, nothing did.
    var hasUnsubmittedInput = false

    /// Scroll position and form contents, captured continuously so a tab parked at any
    /// moment restores to where it was rather than to the top of a blank form.
    var pageState = SessionStore.PageState()

    /// Message handlers are per web view and adding a duplicate name traps, so a tab
    /// remembers whether it has been wired. Reset when the view is rebuilt.
    var handlersAttached = false

    /// Whether kestrel://memory's document has been loaded into this tab yet. After that
    /// the numbers are updated in place rather than by reloading the page.
    var memoryShellLoaded = false

    /// True from the moment a load starts on a tab that has captured state until that
    /// state has been put back. A freshly loaded page reports empty fields, and without
    /// this the report arrives first and wipes exactly what is about to be restored.
    var restorePending = false

    /// Reader view. `readerAvailable` is set from the page on load, so the toolbar button
    /// only appears where the extraction would actually produce an article.
    var readerAvailable = false
    var readerActive = false
    /// The page to return to when reader view is turned off.
    var preReaderURL: URL?

    /// The container this tab belongs to, or nil for the default jar. Fixed at creation:
    /// moving a live tab between cookie jars is not something WebKit supports.
    var container: Container?

    /// Auto-refresh interval in seconds, nil = off. A tab on a refresh timer is a live
    /// dashboard: demoting it defeats the point, so it gets a LIVE floor in the
    /// Seeded from the saved preference so a new tab opens dark when that is the default.

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
    ///
    /// Refreshes the process id from the web view first. Without this a tab whose pid was
    /// never established, or was established for a process WebKit has since swapped,
    /// measures 0 — and the benchmark's per-tab total silently loses a whole page. Main
    /// thread only: it touches the web view.
    @discardableResult
    func measureNow() -> Int64 {
        if let wv = webView, let direct = MemoryProbe.privateProcessIdentifier(of: wv) {
            if pid != direct { pid = direct }
            footprintKnown = true
        }
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
            // An add-on's own page is an add-on page: it gets the same Firefox token the
            // popup and background get. Handing it the Safari token — which this did —
            // means one add-on sees two different browsers depending on which of its own
            // pages is asking.
            cfg.applicationNameForUserAgent = UserAgent.extensionApplicationName
            // A container tab gets its own cookie jar, cache and storage. This is WebKit's
            // own partition boundary, not a cosmetic one.
            // `container` is also the name of this function's NSView parameter, so the
            // tab's own property is spelled out.
            if #available(macOS 14.0, *), let jar = self.container {
                cfg.websiteDataStore = MainActor.assumeIsolated {
                    ContainerStore.store(for: jar)
                }
            }
            cfg.userContentController.addUserScript(SessionStore.captureScript())
            cfg.userContentController.addUserScript(PageWebView.contextTargetScript())
            cfg.userContentController.addUserScript(NetworkMonitor.captureScript())
            // PageWebView, like any other tab: an add-on's own page should have the same
            // right-click Inspect as a web page.
            let wv = PageWebView(frame: container.bounds, configuration: cfg)
            wv.autoresizingMask = [.width, .height]
            // The whole UA string, not an appended token — see UserAgent.firefoxFull.
            // `applicationNameForUserAgent` can only append to WebKit's prefix, so the page
            // ends up claiming to be AppleWebKit *and* Gecko, which Adblock Plus reads as
            // an unsupported browser and refuses to render for.
            wv.customUserAgent = UserAgent.firefoxFull
            webView = wv
            container.addSubview(wv)
            loadCurrent(into: wv)
        } else if webView == nil {
            let before = Tab.lastKnownPids
            let cfg = WKWebViewConfiguration()
            cfg.processPool = WKProcessPool()
            // WKWebView's stock UA stops after "(KHTML, like Gecko)" — no product
            // token at all — so sniffers cannot identify it and sites like Google Meet
            // refuse outright. Appending the Safari token completes it, which is
            // accurate: this really is WebKit.
            cfg.applicationNameForUserAgent = UserAgent.applicationName
            // A container tab gets its own cookie jar, cache and storage. This is WebKit's
            // own partition boundary, not a cosmetic one.
            // `container` is also the name of this function's NSView parameter, so the
            // tab's own property is spelled out.
            if #available(macOS 14.0, *), let jar = self.container {
                cfg.websiteDataStore = MainActor.assumeIsolated {
                    ContainerStore.store(for: jar)
                }
            }
            cfg.userContentController.addUserScript(SessionStore.captureScript())
            cfg.userContentController.addUserScript(PageWebView.contextTargetScript())
            cfg.userContentController.addUserScript(NetworkMonitor.captureScript())
            // Extensions attach per configuration, so a tab restored from COLD comes
            // back with the same add-ons the rest of the window has.
            if #available(macOS 15.4, *) {
                MainActor.assumeIsolated {
                    ExtensionRuntime.apply(to: cfg)
                    ExtensionWeb.attach(to: cfg)
                }
            }
            let wv = PageWebView(frame: container.bounds, configuration: cfg)
            wv.autoresizingMask = [.width, .height]
            webView = wv
            handlersAttached = false
            memoryShellLoaded = false
            container.addSubview(wv)
            if let sessionImage { wv.interactionState = sessionImage }
            loadCurrent(into: wv)
            // Identify the new WebContent process so we can measure this tab. Both the
            // `ps` call and the diff run off the main thread; only the assignment
            // hops back.
            // Ask the web view directly first. The pid-diffing below is the fallback for
            // when that private property is unavailable — it picks arbitrarily among
            // however many processes WebKit spawned at once, which is how a tab ends up
            // reporting another page's memory.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let wv = self.webView else { return }
                if let direct = MemoryProbe.privateProcessIdentifier(of: wv) {
                    self.pid = direct
                    self.footprintKnown = true
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
                let after = Set(MemoryProbe.webContentPids())
                Tab.lastKnownPids = after
                let found = after.subtracting(before).first
                    DispatchQueue.main.async {
                    guard let self else { return }
                    // A pid the web view gave us outranks anything inferred from ps.
                    if let wv = self.webView,
                       let direct = MemoryProbe.privateProcessIdentifier(of: wv) {
                        self.pid = direct
                        self.footprintKnown = true
                    } else if let found {
                        self.pid = found
                        self.footprintKnown = true
                    } else {
                        self.footprintKnown = false
                    }
                }
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
        if AboutMemory.isMemoryPage(url) {
            // A placeholder; the controller renders the real thing on its next tick,
            // because the numbers belong to the scheduler, not to a tab.
            wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
        } else if NewTabPage.isNewTab(url) {
            // Loaded as a string so the document has no URL of its own; the address bar
            // stays empty and the <title> supplies the tab name.
            wv.loadHTMLString(NewTabPage.html, baseURL: nil)
        } else if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
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
