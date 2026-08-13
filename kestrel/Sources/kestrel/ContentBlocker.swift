import WebKit

/// Declarative ad and tracker blocking, compiled by WebKit into native rules.
///
/// This is deliberately *not* a JS-based blocker. DESIGN.md §6: a `webRequest`-style
/// listener forces a live JS context in every tab, while declarative rules are compiled
/// once and cost approximately nothing per tab. Content blocking is the single most
/// common extension people install, so which of the two you pick sets the floor for a
/// browser's per-tab memory.
enum ContentBlocker {
    static let identifier = "kestrel-blocklist"
    private(set) static var compiled: WKContentRuleList?
    private(set) static var ruleCount = 0

    /// Blocked third-party hosts. A starter list, not a replacement for EasyList --
    /// `loadCustomList` reads a user-supplied JSON rule set in the same Safari
    /// content-blocker format, which is what EasyList converters emit.
    static let adHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "rubiconproject.com",
        "pubmatic.com", "openx.net", "criteo.com", "criteo.net", "taboola.com",
        "outbrain.com", "scorecardresearch.com", "quantserve.com", "moatads.com",
        "adsrvr.org", "casalemedia.com", "33across.com", "sharethrough.com",
        "advertising.com", "yieldmo.com", "smartadserver.com", "teads.tv",
        "bluekai.com", "demdex.net", "everesttech.net", "krxd.net", "agkn.com",
        "mathtag.com", "bidswitch.net", "sitescout.com", "adform.net", "zemanta.com",
        "hotjar.com", "mixpanel.com", "segment.io", "fullstory.com", "mouseflow.com",
        "clarity.ms", "branch.io", "amplitude.com", "heapanalytics.com",
        "facebook.net", "connect.facebook.net", "ads-twitter.com", "analytics.tiktok.com",
    ]

    /// Ad endpoints served *first-party*, from the site's own origin, specifically so
    /// that third-party blocking cannot see them. MDN's `/pong/` is the example that
    /// exposed this: every rule above carries `load-type: third-party`, so a same-origin
    /// ad request sails straight through.
    static let firstPartyAdPaths = [
        "/pong/get", "/pong/click", "/api/v1/ad", "/_next/ads/",
        "/advert/", "/sponsored/", "/adserver/",
    ]

    /// Cosmetic rules: hide the containers ads leave behind so blocking doesn't leave
    /// a page full of holes.
    static let cosmeticSelectors = [
        "[id^='google_ads_']", "[id^='div-gpt-ad']", "ins.adsbygoogle",
        "[class*='sponsored-post']", "[data-ad-slot]", "iframe[src*='doubleclick']",
        // MDN renders its ads into these; they are first-party markup, so hiding is
        // the only lever once the request itself is same-origin.
        "section.place", ".place.side", ".place.top-banner", "#ad-container",
        ".ad-container", "[class*='ad-unit']", "aside[aria-label*='Advertisement' i]",
    ]

    static func ruleJSON() -> String {
        var rules: [[String: Any]] = adHosts.map { host in
            [
                "trigger": [
                    // Escaped dots, anchored at the domain boundary.
                    "url-filter": "^https?://([^/]+\\.)?\(host.replacingOccurrences(of: ".", with: "\\."))",
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        // First-party ad paths: deliberately no load-type restriction.
        for path in firstPartyAdPaths {
            rules.append([
                "trigger": ["url-filter": NSRegularExpression.escapedPattern(for: path)],
                "action": ["type": "block"],
            ])
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none",
                       "selector": cosmeticSelectors.joined(separator: ", ")],
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        ruleCount = rules.count
        return String(data: data, encoding: .utf8)!
    }

    /// Compiles once at startup; WebKit caches the compiled list in its own store.
    static func compile(_ done: @escaping (WKContentRuleList?) -> Void) {
        guard let store = WKContentRuleListStore.default() else { done(nil); return }
        let json = ruleJSON()
        store.compileContentRuleList(forIdentifier: identifier,
                                     encodedContentRuleList: json) { list, error in
            if let error {
                FileHandle.standardError.write(
                    "content blocker failed to compile: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
            compiled = list
            done(list)
        }
    }

    private(set) static var customList: WKContentRuleList?
    private(set) static var customStats: FilterList.Stats?

    /// Load a user-supplied blocklist. Accepts either Safari content-blocker JSON
    /// (`~/.kestrel/blocklist.json`) or a raw EasyList / uBlock / hosts-format list
    /// (`~/.kestrel/filters.txt`), which is converted by FilterList first. The raw
    /// form is the useful one -- it is what every published blocklist actually ships.
    static func loadCustomList(_ done: @escaping (WKContentRuleList?, String) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jsonPath = home.appendingPathComponent(".kestrel/blocklist.json")
        let filtersPath = home.appendingPathComponent(".kestrel/filters.txt")
        guard let store = WKContentRuleListStore.default() else { done(nil, "no store"); return }

        var json: String?
        var note = ""
        if let raw = try? String(contentsOf: filtersPath, encoding: .utf8) {
            let (converted, stats) = FilterList.convert(raw)
            json = converted
            customStats = stats
            note = "filters.txt: " + stats.summary
        } else if let j = try? String(contentsOf: jsonPath, encoding: .utf8) {
            json = j
            note = "blocklist.json loaded"
        }
        guard let json else { done(nil, "no custom blocklist"); return }

        store.compileContentRuleList(forIdentifier: "kestrel-custom",
                                     encodedContentRuleList: json) { list, err in
            customList = list
            done(list, list != nil ? note
                 : "custom blocklist failed to compile: "
                   + (err?.localizedDescription ?? "?")
                   + "  (run `kestrel bisect ~/.kestrel/filters.txt` to find the rule)")
        }
    }

    /// Attach to a web view that already exists. Needed because compilation is async:
    /// tabs opened before it finishes would otherwise run with no blocking at all.
    static func apply(to controller: WKUserContentController) {
        if let compiled { controller.add(compiled) }
        if let customList { controller.add(customList) }
    }

    static func apply(to config: WKWebViewConfiguration) {
        if let compiled { config.userContentController.add(compiled) }
        if let customList { config.userContentController.add(customList) }
    }
}
