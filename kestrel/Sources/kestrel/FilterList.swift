import Foundation

/// Converts EasyList / uBlock / hosts-format filter lists into Safari content-blocker
/// JSON, so Kestrel can use real blocklists instead of a hand-written starter set.
///
/// Why this rather than a proxy: Zen (github.com/irbis-sh/zen-desktop) filters
/// system-wide by running a local MITM proxy, which wins on coverage — every app, not
/// just this browser — but costs a CA certificate in your trust store, a network hop,
/// and it cannot do cosmetic filtering because it never sees the DOM. Compiling rules
/// into WebKit keeps blocking inside the engine: no certificate, no extra hop, element
/// hiding works, and per DESIGN.md §6 it costs approximately nothing per tab. The
/// trade-off is that it only covers this browser and only the subset of filter syntax
/// WebKit's rule format can express — which is what this file is careful about.
enum FilterList {

    struct Stats {
        var total = 0
        var blocked = 0
        var exceptions = 0
        var cosmetic = 0
        var skipped = 0
        var skippedReasons: [String: Int] = [:]

        var summary: String {
            let top = skippedReasons.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "\(total) lines -> \(blocked) block, \(exceptions) allow, "
                 + "\(cosmetic) cosmetic, \(skipped) skipped"
                 + (top.isEmpty ? "" : " (\(top))")
        }
    }

    /// WebKit refuses a list above this size, so it has to be enforced here rather than
    /// discovered as a compile failure.
    static let maxRules = 50_000

    static func convert(_ text: String) -> (json: String, stats: Stats) {
        var stats = Stats()
        var blockRules: [[String: Any]] = []
        var exceptionRules: [[String: Any]] = []
        var cosmeticByDomain: [String: [String]] = [:]   // "" = all sites
        var globalCosmetic: [String] = []

        func skip(_ reason: String) {
            stats.skipped += 1
            stats.skippedReasons[reason, default: 0] += 1
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            stats.total += 1

            // Comments and list metadata.
            if line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("#!")
                || line.hasPrefix("# ") { skip("comment"); continue }

            // hosts format: "0.0.0.0 ads.example.com" / "127.0.0.1 ads.example.com"
            if line.hasPrefix("0.0.0.0 ") || line.hasPrefix("127.0.0.1 ") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { skip("malformed hosts"); continue }
                let host = parts[1]
                guard isPlausibleHost(host), host != "localhost" else {
                    skip("non-host"); continue
                }
                blockRules.append([
                    "trigger": ["url-filter": domainFilter(host)],
                    "action": ["type": "block"],
                ])
                stats.blocked += 1
                continue
            }

            // Cosmetic rules: "##selector", "domain.com##selector".
            // "#@#" (exception) and "#?#"/"#$#" (procedural/scriptlet) have no
            // equivalent in WebKit's format.
            if let r = line.range(of: "#@#") ?? line.range(of: "#?#")
                ?? line.range(of: "#$#") ?? line.range(of: "##+js") {
                _ = r; skip("procedural/scriptlet cosmetic"); continue
            }
            if let r = line.range(of: "##") {
                let domains = String(line[line.startIndex..<r.lowerBound])
                let selector = String(line[r.upperBound...])
                guard !selector.isEmpty else { skip("empty selector"); continue }
                if domains.isEmpty {
                    globalCosmetic.append(selector)
                } else {
                    for d in domains.split(separator: ",") {
                        let dom = d.trimmingCharacters(in: .whitespaces)
                        guard !dom.hasPrefix("~"), isPlausibleHost(dom) else { continue }
                        cosmeticByDomain[dom, default: []].append(selector)
                    }
                }
                stats.cosmetic += 1
                continue
            }

            // Network rules.
            let isException = line.hasPrefix("@@")
            if isException { line = String(line.dropFirst(2)) }

            // Options after "$".
            var options: [String] = []
            if let dollar = line.lastIndex(of: "$"),
               // not a regex-anchor dollar inside a /regex/ rule
               !(line.hasPrefix("/") && line.hasSuffix("/")) {
                options = String(line[line.index(after: dollar)...])
                    .split(separator: ",").map(String.init)
                line = String(line[line.startIndex..<dollar])
            }
            if line.hasPrefix("/") && line.hasSuffix("/") && line.count > 2 {
                skip("regex rule"); continue      // WebKit's regex dialect differs; unsafe to pass through
            }

            var trigger: [String: Any] = [:]
            guard let filter = urlFilter(for: line) else { skip("unsupported pattern"); continue }
            trigger["url-filter"] = filter

            var unsupportedOption = false
            var ifDomain: [String] = [], unlessDomain: [String] = []
            var resourceTypes: [String] = []
            for opt in options {
                switch true {
                case opt == "third-party": trigger["load-type"] = ["third-party"]
                case opt == "first-party" || opt == "~third-party":
                    trigger["load-type"] = ["first-party"]
                case opt.hasPrefix("domain="):
                    for d in opt.dropFirst(7).split(separator: "|") {
                        if d.hasPrefix("~") { unlessDomain.append("*" + d.dropFirst()) }
                        else { ifDomain.append("*" + d) }
                    }
                case opt == "script": resourceTypes.append("script")
                case opt == "image": resourceTypes.append("image")
                case opt == "stylesheet": resourceTypes.append("style-sheet")
                case opt == "subdocument": resourceTypes.append("document")
                case opt == "xmlhttprequest": resourceTypes.append("raw")
                case opt == "font": resourceTypes.append("font")
                case opt == "media": resourceTypes.append("media")
                case opt == "popup": resourceTypes.append("popup")
                case opt == "document": resourceTypes.append("document")
                case opt == "match-case": break
                default: unsupportedOption = true    // csp=, redirect=, removeparam=, etc.
                }
            }
            if unsupportedOption { skip("unsupported option"); continue }
            // WebKit rejects a trigger carrying both (WKErrorDomain error 6), so they
            // are mutually exclusive. Prefer the positive list: a negated domain is
            // normally absent from it anyway, so dropping the negation changes nothing.
            // The exception is `domain=example.com|~sub.example.com`, where the
            // negation is genuinely lost -- counted so it is visible rather than silent.
            if !ifDomain.isEmpty {
                trigger["if-domain"] = ifDomain
                if !unlessDomain.isEmpty {
                    stats.skippedReasons["domain negation dropped", default: 0] += 1
                }
            } else if !unlessDomain.isEmpty {
                trigger["unless-domain"] = unlessDomain
            }
            if !resourceTypes.isEmpty { trigger["resource-type"] = resourceTypes }

            let rule: [String: Any] = [
                "trigger": trigger,
                "action": ["type": isException ? "ignore-previous-rules" : "block"],
            ]
            if isException { exceptionRules.append(rule); stats.exceptions += 1 }
            else { blockRules.append(rule); stats.blocked += 1 }
        }

        // Cosmetic rules collapse into one rule per domain, which keeps the rule count
        // far below the per-selector alternative.
        var cosmeticRules: [[String: Any]] = []
        if !globalCosmetic.isEmpty {
            cosmeticRules.append([
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none",
                           "selector": globalCosmetic.joined(separator: ", ")],
            ])
        }
        for (domain, selectors) in cosmeticByDomain.sorted(by: { $0.key < $1.key }) {
            cosmeticRules.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*" + domain]],
                "action": ["type": "css-display-none",
                           "selector": selectors.joined(separator: ", ")],
            ])
        }

        // Order matters: WebKit applies rules in order, and ignore-previous-rules only
        // overrides what came before it.
        var all = blockRules + cosmeticRules + exceptionRules
        if all.count > maxRules {
            // Drop block rules from the tail; never drop exceptions, since losing an
            // allow-rule breaks a site rather than merely failing to block an ad.
            let overflow = all.count - maxRules
            blockRules.removeLast(min(overflow, blockRules.count))
            all = blockRules + cosmeticRules + exceptionRules
            stats.skippedReasons["over rule cap", default: 0] += overflow
        }

        let data = try! JSONSerialization.data(withJSONObject: all)
        return (String(data: data, encoding: .utf8)!, stats)
    }

    // MARK: - pattern translation

    /// `||example.com^` and bare hosts -> an anchored URL filter.
    static func domainFilter(_ host: String) -> String {
        "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: host) + "[:/]"
    }

    static func urlFilter(for pattern: String) -> String? {
        var p = pattern
        guard !p.isEmpty else { return nil }

        if p.hasPrefix("||") {
            p = String(p.dropFirst(2))
            // A trailing separator just means "end of host".
            if p.hasSuffix("^") { p = String(p.dropLast()) }
            if !p.contains("/") && !p.contains("*") && isPlausibleHost(p) {
                return domainFilter(p)
            }
            var body = NSRegularExpression.escapedPattern(for: p)
            body = body.replacingOccurrences(of: "\\*", with: ".*")
            body = body.replacingOccurrences(of: "\\^", with: "[/:?&=]")
            return "^https?://([^/]+\\.)?" + body
        }

        var anchoredStart = false
        if p.hasPrefix("|") { p = String(p.dropFirst()); anchoredStart = true }
        if p.hasSuffix("|") { p = String(p.dropLast()) }
        guard !p.isEmpty else { return nil }

        var body = NSRegularExpression.escapedPattern(for: p)
        body = body.replacingOccurrences(of: "\\*", with: ".*")
        body = body.replacingOccurrences(of: "\\^", with: "[/:?&=]")
        return anchoredStart ? "^" + body : body
    }

    static func isPlausibleHost(_ s: String) -> Bool {
        guard s.contains("."), !s.contains("/"), !s.contains("*"), !s.contains(" ")
        else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
