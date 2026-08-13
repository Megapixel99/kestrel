import AppKit
import WebKit

/// Kestrel's tabs and window, described to WebKit's extension runtime.
///
/// `browser.tabs.query()` returns whatever these methods say, so this file is where the
/// tab ladder meets the extension API — and the two do not agree by default. A WARM or
/// COLD tab is a real tab with a real URL and title, but it has no web view, and there is
/// no honest way to give an extension one without undoing the parking that is the whole
/// point of this browser. So parked tabs are reported, with their metadata, and
/// `webView(for:)` returns nil for them; anything that needs to touch the page — inject a
/// script, read the DOM — waits until the tab is live again. See DEBUGGING.md §9.

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func url(for context: WKWebExtensionContext) -> URL? {
        NewTabPage.isNewTab(url) ? nil : url
    }

    func title(for context: WKWebExtensionContext) -> String? { title }

    func isPinned(for context: WKWebExtensionContext) -> Bool { pinned }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { audible }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        webView?.isLoading == false
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        ExtensionRuntime.shared.browser?.foregroundId == id
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionRuntime.shared.browser
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        ExtensionRuntime.shared.browser?.tabs.firstIndex { $0.id == id } ?? 0
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(webView?.pageZoom ?? 1)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    /// A parked tab asked to navigate is brought back first. This is the one place an
    /// extension can force a promotion, and it is the right one: `tabs.update({url})` is
    /// a deliberate act, not a background poll.
    func loadURL(_ newURL: URL, for context: WKWebExtensionContext,
                 completionHandler: @escaping ((any Error)?) -> Void) {
        url = newURL
        if let wv = webView {
            wv.load(URLRequest(url: newURL))
        } else if let browser = ExtensionRuntime.shared.browser {
            browser.select(self)
        }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext,
                completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        ExtensionRuntime.shared.browser?.select(self)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext,
               completionHandler: @escaping ((any Error)?) -> Void) {
        ExtensionRuntime.shared.browser?.closeTab(id: id)
        completionHandler(nil)
    }

    func setPinned(_ isPinned: Bool, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any Error)?) -> Void) {
        pinned = isPinned
        ExtensionRuntime.shared.browser?.refreshTabStrip()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension BrowserWindowController: WKWebExtensionWindow {

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        currentTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { window.frame }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window.screen?.frame ?? .zero
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext,
                  completionHandler: @escaping ((any Error)?) -> Void) {
        window.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext,
               completionHandler: @escaping ((any Error)?) -> Void) {
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}
