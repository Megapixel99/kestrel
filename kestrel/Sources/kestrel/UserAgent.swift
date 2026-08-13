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
}
