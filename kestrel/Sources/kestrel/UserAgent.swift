import Foundation

/// The browser's user agent.
///
/// WKWebView builds `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)
/// AppleWebKit/605.1.15 (KHTML, like Gecko)` and stops — no `Version/x Safari/x`.
/// Sites that sniff for a known browser see nothing they recognise and serve an
/// "unsupported browser" page. `applicationNameForUserAgent` is appended to that
/// prefix, so setting it to Safari's token yields a complete, truthful UA: the engine
/// genuinely is the same WebKit Safari ships.
enum UserAgent {
    /// Read from the installed Safari so the version does not drift from the platform.
    static let safariVersion: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: plist),
           let v = d["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "18.5"
    }()

    static let webKitBuild = "605.1.15"

    /// Appended by WebKit to its own prefix.
    static var applicationName: String {
        "Version/\(safariVersion) Safari/\(webKitBuild)"
    }

    /// What the full UA will look like, for display in diagnostics.
    static var expectedFull: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/\(webKitBuild) "
        + "(KHTML, like Gecko) \(applicationName)"
    }

    /// What an add-on's own pages should see.
    ///
    /// A Firefox add-on branches on the browser it thinks it is running in, and the
    /// truncated WKWebView UA matches nothing — Dark Reader's `canInjectScript()` falls
    /// through to "this page is protected" and does nothing at all. These are Firefox
    /// add-ons; the Gecko-shaped branch is the one written for them, so their pages get
    /// a Firefox token. Web pages still get the Safari one above, which is the truthful
    /// answer for the engine actually rendering them.
    static let firefoxVersion = "141.0"
    static var extensionApplicationName: String {
        "Gecko/20100101 Firefox/\(firefoxVersion)"
    }

    /// A complete Firefox UA, with no AppleWebKit prefix.
    ///
    /// `applicationNameForUserAgent` can only *append* to WebKit's own prefix, so an
    /// add-on page ends up claiming to be both AppleWebKit and Gecko — a browser no
    /// detection script has ever seen. Adblock Plus's options page reads that and refuses
    /// with "your browser version is no longer supported". A web view Kestrel creates
    /// itself can set the whole string, and an add-on's own page is exactly that case.
    ///
    /// Only ever sent to an add-on's own pages. Web pages keep the Safari token, which is
    /// the truthful answer for the engine rendering them.
    static var firefoxFull: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(firefoxVersion)) "
        + "Gecko/20100101 Firefox/\(firefoxVersion)"
    }
}
