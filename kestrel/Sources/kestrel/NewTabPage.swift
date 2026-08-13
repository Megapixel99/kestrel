import Foundation

/// The new-tab page, served from a data URL so it needs no bundled resources.
///
/// Deliberately plain: a search field and the browser's own memory story, rather than a
/// content feed. A new tab that loads a page of tiles and telemetry is a strange thing
/// to ship in a browser whose entire argument is that tabs should be cheap.
enum NewTabPage {
    static let searchEngineName = "DuckDuckGo"
    static let searchURL = "https://duckduckgo.com/?q="

    /// A sentinel rather than a `data:` URL. Loading the page as a data URL made the
    /// whole percent-encoded document the tab's identity, so the tab strip and address
    /// bar both showed `data:text/html;charset=utf-8,%3C...`. The page is loaded with
    /// `loadHTMLString` instead, and this URL is only ever an internal marker.
    static let sentinel = URL(string: "kestrel://newtab")!

    static func url() -> URL { sentinel }

    static func isNewTab(_ url: URL?) -> Bool {
        guard let url else { return false }
        // kestrel://memory is ours too but is not the new tab page; matching the whole
        // scheme here would have made about:memory load a blank new tab.
        if AboutMemory.isMemoryPage(url) { return false }
        return url == sentinel || url.scheme == "kestrel"
            || url.absoluteString == "about:blank"
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>New Tab</title><style>
      :root { color-scheme: dark; }
      html,body { height:100%; margin:0; background:#1c1c1e; color:#e6e6e6;
                  font: 14px/1.5 -apple-system, system-ui, sans-serif; }
      .wrap { height:100%; display:flex; flex-direction:column; align-items:center;
              justify-content:center; gap:26px; padding:0 24px; }
      .logo { font-size:34px; font-weight:600; letter-spacing:-0.5px; }
      .logo span { opacity:.45; font-weight:400; }
      form { width:min(680px, 92vw); }
      input { width:100%; box-sizing:border-box; padding:15px 20px; font-size:15px;
              color:#eee; background:#2c2c2e; border:1px solid #3a3a3c;
              border-radius:12px; outline:none; }
      input:focus { border-color:#0a84ff; background:#313135; }
      .hint { font-size:12px; color:#8a8a8e; text-align:center; }
      .facts { display:flex; gap:26px; flex-wrap:wrap; justify-content:center;
               font-size:12px; color:#8a8a8e; max-width:640px; text-align:center; }
      .facts b { color:#c9c9ce; font-weight:600; }
    </style></head><body>
      <div class="wrap">
        <div class="logo">Kestrel<span> — a browser with a memory budget</span></div>
        <form onsubmit="go(event)">
          <input id="q" autofocus placeholder="Search \(searchEngineName) or enter address"
                 autocomplete="off" spellcheck="false">
        </form>
        <div class="hint">Tabs you stop using are frozen, then hibernated — press the tab again and they come back.</div>
        <div class="facts">
          <div><b>LIVE</b> full page</div>
          <div><b>WARM</b> frozen, instant</div>
          <div><b>COLD</b> hibernated, ~82&nbsp;ms</div>
          <div><b>STUB</b> url only</div>
        </div>
      </div>
      <script>
        function go(e) {
          e.preventDefault();
          const v = document.getElementById('q').value.trim();
          if (!v) return;
          const looksLikeUrl = /^[a-z]+:\\/\\//i.test(v) ||
            (/^[^\\s]+\\.[a-z]{2,}(\\/|$)/i.test(v) && !v.includes(' '));
          location.href = looksLikeUrl
            ? (/^[a-z]+:\\/\\//i.test(v) ? v : 'https://' + v)
            : '\(searchURL)' + encodeURIComponent(v);
        }
      </script>
    </body></html>
    """

    /// Shared by the address bar: decide whether typed text is a URL or a search.
    static func resolve(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("://") { return URL(string: t) }
        // A single token containing a dot and no spaces is treated as a host.
        let looksLikeHost = !t.contains(" ") && t.contains(".")
            && t.range(of: #"^[^\s/]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
        if looksLikeHost { return URL(string: "https://" + t) }
        let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
        return URL(string: searchURL + q)
    }
}
