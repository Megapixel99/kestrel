import Foundation
import WebKit

/// Integration with the real Dark Reader library (MIT, https://github.com/darkreader/darkreader).
///
/// Dark Reader publishes a standalone build whose whole purpose is to be dropped into an
/// arbitrary page and driven with `DarkReader.enable()`. That is a far better dark mode
/// than the CSS invert in `DarkMode` — it parses stylesheets and transforms colours
/// individually rather than inverting the whole document, so photos stay photos and brand
/// colours survive.
///
/// Kestrel uses it when present and falls back to the built-in filter mode when not, so
/// the browser has no hard dependency on a vendored blob.
///
///     npm install darkreader
///     cp node_modules/darkreader/darkreader.js ~/.kestrel/darkreader.js
///
enum DarkReaderBridge {

    struct Settings {
        var brightness = Prefs.drBrightness
        var contrast = Prefs.drContrast
        var sepia = Prefs.drSepia
        var grayscale = Prefs.drGrayscale
    }

    /// Turn dark mode off in a page that already has it, and clear the fallback.
    static let disableJS = """
    (function () {
      try { if (typeof DarkReader !== 'undefined') DarkReader.disable(); } catch (e) {}
      window.__kestrelDarkReader = false;
      var s = document.getElementById('__kestrel_dark');
      if (s) s.remove();
      return 'disabled';
    })();
    """

    /// Re-apply the current slider values to an already-dark page.
    static func reapplyJS(_ s: Settings = Settings()) -> String {
        guard isAvailable else { return DarkMode.toggleJS }
        return """
        (function () {
          try {
            if (typeof DarkReader === 'undefined') return 'not-loaded';
            DarkReader.enable({ brightness: \(s.brightness), contrast: \(s.contrast),
                                sepia: \(s.sepia), grayscale: \(s.grayscale) });
            window.__kestrelDarkReader = true;
            return 'applied';
          } catch (e) { return 'error'; }
        })();
        """
    }

    /// Searched in order. `npm install darkreader` puts the build under node_modules,
    /// and it is easy to run that from a different directory than expected, so look in
    /// the obvious places rather than demanding one exact path.
    static var searchPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var candidates = [
            home.appendingPathComponent(".kestrel/darkreader.js"),
            cwd.appendingPathComponent("node_modules/darkreader/darkreader.js"),
        ]
        // Walk up from the working directory: npm may have been run in a parent.
        var dir = cwd
        for _ in 0..<4 {
            dir = dir.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("node_modules/darkreader/darkreader.js"))
        }
        return candidates
    }

    static var libraryURL: URL {
        searchPaths.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? searchPaths[0]
    }

    /// Cached so we read the ~200 KB bundle once rather than per tab.
    private static var cachedSource: String?

    static var isAvailable: Bool {
        if cachedSource != nil { return true }
        guard let src = try? String(contentsOf: libraryURL, encoding: .utf8),
              src.contains("DarkReader") else { return false }
        cachedSource = src
        return true
    }

    static var version: String {
        guard isAvailable, let src = cachedSource else { return "not installed" }
        return "\(src.count / 1024) KB from \(libraryURL.path)"
    }

    /// Injected at document start so the page is never briefly light.
    static func userScript(_ s: Settings = Settings()) -> WKUserScript? {
        guard isAvailable, let lib = cachedSource else { return nil }
        // enable() must run again once the document's own stylesheets exist. Injected
        // at document-start, the first call themes an essentially empty document and
        // every sheet that loads afterwards is missed -- which showed up as a page that
        // was dark but had lost its accent colours and form controls until dark mode
        // was toggled by hand.
        let js = """
        \(lib)
        ;(function () {
          var opts = { brightness: \(s.brightness), contrast: \(s.contrast),
                       sepia: \(s.sepia), grayscale: \(s.grayscale) };
          function apply() {
            try {
              if (typeof DarkReader === 'undefined') return;
              DarkReader.enable(opts);
              window.__kestrelDarkReader = true;
            } catch (e) { /* leave the page light rather than breaking it */ }
          }
          apply();                       // early, so the page never flashes white
          if (document.readyState !== 'complete') {
            document.addEventListener('DOMContentLoaded', apply, { once: true });
            window.addEventListener('load', apply, { once: true });
          }
          // Single-page apps swap stylesheets after load; re-apply once things settle.
          setTimeout(apply, 1200);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// Toggle on an already-loaded page. Loads the library on first use in that page.
    static func toggleJS(_ s: Settings = Settings()) -> String? {
        guard isAvailable, let lib = cachedSource else { return nil }
        return """
        (function () {
          try {
            if (typeof DarkReader === 'undefined') { \(lib) }
            if (window.__kestrelDarkReader) {
              DarkReader.disable();
              window.__kestrelDarkReader = false;
              return false;
            }
            DarkReader.enable({
              brightness: \(s.brightness), contrast: \(s.contrast),
              sepia: \(s.sepia), grayscale: \(s.grayscale)
            });
            window.__kestrelDarkReader = true;
            return true;
          } catch (e) { return 'error'; }
        })();
        """
    }

    /// What a tab should actually run: Dark Reader if installed, else the built-in
    /// filter mode. Callers do not need to know which.
    static func effectiveToggleJS() -> String {
        toggleJS() ?? DarkMode.toggleJS
    }

    static var modeDescription: String {
        isAvailable ? "Dark Reader (dynamic)" : "built-in filter (install Dark Reader for better results)"
    }
}
