import AppKit
import WebKit

/// A `WKWebView` that adds Kestrel's own items to the page context menu.
///
/// macOS `WKWebView` has no delegate hook for this — the iOS
/// `contextMenuConfigurationForElement` family does not exist here — but the menu is an
/// ordinary `NSMenu` and `willOpenMenu(_:with:)` is called before it appears. Subclassing
/// is the documented seam.
final class PageWebView: WKWebView {

    /// Called with the element path recorded by `contextTargetScript` when Inspect is
    /// chosen. The path is captured by the page itself on `contextmenu`, because by the
    /// time the menu item fires, the cursor may be anywhere.
    var onInspect: ((String?) -> Void)?
    var onViewSource: (() -> Void)?

    /// Records what was right-clicked. WebKit's own menu knows the element; the app does
    /// not, so the page keeps a note of it.
    static func contextTargetScript() -> WKUserScript {
        let js = """
        (function () {
          if (window.__kestrelCtx) return;
          window.__kestrelCtx = true;
          function pathOf(el) {
            var parts = [];
            while (el && el.nodeType === 1 && parts.length < 40) {
              var seg = el.tagName.toLowerCase();
              if (el.id) { parts.unshift(seg + '#' + el.id); break; }
              var parent = el.parentNode;
              if (parent) {
                var same = [];
                for (var i = 0; i < parent.children.length; i++) {
                  if (parent.children[i].tagName === el.tagName) same.push(parent.children[i]);
                }
                if (same.length > 1) seg += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
              }
              parts.unshift(seg);
              el = el.parentElement;
            }
            return parts.join(' > ');
          }
          document.addEventListener('contextmenu', function (e) {
            window.__kestrelInspectTarget = pathOf(e.target);
          }, true);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // WebKit's default menu already carries Back/Forward/Reload and the like. These go
        // at the end, where a browser puts them.
        menu.addItem(.separator())

        let source = NSMenuItem(title: "View Page Source", action: #selector(viewSource(_:)),
                                keyEquivalent: "")
        source.target = self
        menu.addItem(source)

        let inspect = NSMenuItem(title: "Inspect", action: #selector(inspect(_:)),
                                 keyEquivalent: "")
        inspect.target = self
        menu.addItem(inspect)
    }

    @objc private func inspect(_ sender: Any?) {
        evaluateJavaScript("window.__kestrelInspectTarget || ''") { [weak self] v, _ in
            let path = (v as? String).flatMap { $0.isEmpty ? nil : $0 }
            self?.onInspect?(path)
        }
    }

    @objc private func viewSource(_ sender: Any?) { onViewSource?() }
}
