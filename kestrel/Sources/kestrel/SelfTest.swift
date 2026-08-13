import AppKit
import WebKit

/// Headless checks for the features that can be verified without a user driving the UI.
enum SelfTest {
    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — " + detail)")
            if !ok { failures += 1 }
        }
        print("Kestrel self-test\n")

        // --- QR ---
        let qr = QRCode.image(for: "https://example.com/some/path?q=1")
        check("QR encodes a URL", qr != nil,
              qr.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")

        // --- content blocker rules ---
        let json = ContentBlocker.ruleJSON()
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
        check("blocklist is valid JSON", parsed != nil, "\(parsed?.count ?? 0) rules")
        check("blocklist covers known ad hosts",
              json.contains("doubleclick") && json.contains("scorecardresearch"))

        // --- userscript parsing ---
        let sample = """
        // ==UserScript==
        // @name        Test Script
        // @match       https://example.com/*
        // @run-at      document-start
        // ==/UserScript==
        console.log('hi');
        """
        let us = UserScript.parse(sample, filename: "t.user.js")
        check("userscript name parsed", us.name == "Test Script", us.name)
        check("userscript match parsed", us.matches == ["https://example.com/*"],
              us.matches.joined())
        check("userscript run-at parsed", us.runAtStart)
        check("userscript wrapped with origin guard",
              us.wrapped().source.contains("RegExp") && us.wrapped().source.contains("console.log"))

        // --- Bitwarden origin gate: the security-critical logic ---
        check("bw matches exact host",
              Bitwarden.domainMatches(pageHost: "example.com", uri: "https://example.com/login"))
        check("bw matches subdomain",
              Bitwarden.domainMatches(pageHost: "mail.example.com", uri: "https://example.com"))
        check("bw REJECTS look-alike suffix",
              !Bitwarden.domainMatches(pageHost: "example.com.evil.net",
                                       uri: "https://example.com"))
        check("bw REJECTS unrelated host",
              !Bitwarden.domainMatches(pageHost: "evil.net", uri: "https://example.com"))
        let cred = Bitwarden.Credential(name: "n", username: "u\"'\\",
                                        password: "p</script>\n\"", uris: [])
        let fill = Bitwarden.fillScript(cred, expectedHost: "example.com")
        check("bw fill escapes quotes/newlines safely",
              !fill.contains("p</script>\n"), "password JSON-encoded")
        check("bw fill checks origin and https",
              fill.contains("location.hostname !==") && fill.contains("location.protocol"))
        check("bw fill never submits", !fill.contains(".submit()"))
        check("bw status without CLI/session is not .ready",
              { if case .ready = Bitwarden.status() { return false } else { return true } }())

        // --- dark mode ---
        check("dark mode un-inverts media",
              DarkMode.css.contains("img") && DarkMode.css.contains("video"))

        // --- reading a tab's memory must never spawn a subprocess ---
        // /usr/bin/footprint costs ~226 ms. currentBytes used to call it on every read,
        // roughly 8 times per UI tick, which dropped a quarter of frames while scrolling.
        let perfTab = Tab(id: 99, url: URL(string: "https://example.com")!)
        perfTab.cachedBytes = 123 * 1024 * 1024
        let t0 = Date()
        var acc: Int64 = 0
        for _ in 0..<1000 { acc &+= perfTab.currentBytes }
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        check("1000 currentBytes reads are free (no process spawn)",
              elapsedMs < 50 && acc > 0,
              String(format: "%.2f ms for 1000 reads", elapsedMs))
        check("currentBytes returns the cached sample",
              perfTab.currentBytes == 123 * 1024 * 1024)

        // --- tab row shows which tab is active ---
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        let rowTab = Tab(id: 0, url: URL(string: "https://example.com")!)
        row.configure(rowTab, isCurrent: false)
        let unselected = row.isCurrent
        row.configure(rowTab, isCurrent: true)
        check("tab row reflects selection", !unselected && row.isCurrent,
              "no highlight meant clicks looked like no-ops")

        // --- reload must re-render the new tab page, not about:blank ---
        let ntabReload = Tab(id: 700, url: NewTabPage.url())
        check("new tab page is detected for reload",
              NewTabPage.isNewTab(ntabReload.url))
        check("about:blank is treated as the new tab page, so reload re-renders it",
              NewTabPage.isNewTab(URL(string: "about:blank")))
        check("a real page reloads normally",
              !NewTabPage.isNewTab(URL(string: "https://example.com/page")))

        // --- loading state drives the spinner ---
        let spinTab = Tab(id: 701, url: URL(string: "https://example.com")!)
        check("a tab starts not loading", !spinTab.isLoading)
        spinTab.isLoading = true
        let item = TabStripView.Item(id: spinTab.id, title: spinTab.title,
                                     state: spinTab.state, bytes: 0, isCurrent: true,
                                     pinned: false, isLoading: spinTab.isLoading)
        check("tab strip item carries the loading flag", item.isLoading)

        // --- per-site dark mode exclusions ---
        let origExcl = Prefs.darkExcludedHosts
        Prefs.darkExcludedHosts = []
        Prefs.setDarkExcluded(true, host: "cas.apu.edu")
        check("an excluded host is recognised", Prefs.isDarkExcluded(host: "cas.apu.edu"))
        check("subdomains of an excluded host are excluded",
              Prefs.isDarkExcluded(host: "sub.cas.apu.edu"))
        check("unrelated hosts are not excluded", !Prefs.isDarkExcluded(host: "apu.edu"))
        check("a look-alike suffix is not excluded",
              !Prefs.isDarkExcluded(host: "cas.apu.edu.evil.net"))
        Prefs.setDarkExcluded(false, host: "cas.apu.edu")
        check("exclusion can be removed", !Prefs.isDarkExcluded(host: "cas.apu.edu"))
        Prefs.darkExcludedHosts = origExcl

        // --- user agent ---
        check("UA carries a Safari product token",
              UserAgent.applicationName.contains("Safari/")
                && UserAgent.applicationName.contains("Version/"),
              UserAgent.applicationName)
        check("UA version comes from the installed Safari",
              !UserAgent.safariVersion.isEmpty, "Safari \(UserAgent.safariVersion)")

        // --- password generator ---
        var opts = PasswordGenerator.Options()
        opts.length = 24
        let pw = PasswordGenerator.generate(opts)
        check("generates the requested length", pw.count == 24, "\(pw.count) chars")
        check("two runs differ", PasswordGenerator.generate(opts) != pw)
        opts.avoidAmbiguous = true
        let clean = PasswordGenerator.generate(opts)
        check("avoids ambiguous characters when asked",
              !clean.contains(where: { PasswordGenerator.ambiguous.contains($0) }), clean)
        opts = PasswordGenerator.Options()
        opts.upper = false; opts.lower = false; opts.special = false; opts.digits = true
        let digitsOnly = PasswordGenerator.generate(opts)
        check("honours the character classes",
              digitsOnly.allSatisfy { $0.isNumber }, digitsOnly)
        opts = PasswordGenerator.Options()
        opts.minDigits = 3
        let withDigits = PasswordGenerator.generate(opts)
        check("meets the digit minimum",
              withDigits.filter { $0.isNumber }.count >= 3, withDigits)
        // Distribution sanity: a biased generator shows up as missing values.
        var seen = Set<Character>()
        var only = PasswordGenerator.Options(); only.upper = false; only.lower = false
        only.special = false; only.length = 200
        for _ in 0..<20 { seen.formUnion(PasswordGenerator.generate(only)) }
        check("digit generation covers the whole range", seen.count == 10,
              "\(seen.count)/10 digits seen")
        check("entropy estimate is sane",
              PasswordGenerator.entropyBits(PasswordGenerator.Options()) > 100,
              "\(PasswordGenerator.entropyBits(PasswordGenerator.Options())) bits")

        // --- layout preference round-trips ---
        let origVertical = Prefs.verticalTabs
        Prefs.verticalTabs = true
        check("vertical tabs preference persists", Prefs.verticalTabs)
        Prefs.verticalTabs = false
        check("horizontal tabs preference persists", !Prefs.verticalTabs)
        Prefs.verticalTabs = origVertical

        // --- the new tab page must not become the tab's identity ---
        let ntab = Tab(id: 600, url: NewTabPage.url())
        check("new tab is titled 'New Tab', not a data URL", ntab.title == "New Tab",
              ntab.title)
        check("new tab url is a sentinel, not a percent-encoded document",
              !ntab.url.absoluteString.hasPrefix("data:")
                && ntab.url.absoluteString.count < 40, ntab.url.absoluteString)
        check("about:blank is recognised as the new tab page",
              NewTabPage.isNewTab(URL(string: "about:blank")))
        check("a real page is not mistaken for the new tab page",
              !NewTabPage.isNewTab(URL(string: "https://example.com")))

        // --- preferences persist and seed new tabs ---
        let originalDefault = Prefs.darkByDefault
        Prefs.darkByDefault = true
        check("a new tab inherits the dark-by-default preference",
              Tab(id: 500, url: URL(string: "https://example.com")!).darkMode)
        Prefs.darkByDefault = false
        check("clearing the preference stops seeding new tabs",
              !Tab(id: 501, url: URL(string: "https://example.com")!).darkMode)
        Prefs.darkByDefault = originalDefault

        let originalBudget = Prefs.budgetMB
        Prefs.budgetMB = 2345
        check("budget persists across reads", Prefs.budgetMB == 2345,
              "\(Prefs.budgetMB) MB")
        Prefs.budgetMB = originalBudget

        // --- Dark Reader bridge ---
        check(DarkReaderBridge.isAvailable
                ? "Dark Reader library detected and used"
                : "dark mode falls back cleanly when Dark Reader is absent",
              !DarkReaderBridge.isAvailable
                ? DarkReaderBridge.effectiveToggleJS() == DarkMode.toggleJS
                : DarkReaderBridge.effectiveToggleJS().contains("DarkReader.enable"),
              DarkReaderBridge.modeDescription)

        // --- tab switching: the exact bug that broke the UI ---
        // A tab that is already LIVE but detached must re-attach when re-selected.
        // promote() short-circuits on `target > state`, so this needs ensureAttached.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let win = NSWindow(contentRect: container.frame, styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.contentView = container
        var switchTabs: [Tab] = []
        for i in 0..<3 {
            let t = Tab(id: i, url: URL(string: "https://example\(i).invalid/")!)
            t.promote(to: .live, in: container)
            switchTabs.append(t)
        }
        func show(_ tab: Tab) {
            for other in switchTabs where other.id != tab.id {
                other.webView?.removeFromSuperview()
            }
            tab.promote(to: .live, in: container)
            tab.ensureAttached(to: container)
        }
        show(switchTabs[0])
        check("tab 0 attached after first select",
              switchTabs[0].webView?.superview === container)
        show(switchTabs[2])
        check("switching to tab 2 attaches it",
              switchTabs[2].webView?.superview === container)
        check("tab 0 detached after switching away",
              switchTabs[0].webView?.superview == nil)
        show(switchTabs[0])
        check("switching BACK to an already-LIVE tab re-attaches it",
              switchTabs[0].webView?.superview === container,
              "this is the bug that broke tab switching")
        check("exactly one web view attached at a time",
              container.subviews.filter { $0 is WKWebView }.count == 1,
              "\(container.subviews.filter { $0 is WKWebView }.count) attached")

        // --- does WebKit actually accept the rules? Its compiler rejects malformed
        // url-filter regexes, which JSON validity alone will not catch.
        var done = false
        ContentBlocker.compile { list in
            check("WebKit compiles the blocklist", list != nil)
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if !done { check("WebKit compiles the blocklist", false, "timed out") }

        print("\n\(failures == 0 ? "all checks passed" : "\(failures) FAILURES")")
        exit(failures == 0 ? 0 : 1)
    }
}
