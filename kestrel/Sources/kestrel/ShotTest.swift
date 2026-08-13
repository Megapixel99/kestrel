import AppKit
import WebKit

/// Verifies full-page capture on a page built to break it: taller than the viewport,
/// with a sticky header that would otherwise repeat in every band.
enum ShotTest {
    static func run() {
        print("Screenshot end-to-end test\n")
        var fails = 0
        func check(_ n: String, _ ok: Bool, _ d: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(n)\(d.isEmpty ? "" : "  — " + d)")
            if !ok { fails += 1 }
        }

        // Capture planning must bound memory before allocating anything.
        let big = Screenshot.plan(content: CGSize(width: 1440, height: 50000),
                                  viewport: CGSize(width: 1440, height: 900),
                                  deviceScale: 2)
        let px = big.scaledSize.width * 2 * big.scaledSize.height * 2
        check("a 50,000 px page is scaled to fit the capture budget",
              big.wasDownscaled && Int(px) <= Screenshot.maxPixels * 11 / 10,
              String(format: "scale %.3f -> %.0f MP", big.scale, px / 1_000_000))
        let small = Screenshot.plan(content: CGSize(width: 1440, height: 3000),
                                    viewport: CGSize(width: 1440, height: 900),
                                    deviceScale: 2)
        check("an ordinary page is not scaled", !small.wasDownscaled,
              String(format: "scale %.3f, %d bands", small.scale, small.bandCount))
        check("band count covers the page", small.bandCount == 4, "\(small.bandCount)")

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: win.contentLayoutRect)
        win.contentView = container
        let wv = WKWebView(frame: container.bounds)
        container.addSubview(wv)
        win.makeKeyAndOrderFront(nil)

        // 5 coloured full-viewport blocks + a sticky header.
        let page = """
        <!doctype html><html><head><style>
          body{margin:0;font:16px system-ui}
          header{position:sticky;top:0;height:44px;background:#111;color:#fff;
                 display:flex;align-items:center;padding:0 16px;z-index:9}
          section{height:100vh;display:flex;align-items:center;justify-content:center;
                  font-size:64px;color:#fff}
        </style></head><body>
          <header>sticky header</header>
          <section style="background:#e5342a">1</section>
          <section style="background:#2aa84a">2</section>
          <section style="background:#2a6ae5">3</section>
          <section style="background:#e5a52a">4</section>
          <section style="background:#8a2ae5">5</section>
        </body></html>
        """
        let waiter = NavWaiter()
        wv.navigationDelegate = waiter
        wv.loadHTMLString(page, baseURL: URL(string: "https://shot.invalid/"))
        settle(until: { waiter.finishedAt != nil }, timeout: 20)
        settle(seconds: 1.0)

        var visible: NSImage?
        var got = false
        Screenshot.captureVisible(wv) { img, _ in visible = img; got = true }
        settle(until: { got }, timeout: 20)
        check("visible capture returns an image", visible != nil,
              visible.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "nil")

        var full: NSImage?
        var note = ""
        var done = false
        Screenshot.captureFullPage(wv) { img, n in full = img; note = n; done = true }
        settle(until: { done }, timeout: 120)
        check("full page capture returns an image", full != nil, note)

        if let full, let v = visible {
            check("full page is taller than the viewport",
                  full.size.height > v.size.height * 3,
                  "\(Int(full.size.height))px vs viewport \(Int(v.size.height))px")

            // The sticky header is dark; if it repeated per band it would appear as a
            // dark stripe at every viewport boundary. Sample down the middle column.
            if let tiff = full.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                var darkRuns = 0
                let x = rep.pixelsWide / 2
                var inDark = false
                for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let dark = (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.15
                    if dark && !inDark { darkRuns += 1 }
                    inDark = dark
                }
                check("sticky header does not repeat in every band", darkRuns <= 2,
                      "\(darkRuns) dark bands found (5 would mean one per section)")

                // All five colours should survive the stitch.
                var seen = Set<String>()
                for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.alphaComponent < 0.5 { continue }
                    let key = "\(Int(c.redComponent*4))-\(Int(c.greenComponent*4))-\(Int(c.blueComponent*4))"
                    seen.insert(key)
                }
                check("stitched image contains several distinct sections",
                      seen.count >= 4, "\(seen.count) distinct colour buckets")
            }
        }

        var pdf: Data?
        var pdone = false
        Screenshot.capturePDF(wv) { d, _ in pdf = d; pdone = true }
        settle(until: { pdone }, timeout: 40)
        check("PDF capture produces a PDF", (pdf?.count ?? 0) > 1000 &&
              pdf?.prefix(4).elementsEqual("%PDF".utf8) == true,
              "\((pdf?.count ?? 0) / 1024) KB")

        print("\n\(fails == 0 ? "screenshot capture works" : "\(fails) FAILURES")")
        exit(fails == 0 ? 0 : 1)
    }

    static func settle(seconds: Double) {
        let d = Date().addingTimeInterval(seconds)
        while Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    static func settle(until c: () -> Bool, timeout: Double) {
        let d = Date().addingTimeInterval(timeout)
        while !c() && Date() < d { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
}
