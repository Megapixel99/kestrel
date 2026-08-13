import Foundation
import WebKit

/// Converts a filter list and — crucially — makes WebKit compile the result.
/// A converter that emits plausible-looking JSON WebKit rejects is worthless.
enum FilterTest {
    static func run(path: String?) {
        let sample = """
        [Adblock Plus 2.0]
        ! Title: sample list
        ||doubleclick.net^
        ||ads.example.com^$third-party
        ||tracker.test^$script,third-party
        ||analytics.example.org^$domain=news.example|~admin.example
        |http://banner.example.com/
        /ads/banner
        @@||example.com/allowed^
        ##.ad-container
        ##div[id^="google_ads"]
        news.example##.sponsored-story
        shop.example,blog.example##.promo
        example.com#@#.excepted
        ||api.example.com^$csp=script-src 'none'
        /^https?:\\/\\/regex\\.example\\//
        0.0.0.0 malware.test
        127.0.0.1 tracking.test
        0.0.0.0 localhost
        """
        let text: String
        if let path, let t = try? String(contentsOfFile: path, encoding: .utf8) {
            text = t
            print("filter list: \(path)")
        } else {
            text = sample
            print("filter list: built-in sample (pass a path to convert a real list)")
        }

        let (json, stats) = FilterList.convert(text)
        print("  \(stats.summary)")
        print("  JSON size: \(json.count / 1024) KB")

        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — " + detail)")
            if !ok { fails += 1 }
        }

        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
        check("output is valid JSON array", parsed != nil, "\(parsed?.count ?? 0) rules")

        if path == nil {
            check("hosts entries converted", json.contains("malware\\\\.test"))
            check("localhost ignored", !json.contains("localhost"))
            check("third-party option mapped", json.contains("third-party"))
            check("domain= mapped to if-domain", json.contains("if-domain"))
            check("exception became ignore-previous-rules",
                  json.contains("ignore-previous-rules"))
            check("cosmetic selectors kept", json.contains("css-display-none"))
            check("unsupported $csp skipped",
                  stats.skippedReasons["unsupported option"] ?? 0 > 0)
            check("regex rule skipped", stats.skippedReasons["regex rule"] ?? 0 > 0)
            check("#@# exception skipped",
                  stats.skippedReasons["procedural/scriptlet cosmetic"] ?? 0 > 0)
            // Exceptions must come last or they cannot override the blocks.
            if let parsed {
                let firstException = parsed.firstIndex {
                    ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
                }
                let lastBlock = parsed.lastIndex {
                    ($0["action"] as? [String: Any])?["type"] as? String == "block"
                }
                check("exceptions ordered after blocks",
                      (firstException ?? Int.max) > (lastBlock ?? -1))
            }
        }

        // The real test: WebKit's own compiler.
        var done = false
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "kestrel-filtertest", encodedContentRuleList: json
        ) { list, err in
            check("WebKit compiles the converted list", list != nil,
                  err.map { String($0.localizedDescription.prefix(120)) } ?? "")
            done = true
        }
        let deadline = Date().addingTimeInterval(120)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !done { check("WebKit compiles the converted list", false, "timed out") }

        print("\n\(fails == 0 ? "filter conversion works" : "\(fails) FAILURES")")
        exit(fails == 0 ? 0 : 1)
    }
}
