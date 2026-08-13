import AppKit
import WebKit

/// What the engine is already doing to protect this page, made visible.
///
/// Firefox has a protections panel behind the shield in its address bar. Kestrel had a
/// shield too, until the built-in ad blocker was deleted with the other imitations — and
/// what remained was a browser doing a substantial amount of tracking protection and
/// telling the user nothing about it.
///
/// WebKit's Intelligent Tracking Prevention is on by default in every `WKWebView`: it
/// partitions third-party storage, caps script-writable cookie lifetimes, and blocks
/// classified trackers' cookies outright. Kestrel does not implement any of it and takes no
/// credit for it. This panel reports it, alongside the two things Kestrel *does* control —
/// whether the page is on HTTPS, and what an installed ad-blocking add-on is doing — and
/// distinguishes the three, because a panel that blurs "the engine does this" with "we do
/// this" is marketing.
enum Protections {

    struct Item {
        let title: String
        let detail: String
        let state: State
        let owner: Owner

        enum State { case on, off, unknown }
        /// Who is responsible, which is the distinction worth drawing.
        enum Owner: String { case engine = "WebKit", browser = "Kestrel", addon = "add-on" }
    }

    @MainActor
    static func items(for tab: Tab?) -> [Item] {
        var out: [Item] = []
        let url = tab?.url

        // WebKit exposes no read-only accessor for ITP's state, so this reports the
        // platform default rather than inventing a reading. Saying "on" because Apple
        // says it is on is different from measuring it, and the wording admits that.
        out.append(Item(
            title: "Tracking protection",
            detail: "On by default in WebKit — third-party storage partitioned, tracker "
                  + "cookies blocked, script-set cookie lifetimes capped. Not configurable "
                  + "from this app, and not measured here.",
            state: .on,
            owner: .engine))

        let https = url?.scheme == "https"
        out.append(Item(
            title: https ? "Connection is encrypted" : "Connection is not encrypted",
            detail: https ? (url?.host ?? "") + " over TLS"
                          : "This page was loaded over plain HTTP",
            state: https ? .on : .off,
            owner: .browser))

        // Add-ons are the ad blocker now, so the panel reports what is installed rather
        // than claiming a capability the browser no longer has.
        if #available(macOS 15.4, *) {
            let blockers = MainActor.assumeIsolated {
                ExtensionRuntime.shared.contexts.filter { $0.value.hasContentModificationRules }
            }
            let enabled = ExtensionStore.installed()
                .filter { Prefs.isExtensionEnabled($0.id) }
            let names = enabled.filter { blockers[$0.id] != nil }.map(\.name)
            out.append(Item(
                title: names.isEmpty ? "No content blocker" : "Content blocking",
                detail: names.isEmpty
                    ? "Kestrel has no built-in ad blocker — install one from the add-ons menu"
                    : names.joined(separator: ", ") + " has content rules compiled into WebKit",
                state: names.isEmpty ? .off : .on,
                owner: .addon))
        }

        let mediaHost = url?.host ?? ""
        let camera = Prefs.mediaDecision(for: "\(mediaHost)|camera")
        let mic = Prefs.mediaDecision(for: "\(mediaHost)|microphone")
        if camera != nil || mic != nil {
            var granted: [String] = []
            if camera == true { granted.append("camera") }
            if mic == true { granted.append("microphone") }
            out.append(Item(
                title: granted.isEmpty ? "Camera and microphone blocked"
                                       : "Allowed: " + granted.joined(separator: ", "),
                detail: "Remembered for \(mediaHost) — reset from the wrench menu",
                state: granted.isEmpty ? .on : .off,
                owner: .browser))
        }

        return out
    }

    /// Storage this site has on disk, fetched asynchronously because that is the only way
    /// WebKit will report it.
    @MainActor
    static func siteData(for host: String, completion: @escaping (String) -> Void) {
        guard !host.isEmpty else { return completion("") }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter {
                $0.displayName == host || host.hasSuffix("." + $0.displayName)
            }
            guard !mine.isEmpty else { return completion("No stored data for this site") }
            let kinds = Set(mine.flatMap { $0.dataTypes })
                .map { $0.replacingOccurrences(of: "WKWebsiteDataType", with: "") }
                .sorted()
            completion("Stored here: " + kinds.joined(separator: ", "))
        }
    }

    /// Clears everything this site has stored. Destructive, so the caller confirms first.
    @MainActor
    static func clearSiteData(for host: String, completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter {
                $0.displayName == host || host.hasSuffix("." + $0.displayName)
            }
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: mine) {
                completion()
            }
        }
    }
}
