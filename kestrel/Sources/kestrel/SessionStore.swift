import AppKit
import WebKit

/// Session restore with enough fidelity to be worth having.
///
/// Firefox's SessionStore keeps scroll position, form contents and per-tab history, writes
/// periodically rather than only at quit, and can tell a crash from a clean exit. Kestrel
/// saved a URL, a title and `interactionState` — which covers back/forward history and
/// scroll for a *live* tab, and nothing at all for a tab the scheduler parked before the
/// browser closed.
///
/// That gap is not incidental here. This browser's entire argument is that a parked tab
/// comes back indistinguishable from a live one, so the state a parked tab loses is the
/// claim failing. Two things were missing:
///
/// - **Form contents.** `interactionState` does not carry them. A tab demoted to COLD with
///   half a form filled in lost it, silently.
/// - **`hasUnsubmittedInput`.** The scheduler has a demotion floor that keeps a tab with
///   unsubmitted input from going below COLD — and nothing ever set the flag. The floor
///   has been dead code since it was written.
enum SessionStore {

    static let messageName = "kestrelSession"

    /// Captured from the page and re-applied on restore.
    struct PageState: Codable {
        var scrollX: Double = 0
        var scrollY: Double = 0
        /// Keyed by a stable-ish selector; `values` is deliberately not persisted for
        /// password fields — see `captureScript`.
        var values: [String: String] = [:]
        var hasInput: Bool { !values.isEmpty }
    }

    /// Runs in every page. Reports scroll and form contents on change, debounced, and once
    /// more on `pagehide` so a tab closed or parked mid-edit still reports.
    ///
    /// Password fields and anything marked `autocomplete="off"` are skipped: session state
    /// is written to disk in the clear, and a restored password field is not worth that.
    static func captureScript() -> WKUserScript {
        let js = """
        (function () {
          if (window.__kestrelSession) return;
          window.__kestrelSession = true;
          var timer = null;
          var scrollTimer = null;

          function selectorFor(el, i) {
            if (el.id) return '#' + el.id;
            if (el.name) return (el.tagName || 'input').toLowerCase() + '[name="' + el.name + '"]';
            return 'idx:' + i;
          }

          function collect() {
            var values = {};
            var fields = document.querySelectorAll('input, textarea, select');
            for (var i = 0; i < fields.length; i++) {
              var el = fields[i];
              var type = (el.type || '').toLowerCase();
              if (type === 'password' || type === 'hidden' || type === 'file') continue;
              if ((el.getAttribute('autocomplete') || '').toLowerCase() === 'off') continue;
              var v;
              if (type === 'checkbox' || type === 'radio') {
                v = el.checked ? 'on' : '';
              } else {
                v = el.value;
              }
              if (v === undefined || v === null || v === '') continue;
              if (String(v).length > 4096) continue;
              values[selectorFor(el, i)] = String(v);
            }
            return {
              scrollX: window.scrollX || 0,
              scrollY: window.scrollY || 0,
              values: values
            };
          }

          function send() {
            try {
              window.webkit.messageHandlers.\(messageName).postMessage(collect());
            } catch (e) {}
          }

          // Scrolling cannot change a form value, so it sends the position and nothing
          // else. Sharing the debounced path meant every scroll shipped every field's
          // contents over IPC — 400 values on a form-heavy page, to report a number.
          function sendScroll() {
            try {
              window.webkit.messageHandlers.\(messageName).postMessage({
                kind: 'scroll',
                scrollX: window.scrollX || 0,
                scrollY: window.scrollY || 0
              });
            } catch (e) {}
          }

          function schedule() {
            if (timer) clearTimeout(timer);
            timer = setTimeout(send, 400);
          }

          function scheduleScroll() {
            if (scrollTimer) clearTimeout(scrollTimer);
            scrollTimer = setTimeout(sendScroll, 400);
          }

          document.addEventListener('input', schedule, true);
          document.addEventListener('change', schedule, true);
          window.addEventListener('scroll', scheduleScroll, { passive: true });
          // A submitted form is no longer unsubmitted input; clearing here is what stops
          // the scheduler pinning a tab to COLD forever after one search.
          window.addEventListener('submit', function () {
            setTimeout(function () {
              try {
                window.webkit.messageHandlers.\(messageName).postMessage(
                  { scrollX: 0, scrollY: 0, values: {} });
              } catch (e) {}
            }, 0);
          }, true);
          window.addEventListener('pagehide', send);
          setTimeout(send, 800);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Re-applies a captured state. Runs after a restored page finishes loading.
    static func restoreScript(_ state: PageState) -> String {
        let json = (try? JSONEncoder().encode(state.values))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function () {
          var values = \(json);
          var fields = document.querySelectorAll('input, textarea, select');
          for (var i = 0; i < fields.length; i++) {
            var el = fields[i];
            var key = el.id ? '#' + el.id
                    : el.name ? (el.tagName || 'input').toLowerCase() + '[name="' + el.name + '"]'
                    : 'idx:' + i;
            if (!(key in values)) continue;
            var type = (el.type || '').toLowerCase();
            if (type === 'checkbox' || type === 'radio') {
              el.checked = values[key] === 'on';
            } else {
              el.value = values[key];
            }
            el.dispatchEvent(new Event('input', { bubbles: true }));
          }
          window.scrollTo(\(Int(state.scrollX)), \(Int(state.scrollY)));
          return Object.keys(values).length;
        })();
        """
    }

    // MARK: - crash detection

    /// A file that exists only while the browser is running. Firefox does the same thing:
    /// if it is still there at startup, the last run did not exit cleanly.
    private static var runningFlag: URL {
        Store.dir.appendingPathComponent("running.flag")
    }

    static func markRunning() {
        try? Data("\(getpid())".utf8).write(to: runningFlag)
    }

    static func markCleanExit() {
        try? FileManager.default.removeItem(at: runningFlag)
    }

    /// True when the previous run left its flag behind, i.e. crashed or was killed.
    static func lastRunCrashed() -> Bool {
        FileManager.default.fileExists(atPath: runningFlag.path)
    }
}

/// Routes a page's reports to the tab that sent them.
///
/// One object per tab per channel: `WKScriptMessage` identifies the web view but not which
/// of our tabs it belongs to, and searching the tab list on every message — a busy page
/// sends hundreds — is work worth avoiding.
final class PageMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var browser: BrowserWindowController?
    private weak var tab: Tab?

    init(browser: BrowserWindowController?, tab: Tab?) {
        self.browser = browser
        self.tab = tab
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let tab else { return }
        switch message.name {
        case SessionStore.messageName:
            guard let d = message.body as? [String: Any] else { return }
            // A scroll report carries only a position; it must not wipe the values.
            if (d["kind"] as? String) == "scroll" {
                tab.pageState.scrollX = d["scrollX"] as? Double ?? tab.pageState.scrollX
                tab.pageState.scrollY = d["scrollY"] as? Double ?? tab.pageState.scrollY
                return
            }
            var state = SessionStore.PageState()
            state.scrollX = d["scrollX"] as? Double ?? 0
            state.scrollY = d["scrollY"] as? Double ?? 0
            state.values = (d["values"] as? [String: String]) ?? [:]
            // An empty report from a page that has not been restored yet is the blank
            // form, not the user clearing it.
            if tab.restorePending && !state.hasInput { return }
            tab.pageState = state
            // The scheduler's demotion floor reads this. A tab with something typed into
            // it will not be pushed below COLD, which is where the typing survives.
            tab.hasUnsubmittedInput = state.hasInput
        case NetworkMonitor.messageName:
            NetworkMonitor.ingest(message.body, pageURL: tab.url)
        default: break
        }
    }
}
