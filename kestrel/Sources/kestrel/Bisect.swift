import Foundation
import WebKit

enum Bisect {
  /// Compiles each converted rule alone to find exactly which one WebKit rejects.
  /// Invaluable when a real filter list fails to compile as a whole.
  static func run(path: String? = nil) {
// Compile each rule alone to find exactly which one WebKit rejects.
let sample = """
[Adblock Plus 2.0]
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
0.0.0.0 malware.test
"""
let text = path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? sample
let (json, _) = FilterList.convert(text)
let rules = (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [[String: Any]]
print("testing \(rules.count) rules individually (only failures matter)\n")

var idx = 0
func next() {
    guard idx < rules.count else { exit(0) }
    let r = rules[idx]
    let one = String(data: try! JSONSerialization.data(withJSONObject: [r]), encoding: .utf8)!
    WKContentRuleListStore.default()?.compileContentRuleList(
        forIdentifier: "bisect-\(idx)", encodedContentRuleList: one
    ) { list, err in
        let ok = list != nil
        print("\(ok ? "ok  " : "BAD ") [\(idx)] \(one.prefix(150))")
        if !ok { print("      -> \(err?.localizedDescription ?? "?")") }
        if idx == rules.count - 1 { print("\ndone") }
        idx += 1
        next()
    }
}
next()
RunLoop.current.run(until: Date().addingTimeInterval(120))
  }
}
