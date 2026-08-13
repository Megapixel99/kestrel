import AppKit
import WebKit

/// Headless driver: load real sites, replay a recency-biased access trace, and log the
/// real memory each policy actually holds.
///
/// One policy per process invocation. WebKit caches WebContent processes aggressively
/// (measured: a released process can outlive its view by minutes), so running two
/// policies in one process would let the first contaminate the second.
enum Benchmark {

    static func run(urlFile: String, budgetMB: Int) {
        let args = CommandLine.arguments
        let policy = args.count > 4 ? args[4] : "kestrel"
        let events = args.count > 5 ? Int(args[5]) ?? 40 : 40

        guard let text = try? String(contentsOfFile: urlFile, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(urlFile)\n".data(using: .utf8)!)
            exit(2)
        }
        let urls = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0) }
        guard !urls.isEmpty else { exit(2) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        window.contentView = container

        let sched = Scheduler(budgetBytes: Int64(budgetMB) * 1024 * 1024,
                              perTabCapBytes: 0, keepLive: 3)
        var tabs: [Tab] = []
        for (i, u) in urls.enumerated() { tabs.append(Tab(id: i, url: u)) }

        var samples: [Int64] = []
        var restores: [Double] = []
        var trace = Trace(seed: 20260811, n: urls.count)

        log("# policy=\(policy) budget=\(budgetMB)MB tabs=\(urls.count) events=\(events)")
        log("# event tab state_before total_mb restore_ms")

        for e in 0..<events {
            let idx = trace.next()
            let tab = tabs[idx]
            let before = tab.state

            // Time the restore to didFinish, not just the synchronous call -- what the
            // user waits for is the page appearing, not the API returning.
            let waiter = NavWaiter()
            let t0 = Date()
            tab.promote(to: .live, in: container)
            tab.webView?.navigationDelegate = waiter
            tab.lastUsed = Date()
            tab.uses += 1
            if before == .live {
                settle(seconds: 1.2)
            } else {
                while waiter.finishedAt == nil && Date().timeIntervalSince(t0) < 20 {
                    RunLoop.current.run(mode: .default,
                                        before: Date().addingTimeInterval(0.01))
                }
                settle(seconds: 1.5)   // let the memory number stabilise after load
            }
            let ms = (waiter.finishedAt ?? Date()).timeIntervalSince(t0) * 1000
            if before != .live { restores.append(ms) }

            // Keep only the foreground tab attached, as a real browser would.
            for other in tabs where other.id != tab.id && other.state == .live {
                other.webView?.removeFromSuperview()
            }

            switch policy {
            case "none":       break
            case "discardlru": sched.enforceDiscardLRU(tabs, foreground: tab.id)
            default:           sched.enforce(tabs, foreground: tab.id)
            }
            settle(seconds: 0.8)

            // Headless: measure synchronously, accuracy matters more than latency.
            let total = tabs.reduce(Int64(0)) { $0 + $1.measureNow() }
            samples.append(total)
            log(String(format: "%d %d %@ %.1f %.0f", e, idx, before.description,
                       Double(total) / 1_048_576, ms))
        }

        let mb = { (v: Int64) in Double(v) / 1_048_576 }
        let mean = samples.isEmpty ? 0 : Double(samples.reduce(0, +)) / Double(samples.count) / 1_048_576
        let peak = mb(samples.max() ?? 0)
        let over = samples.filter { $0 > sched.budgetBytes }.count
        let sortedR = restores.sorted()
        let p95 = sortedR.isEmpty ? 0 : sortedR[min(sortedR.count - 1, Int(Double(sortedR.count) * 0.95))]

        log("")
        log("RESULT policy=\(policy) mean_mb=\(String(format: "%.1f", mean)) "
            + "peak_mb=\(String(format: "%.1f", peak)) "
            + "over_budget_pct=\(String(format: "%.0f", 100.0 * Double(over) / Double(max(1, samples.count)))) "
            + "restores=\(restores.count) "
            + "p95_restore_ms=\(String(format: "%.0f", p95)) "
            + "state_lost=\(sched.stateLosses) "
            + "demotions=\(sched.demotions) gave_up=\(sched.gaveUp)")
        exit(0)
    }

    static let navWaiter = NavWaiter()

    /// Recency-biased revisit, matching the Zipf-over-LRU-stack model the simulation
    /// used, so the real run and the simulated run are driven the same way.
    struct Trace {
        var rng: UInt64
        var stack: [Int]
        let alpha = 1.1
        var warmup: Int              // open every tab once before revisiting
        init(seed: UInt64, n: Int) { rng = seed; stack = Array(0..<n); warmup = n }
        mutating func rand() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(rng % 1_000_000) / 1_000_000
        }
        mutating func next() -> Int {
            // A pure Zipf-over-LRU trace revisits the few most recent tabs and leaves
            // most tabs never opened, so nothing accumulates and no policy is exercised.
            // Open each tab once first, as a user filling a window would.
            if warmup > 0 {
                warmup -= 1
                let tid = stack.removeLast()
                stack.insert(tid, at: 0)
                return tid
            }
            let weights = (1...stack.count).map { pow(1.0 / Double($0), alpha) }
            let total = weights.reduce(0, +)
            var x = rand() * total, pick = 0
            for (i, w) in weights.enumerated() { x -= w; if x <= 0 { pick = i; break } }
            let tid = stack.remove(at: pick)
            stack.insert(tid, at: 0)
            return tid
        }
    }

    static func settle(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    static func log(_ s: String) {
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }
}
