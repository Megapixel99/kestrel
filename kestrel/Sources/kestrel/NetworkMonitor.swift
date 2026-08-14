import AppKit
import WebKit

/// A network panel for a browser whose engine will not give it one.
///
/// WKWebView exposes no request observer — there is no `WKURLSchemeHandler` for ordinary
/// http(s), no equivalent of Chrome's `Network.requestWillBeSent`. So this is assembled
/// from the three sources that *are* available, and the panel says which one each row came
/// from rather than pretending they are equivalent:
///
/// - **`PerformanceObserver`** for `resource` entries: every subresource the engine
///   fetched — scripts, stylesheets, images, fonts — with transfer size, decoded size,
///   duration and initiator type. No headers: the page never sees them.
/// - **`fetch` and `XMLHttpRequest` wrappers**: full detail for anything the page requested
///   itself, including request and response headers, method, status and body size. This is
///   where the interesting traffic is — the XHR/fetch calls an app makes.
/// - **The navigation delegate**: real `HTTPURLResponse` headers for the main frame, from
///   `decidePolicyFor navigationResponse`, which is the one place WebKit hands over a
///   genuine response object.
///
/// What that means honestly: an image's headers are not observable, and neither is a
/// request the engine made before the wrapper installed. Both are marked in the source
/// column rather than left to look like missing data.
enum NetworkMonitor {

    static let messageName = "kestrelNetwork"

    struct Entry: Identifiable {
        let id = UUID()
        var started: Date
        var method: String
        var url: URL
        var status: Int?          // nil while pending, or when unobservable
        var type: String          // script, css, img, fetch, xhr, document…
        var transferred: Int      // bytes on the wire, 0 when unknown
        var size: Int             // decoded size
        var durationMs: Double
        var initiator: String
        var source: Source
        var requestHeaders: [String: String] = [:]
        var responseHeaders: [String: String] = [:]

        enum Source: String { case performance = "timing", script = "fetch/xhr", navigation = "document" }

        var host: String { url.host ?? "" }
        var file: String {
            let last = url.lastPathComponent
            let name = last.isEmpty || last == "/" ? "/" : last
            return url.query.map { _ in name + "?…" } ?? name
        }
    }

    /// Ring buffer. A busy page can issue hundreds of requests — the screenshot that
    /// prompted this had 244 — and an unbounded log in a memory-budget browser would be
    /// its own joke.
    private(set) static var entries: [Entry] = []
    static var limit = 500
    static var isRecording = true
    static var onChange: (() -> Void)?

    static func record(_ e: Entry) {
        guard isRecording else { return }
        entries.append(e)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        onChange?()
    }

    static func clear() {
        entries.removeAll()
        onChange?()
    }

    static var totals: (count: Int, transferred: Int, size: Int) {
        entries.reduce(into: (0, 0, 0)) { acc, e in
            acc.0 += 1; acc.1 += e.transferred; acc.2 += e.size
        }
    }

    /// Whether pages should be instrumented at all.
    ///
    /// Wrapping `fetch` and `XMLHttpRequest` and observing every resource costs the page
    /// about 40% more per request — measured, 300 requests — and every observed resource
    /// becomes an IPC message to the browser. Paying that on every page when nobody has
    /// the panel open is the same mistake as the memory probe in DEBUGGING.md §2: a
    /// diagnostic charging its cost to the thing being diagnosed.
    ///
    /// The script is still injected everywhere, because a web view's user scripts are
    /// fixed at creation, but it does nothing until installed.
    private(set) static var isCapturing = false

    /// Turns capture on or off. Live tabs are told immediately; tabs created later read
    /// the flag when their script runs.
    @MainActor
    static func setCapturing(_ on: Bool, tabs: [Tab]) {
        isCapturing = on
        for tab in tabs {
            tab.webView?.evaluateJavaScript(
                on ? "window.__kestrelNetInstall && window.__kestrelNetInstall()"
                   : "window.__kestrelNetOn = false")
        }
    }

    /// Installed at document start in every tab.
    static func captureScript() -> WKUserScript {
        let js = """
        (function () {
          if (window.__kestrelNetInstall) return;
          var post = function (o) {
            if (!window.__kestrelNetOn) return;
            try { window.webkit.messageHandlers.\(messageName).postMessage(o); } catch (e) {}
          };

          // Nothing is wrapped and no observer exists until this runs.
          window.__kestrelNetInstall = function () {
            if (window.__kestrelNetOn) return;
            window.__kestrelNetOn = true;
            install();
          };

          function install() {

          // --- everything the engine fetched, with timing but no headers ---
          try {
            var seen = 0;
            var obs = new PerformanceObserver(function (list) {
              var items = list.getEntries();
              for (var i = 0; i < items.length; i++) {
                var r = items[i];
                if (++seen > 800) return;
                post({
                  kind: 'timing',
                  url: r.name,
                  type: r.initiatorType || 'other',
                  transferred: r.transferSize || 0,
                  size: r.decodedBodySize || 0,
                  duration: r.duration || 0
                });
              }
            });
            obs.observe({ type: 'resource', buffered: true });
          } catch (e) {}

          // --- what the page asked for itself, with headers ---
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function (input, init) {
              var url = (typeof input === 'string') ? input
                      : (input && input.url) || String(input);
              var method = (init && init.method)
                        || (input && input.method) || 'GET';
              var reqHeaders = {};
              try {
                var h = (init && init.headers) || (input && input.headers);
                if (h) {
                  if (typeof h.forEach === 'function') {
                    h.forEach(function (v, k) { reqHeaders[k] = v; });
                  } else {
                    Object.keys(h).forEach(function (k) { reqHeaders[k] = h[k]; });
                  }
                }
              } catch (e) {}
              var t0 = performance.now();
              return origFetch.apply(this, arguments).then(function (res) {
                var resHeaders = {};
                try { res.headers.forEach(function (v, k) { resHeaders[k] = v; }); } catch (e) {}
                post({
                  kind: 'script', sub: 'fetch', url: String(url), method: method,
                  status: res.status, duration: performance.now() - t0,
                  requestHeaders: reqHeaders, responseHeaders: resHeaders
                });
                return res;
              }, function (err) {
                post({
                  kind: 'script', sub: 'fetch', url: String(url), method: method,
                  status: 0, duration: performance.now() - t0,
                  requestHeaders: reqHeaders, responseHeaders: {}
                });
                throw err;
              });
            };
          }

          var XHR = window.XMLHttpRequest;
          if (XHR && XHR.prototype) {
            var open = XHR.prototype.open, send = XHR.prototype.send,
                setH = XHR.prototype.setRequestHeader;
            XHR.prototype.open = function (m, u) {
              this.__k = { method: m, url: u, headers: {} };
              return open.apply(this, arguments);
            };
            XHR.prototype.setRequestHeader = function (k, v) {
              if (this.__k) this.__k.headers[k] = v;
              return setH.apply(this, arguments);
            };
            XHR.prototype.send = function (body) {
              var self = this, t0 = performance.now();
              if (this.__k && body && typeof body === 'string') {
                this.__k.headers['Content-Length'] = String(body.length);
              }
              this.addEventListener('loadend', function () {
                if (!self.__k) return;
                var resHeaders = {};
                try {
                  var raw = self.getAllResponseHeaders() || '';
                  raw.trim().split(/[\\r\\n]+/).forEach(function (line) {
                    var i = line.indexOf(':');
                    if (i > 0) resHeaders[line.slice(0, i).trim()] = line.slice(i + 1).trim();
                  });
                } catch (e) {}
                post({
                  kind: 'script', sub: 'xhr', url: String(self.__k.url),
                  method: self.__k.method, status: self.status,
                  duration: performance.now() - t0,
                  size: (self.responseText || '').length,
                  requestHeaders: self.__k.headers, responseHeaders: resHeaders
                });
              });
              return send.apply(this, arguments);
            };
          }
          }

          if (\(isCapturing ? "true" : "false")) window.__kestrelNetInstall();
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    /// Turns one posted message into an entry.
    static func ingest(_ body: Any, pageURL: URL?) {
        guard let d = body as? [String: Any],
              let raw = d["url"] as? String,
              let url = URL(string: raw, relativeTo: pageURL)?.absoluteURL
        else { return }
        let kind = d["kind"] as? String ?? "timing"

        var e = Entry(started: Date(),
                      method: (d["method"] as? String ?? "GET").uppercased(),
                      url: url,
                      status: (d["status"] as? Int).flatMap { $0 == 0 ? nil : $0 },
                      type: d["sub"] as? String ?? d["type"] as? String ?? "other",
                      transferred: Int(d["transferred"] as? Double ?? 0),
                      size: Int(d["size"] as? Double ?? 0),
                      durationMs: d["duration"] as? Double ?? 0,
                      initiator: pageURL?.host ?? "",
                      source: kind == "script" ? .script : .performance)
        e.requestHeaders = (d["requestHeaders"] as? [String: String]) ?? [:]
        e.responseHeaders = (d["responseHeaders"] as? [String: String]) ?? [:]
        record(e)
    }

    /// The main-frame response, which is the only place real headers are available
    /// without the page's cooperation.
    static func recordNavigation(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse, let url = http.url else { return }
        var e = Entry(started: Date(), method: "GET", url: url,
                      status: http.statusCode, type: "document",
                      transferred: Int(max(0, http.expectedContentLength)),
                      size: Int(max(0, http.expectedContentLength)),
                      durationMs: 0, initiator: url.host ?? "", source: .navigation)
        for (k, v) in http.allHeaderFields {
            e.responseHeaders["\(k)"] = "\(v)"
        }
        record(e)
    }
}
