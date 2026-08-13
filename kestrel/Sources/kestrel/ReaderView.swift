import AppKit
import WebKit

/// Reader view: the article, without the rest of the page.
///
/// Firefox documents Reader Mode as a front-end component and Kestrel already claimed it
/// existed — `WKWebExtensionTab` has `isReaderModeAvailable` and `isReaderModeActive`, and
/// both returned false unconditionally, so an add-on asking was told no every time.
///
/// It also earns its place in *this* browser rather than merely being a nice feature. A
/// reader-mode document is a fraction of the original: no ad frames, no analytics, no
/// layout scripts, no web fonts, no images beyond the article's own. That is a page the
/// scheduler can hold LIVE for a fraction of what the real one costs, which makes it the
/// only feature here that reduces a tab's footprint without demoting it. `readertest`
/// measures the difference rather than assuming it.
enum ReaderView {

    /// Extracts the article. A readability pass, deliberately small: score blocks by text
    /// density and link ratio, take the winner, keep its paragraphs.
    ///
    /// Not Mozilla's Readability.js — that is 2,000 lines and a dependency. This handles
    /// article-shaped pages, and `isAvailable` is honest about when it has not found one,
    /// so the button does not appear on a page it would ruin.
    static let extractScript = """
    (function () {
      function textLength(el) { return (el.innerText || '').trim().length; }
      function linkDensity(el) {
        var t = textLength(el);
        if (!t) return 1;
        var links = el.querySelectorAll('a');
        var lt = 0;
        for (var i = 0; i < links.length; i++) lt += (links[i].innerText || '').length;
        return lt / t;
      }

      // An explicit <article> wins; otherwise score every plausible container.
      var best = document.querySelector('article');
      var bestScore = best ? textLength(best) : 0;
      if (!best || bestScore < 400) {
        var candidates = document.querySelectorAll(
          'article, main, [role="main"], div, section');
        for (var i = 0; i < candidates.length; i++) {
          var el = candidates[i];
          var t = textLength(el);
          if (t < 400) continue;
          // Paragraph count matters: a nav column can be long without being prose.
          var paras = el.querySelectorAll('p').length;
          if (paras < 2) continue;
          var score = t * (1 - linkDensity(el)) + paras * 40;
          if (score > bestScore) { bestScore = score; best = el; }
        }
      }
      if (!best || textLength(best) < 400) return null;

      var clone = best.cloneNode(true);
      var strip = clone.querySelectorAll(
        'script, style, noscript, iframe, form, button, input, select, textarea, ' +
        'nav, aside, footer, [aria-hidden="true"], .ad, .ads, [class*="share"], ' +
        '[class*="related"], [class*="newsletter"], [id*="comment"]');
      for (var j = 0; j < strip.length; j++) strip[j].remove();

      // Images keep only what a reader needs; everything else that could load is gone.
      var imgs = clone.querySelectorAll('img');
      for (var k = 0; k < imgs.length; k++) {
        var im = imgs[k];
        var src = im.getAttribute('src') || im.getAttribute('data-src') || '';
        if (!src) { im.remove(); continue; }
        im.removeAttribute('srcset');
        im.removeAttribute('loading');
        im.setAttribute('src', new URL(src, location.href).href);
      }
      var all = clone.querySelectorAll('*');
      for (var m = 0; m < all.length; m++) {
        all[m].removeAttribute('style');
        all[m].removeAttribute('class');
        all[m].removeAttribute('onclick');
      }

      var title = (document.querySelector('h1') || {}).innerText || document.title || '';
      var byline = '';
      var b = document.querySelector('[rel="author"], .byline, [class*="author"]');
      if (b) byline = (b.innerText || '').trim().slice(0, 120);

      return JSON.stringify({
        title: title.trim(),
        byline: byline,
        words: (clone.innerText || '').trim().split(/\\s+/).length,
        html: clone.innerHTML
      });
    })();
    """

    /// Whether this page looks like an article. Cheap enough to run on every load.
    static let availabilityScript = """
    (function () {
      var a = document.querySelector('article');
      if (a && (a.innerText || '').trim().length > 600) return true;
      var ps = document.querySelectorAll('p'), total = 0;
      for (var i = 0; i < ps.length; i++) total += (ps[i].innerText || '').length;
      return ps.length >= 4 && total > 1200;
    })();
    """

    struct Article: Decodable {
        let title: String
        let byline: String
        let words: Int
        let html: String
    }

    static func parse(_ raw: Any?) -> Article? {
        guard let s = raw as? String, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Article.self, from: d)
    }

    /// The reader document. Self-contained: no external CSS, no scripts, no web fonts.
    static func page(_ article: Article, url: URL) -> String {
        let minutes = max(1, article.words / 220)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <title>\(escape(article.title))</title>
        <style>
          :root { color-scheme: light dark; }
          body { max-width: 42em; margin: 0 auto; padding: 56px 24px 96px;
                 font: 19px/1.65 -apple-system, Georgia, serif; }
          h1 { font-size: 30px; line-height: 1.2; margin: 0 0 8px; }
          .meta { font-size: 13px; opacity: .6; margin-bottom: 36px;
                  font-family: -apple-system, system-ui, sans-serif; }
          .meta a { color: inherit; }
          img { max-width: 100%; height: auto; display: block; margin: 24px auto; }
          p { margin: 0 0 1.1em; }
          pre, code { font-family: ui-monospace, monospace; font-size: .85em; }
          pre { overflow-x: auto; padding: 12px;
                background: color-mix(in srgb, currentColor 8%, transparent); }
          blockquote { margin: 1.2em 0; padding-left: 1em;
                       border-left: 3px solid color-mix(in srgb, currentColor 25%, transparent);
                       opacity: .85; }
          h2, h3 { line-height: 1.25; margin: 1.6em 0 .5em; }
        </style></head><body>
          <h1>\(escape(article.title))</h1>
          <div class="meta">
            \(article.byline.isEmpty ? "" : escape(article.byline) + " · ")
            \(article.words) words · \(minutes) min ·
            <a href="\(escape(url.absoluteString))">\(escape(url.host ?? ""))</a>
          </div>
          \(article.html)
        </body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
