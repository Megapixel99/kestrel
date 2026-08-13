import AppKit
import CoreImage
import WebKit

// MARK: - Dark mode

/// A Dark-Reader-style dark mode, injected as CSS.
///
/// Honest about what this is: Dark Reader analyses computed styles per element and
/// rebuilds a palette. This is the cheaper "smart invert" approach — invert the whole
/// document, rotate hue to keep colours roughly right, then un-invert media so photos
/// and video are not negatives. It handles most sites and gets some wrong, and it costs
/// one stylesheet per tab rather than a JS analysis pass.
enum DarkMode {
    static let css = """
    html { filter: invert(100%) hue-rotate(180deg) contrast(90%) !important;
           background: #131313 !important; }
    img, video, canvas, svg, picture, iframe, embed, object,
    [style*="background-image"], .no-invert {
        filter: invert(100%) hue-rotate(180deg) !important;
    }
    """

    static func script() -> WKUserScript {
        let js = """
        (function () {
          if (document.getElementById('__kestrel_dark')) return;
          const s = document.createElement('style');
          s.id = '__kestrel_dark';
          s.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(s);
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    static let toggleJS = """
    (function () {
      const e = document.getElementById('__kestrel_dark');
      if (e) { e.remove(); return false; }
      const s = document.createElement('style');
      s.id = '__kestrel_dark';
      s.textContent = `\(css)`;
      (document.head || document.documentElement).appendChild(s);
      return true;
    })();
    """
}

// MARK: - QR codes

enum QRCode {
    /// CoreImage ships a QR encoder, so this needs no dependency.
    static func image(for string: String, size: CGFloat = 320) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")   // 15% recovery
        guard let out = filter.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Userscripts

/// A Tampermonkey-style userscript engine.
///
/// Scripts live in ~/.kestrel/userscripts/*.user.js and use the standard metadata
/// block. WebKit has no notion of match patterns — a WKUserScript is injected into
/// every page — so each script is wrapped in a runtime origin guard compiled from its
/// @match lines.
struct UserScript {
    let name: String
    let matches: [String]
    let runAtStart: Bool
    let body: String

    static func parse(_ source: String, filename: String) -> UserScript {
        var name = filename
        var matches: [String] = []
        var runAtStart = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("//") else {
                if t.contains("==/UserScript==") { break } else { continue }
            }
            if let r = t.range(of: "@name") {
                name = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = t.range(of: "@match") ?? t.range(of: "@include") {
                matches.append(String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            } else if t.contains("@run-at") {
                runAtStart = t.contains("document-start")
            }
        }
        if matches.isEmpty { matches = ["*://*/*"] }
        return UserScript(name: name, matches: matches, runAtStart: runAtStart, body: source)
    }

    /// Converts @match glob patterns into a JS regex test performed at run time.
    private var guardRegex: String {
        matches.map { pat -> String in
            var p = NSRegularExpression.escapedPattern(for: pat)
            p = p.replacingOccurrences(of: "\\*", with: ".*")
            return "^" + p + "$"
        }.joined(separator: "|")
    }

    func wrapped() -> WKUserScript {
        let js = """
        (function () {
          try {
            const re = new RegExp(\(jsStringLiteral(guardRegex)));
            const href = location.href;
            const alt = location.protocol + '//' + location.host + location.pathname;
            if (!re.test(href) && !re.test(alt)) return;
          } catch (e) { return; }
        \(body)
        })();
        """
        return WKUserScript(source: js,
                            injectionTime: runAtStart ? .atDocumentStart : .atDocumentEnd,
                            forMainFrameOnly: false)
    }

    private func jsStringLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}

enum UserScriptStore {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel/userscripts")
    }

    static func loadAll() -> [UserScript] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasSuffix(".js") }
            .compactMap { url -> UserScript? in
                guard let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return UserScript.parse(src, filename: url.lastPathComponent)
            }
    }
}
