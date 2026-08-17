import AppKit
import WebKit

/// Measures what each rung of the DESIGN.md §2 ladder actually costs on a real engine.
///
/// Views are created one at a time so each new WebContent pid can be attributed to the
/// view that caused it -- WKWebView exposes no pid, so pid-set diffing is the only way
/// to map a tab to its process.
enum Probe {
    static func run(count: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container

        var tabs: [(view: WKWebView, pid: Int32)] = []
        log("spawning \(count) tabs, one at a time, to map each to its process...\n")

        for i in 0..<count {
            let before = Set(currentPids())
            let cfg = WKWebViewConfiguration()
            cfg.processPool = WKProcessPool()
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900),
                               configuration: cfg)
            container.addSubview(wv)
            wv.loadHTMLString(syntheticPage(index: i),
                              baseURL: URL(string: "https://example\(i).invalid/"))
            waitRunLoop(seconds: 3.5)
            // Ask the view for its process. The diff below is the fallback, and it is
            // how every rung cost this project has published was attributed: `.first` on
            // an unordered set of whatever appeared. Usually right here — one view at a
            // time, 3.5 s apart — but "usually" is not a basis for a published number.
            let direct = MemoryProbe.privateProcessIdentifier(of: wv)
            let newPids = Set(currentPids()).subtracting(before)
            guard let pid = direct ?? newPids.first else {
                log("  tab \(i): could not identify a process; skipping")
                continue
            }
            if let direct, newPids.count > 1 {
                log("  tab \(i): \(newPids.count) processes appeared; the view names "
                    + "pid \(direct)")
            } else if direct == nil {
                log("  tab \(i): view would not name its process; fell back to a diff of "
                    + "\(newPids.count)")
            }
            let mb = mbOf(pid)
            log(String(format: "  tab %d -> pid %d, LIVE = %.1f MB", i, pid, mb))
            tabs.append((wv, pid))
        }
        guard !tabs.isEmpty else { exit(1) }

        let liveTotal = tabs.reduce(0.0) { $0 + mbOf($1.pid) }
        log(String(format: "\nLIVE: %d tabs, %.1f MB total, %.1f MB/tab\n",
                   tabs.count, liveTotal, liveTotal / Double(tabs.count)))

        // ---- WARM: detach from the view hierarchy, suspend media, pause timers ----
        // Everything a host app can do to a WKWebView short of destroying it.
        let subject = tabs[0]
        let liveMB = mbOf(subject.pid)
        subject.view.removeFromSuperview()
        if #available(macOS 12.0, *) { subject.view.setAllMediaPlaybackSuspended(true) }
        subject.view.evaluateJavaScript(
            "for (let i = 1; i < 99999; i++) { clearInterval(i); clearTimeout(i); }",
            completionHandler: nil)
        waitRunLoop(seconds: 6)
        let warmMB = mbOf(subject.pid)

        // ---- COLD: capture the session image, then navigate the page away ----
        let state = subject.view.interactionState as? Data
        subject.view.load(URLRequest(url: URL(string: "about:blank")!))
        waitRunLoop(seconds: 8)
        // Navigating away can move the page to a different process, and this measured the
        // original pid regardless — so a COLD figure could be the *old* process's
        // footprint while the view lived somewhere else entirely.
        let coldPid = MemoryProbe.privateProcessIdentifier(of: subject.view) ?? subject.pid
        if coldPid != subject.pid {
            log(String(format: "  note: navigating away moved the view from pid %d to %d; "
                             + "the old process still holds %.1f MB",
                       subject.pid, coldPid, mbOf(subject.pid)))
        }
        let coldMB = mbOf(coldPid)

        log("one tab through the ladder (pid \(subject.pid)):")
        log(String(format: "  LIVE  %7.1f MB", liveMB))
        log(String(format: "  WARM  %7.1f MB   (%.0f%% of live, recovered %.1f MB)",
                   warmMB, 100 * warmMB / liveMB, liveMB - warmMB))
        log(String(format: "  COLD  %7.1f MB   (%.0f%% of live, recovered %.1f MB)",
                   coldMB, 100 * coldMB / liveMB, liveMB - coldMB))
        log("  session image: \(state?.count ?? 0) bytes on disk")

        // ---- restore COLD -> LIVE, timed properly off the navigation delegate ----
        let waiter = NavWaiter()
        subject.view.navigationDelegate = waiter
        let t0 = Date()
        if let state { subject.view.interactionState = state }
        subject.view.loadHTMLString(syntheticPage(index: 0),
                                    baseURL: URL(string: "https://example0.invalid/"))
        while waiter.finishedAt == nil && Date().timeIntervalSince(t0) < 30 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let restoreMs = (waiter.finishedAt ?? Date()).timeIntervalSince(t0) * 1000
        waitRunLoop(seconds: 2)
        // Restoring can move the view again; ask rather than assume.
        let restoredPid = MemoryProbe.privateProcessIdentifier(of: subject.view)
                       ?? coldPid
        let restoredMB = mbOf(restoredPid)
        log(String(format: "  restore COLD -> LIVE: %.0f ms to didFinish, back to %.1f MB\n",
                   restoreMs, restoredMB))

        // ---- does releasing the blanked view get below the process baseline? ----
        let releasedPid = coldPid
        autoreleasepool {
            var v: WKWebView? = subject.view
            v?.navigationDelegate = nil
            v?.load(URLRequest(url: URL(string: "about:blank")!))
            v?.removeFromSuperview()
            v = nil
        }
        tabs.removeAll { $0.pid == releasedPid }
        var died = false
        for _ in 0..<60 {
            waitRunLoop(seconds: 0.5)
            if !MemoryProbe.isAlive(releasedPid) { died = true; break }
        }
        log(died
            ? "  releasing the blanked view DID free its process (baseline recovered)"
            : String(format: "  releasing the blanked view left the process alive at %.1f MB",
                     mbOf(releasedPid)))
        log("")

        log("Implication for COLD: WebKit exposes no public way to terminate a")
        log("WebContent process on demand, so COLD is navigate-away + interactionState.")
        log(String(format: "It recovers %.0f%% of a live tab; the residual %.1f MB is the",
                   100 * (liveMB - coldMB) / liveMB, coldMB))
        log("process baseline that only process death would return.")
        exit(0)
    }

    static func currentPids() -> [Int32] { MemoryProbe.webContentPids() }

    static func mbOf(_ pid: Int32) -> Double {
        Double(MemoryProbe.footprint(pid: pid) ?? 0) / 1_048_576
    }

    static func syntheticPage(index: Int) -> String {
        """
        <!doctype html><html><head><title>probe \(index)</title></head><body>
        <div id="root"></div>
        <script>
          const root = document.getElementById('root');
          const retained = [];
          for (let i = 0; i < 20000; i++) {
            const d = document.createElement('div');
            d.textContent = 'row ' + i + ' of page \(index)';
            d.dataset.k = String(i * 2654435761 % 100000);
            root.appendChild(d);
            retained.push({ i, s: 'payload-' + i, buf: new Array(24).fill(i) });
          }
          window.__retained = retained;   // keep it reachable, like a real SPA
          setInterval(() => { window.__tick = (window.__tick || 0) + 1; }, 16);
        </script></body></html>
        """
    }

    static func waitRunLoop(seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    static func log(_ s: String) {
        FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
    }
}

/// Times a navigation to didFinish so restore latency is measured, not assumed.
final class NavWaiter: NSObject, WKNavigationDelegate {
    var finishedAt: Date?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if finishedAt == nil { finishedAt = Date() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        if finishedAt == nil { finishedAt = Date() }
    }
}
