import AppKit

/// The add-ons popover: a list of Kestrel's built-in "extensions", each opening its own
/// detail pane — the shape Chrome, Brave and Firefox all converged on.
///
/// These are not real extensions and the UI should not pretend otherwise: there is no
/// extension runtime here, no store, and nothing to install. They are the browser's own
/// features presented in the place people look for them.
final class AddonsPopoverController: NSViewController {

    struct Addon {
        let id: String
        let name: String
        let symbol: String
        let tint: NSColor
        let status: () -> String
        let available: () -> Bool
    }

    weak var browser: BrowserWindowController?
    private var stack: [NSView] = []
    private var darkTab = 0
    private var bwTab = 0
    private var genOptions = PasswordGenerator.Options()
    private weak var generatedField: NSTextField?
    private weak var entropyLabel: NSTextField?
    private weak var lengthLabel: NSTextField?
    static let width: CGFloat = 360
    private static let rowH: CGFloat = 62
    private static let headerH: CGFloat = 68
    private static let footerH: CGFloat = 54

    /// Sized to its content: six rows at 62 pt plus header and footer overflowed a
    /// fixed 460 pt popover and drew the note on top of the last row.
    static func preferredHeight(rows: Int) -> CGFloat {
        headerH + CGFloat(rows) * rowH + footerH
    }

    private let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                                   height: preferredHeight(rows: 6)))

    override func loadView() { view = contentView }

    init(browser: BrowserWindowController?) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    var addons: [Addon] {
        [
            Addon(id: "adblock", name: "Ad Blocker", symbol: "shield.lefthalf.filled",
                  tint: .systemRed,
                  status: {
                      let custom = ContentBlocker.customStats?.blocked ?? 0
                      return "\(ContentBlocker.ruleCount + custom) rules active"
                  },
                  available: { ContentBlocker.compiled != nil }),
            Addon(id: "darkreader", name: "Dark Reader", symbol: "circle.lefthalf.filled",
                  tint: .systemIndigo,
                  status: { DarkReaderBridge.isAvailable
                              ? "Dynamic theme engine" : "Built-in filter fallback" },
                  available: { true }),
            Addon(id: "userscripts", name: "Userscripts", symbol: "curlybraces",
                  tint: .systemTeal,
                  status: { "\(UserScriptStore.loadAll().count) script(s) loaded" },
                  available: { true }),
            Addon(id: "bitwarden", name: "Bitwarden", symbol: "lock.shield",
                  tint: .systemBlue,
                  status: { Bitwarden.status().shortLabel },
                  available: { if case .ready = Bitwarden.status() { return true }; return false }),
            Addon(id: "refresh", name: "Tab Reloader", symbol: "arrow.clockwise.circle",
                  tint: .systemOrange,
                  status: { [weak self] in
                      guard let i = self?.browser?.currentTab?.refreshInterval
                      else { return "Off for this tab" }
                      return "Every \(Int(i))s — tab pinned LIVE"
                  },
                  available: { true }),
            Addon(id: "capture", name: "Screenshot", symbol: "camera.viewfinder",
                  tint: .systemGreen,
                  status: { "Page, region, element, PDF" },
                  available: { true }),
        ]
    }

    // MARK: - root list

    func showRoot() {
        // Resize to fit before laying out, in case the add-on list changed.
        let h = Self.preferredHeight(rows: addons.count)
        contentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: h)
        preferredContentSize = contentView.frame.size
        let v = NSView(frame: contentView.bounds)
        var y = v.bounds.height - 44

        let title = NSTextField(labelWithString: "Add-ons")
        title.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 22)
        title.alignment = .center
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        v.addSubview(title)

        let rule = NSBox(frame: NSRect(x: 12, y: y - 10, width: v.bounds.width - 24, height: 1))
        rule.boxType = .separator
        v.addSubview(rule)
        y -= 24

        for addon in addons {
            y -= 62
            let row = AddonRow(frame: NSRect(x: 8, y: y, width: v.bounds.width - 16, height: 58))
            row.configure(addon)
            row.onOpen = { [weak self] in self?.showDetail(addon) }
            v.addSubview(row)
        }

        let sep = NSBox(frame: NSRect(x: 12, y: Self.footerH - 8,
                                      width: v.bounds.width - 24, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)

        let note = NSTextField(wrappingLabelWithString:
            "Kestrel's own features, not installable extensions — there is no extension "
            + "runtime here.")
        note.frame = NSRect(x: 14, y: 8, width: v.bounds.width - 28, height: 32)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)

        push(v, animated: false)
    }

    // MARK: - detail panes

    /// Test hook: drive a detail pane without a click.
    func openForTest(_ addon: Addon) { showDetail(addon) }

    private func showDetail(_ addon: Addon) {
        let h = Self.preferredHeight(rows: addons.count)
        contentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: h)
        let v = NSView(frame: contentView.bounds)

        // One header, not two: the back control carries the icon and title, so the
        // panes below it start straight into content.
        let back = NSButton(title: "", target: self, action: #selector(pop))
        back.frame = NSRect(x: 8, y: v.bounds.height - 40, width: 30, height: 28)
        back.isBordered = false
        if let img = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back") {
            img.isTemplate = true
            back.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        }
        v.addSubview(back)

        let icon = NSImageView(frame: NSRect(x: 42, y: v.bounds.height - 39, width: 24, height: 24))
        if let img = NSImage(systemSymbolName: addon.symbol, accessibilityDescription: addon.name) {
            img.isTemplate = true
            icon.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
            icon.contentTintColor = addon.tint
        }
        v.addSubview(icon)

        let title = NSTextField(labelWithString: addon.name)
        title.frame = NSRect(x: 72, y: v.bounds.height - 38, width: v.bounds.width - 88, height: 22)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        v.addSubview(title)

        let rule = NSBox(frame: NSRect(x: 12, y: v.bounds.height - 50,
                                       width: v.bounds.width - 24, height: 1))
        rule.boxType = .separator
        v.addSubview(rule)

        let body = NSView(frame: NSRect(x: 0, y: 0, width: v.bounds.width,
                                        height: v.bounds.height - 54))
        v.addSubview(body)

        switch addon.id {
        case "darkreader":  buildDarkReader(in: body)
        case "adblock":     buildAdBlock(in: body)
        case "userscripts": buildUserScripts(in: body)
        case "bitwarden":   buildBitwarden(in: body)
        case "refresh":     buildRefresh(in: body)
        case "capture":     buildCapture(in: body)
        default: break
        }
        push(v, animated: true)
    }

    /// Human label for the current page, so panes don't say "newtab".
    private var siteLabel: String {
        guard let tab = browser?.currentTab else { return "no page" }
        if NewTabPage.isNewTab(tab.url) { return "the new tab page" }
        return tab.url.host ?? tab.url.absoluteString
    }

    private func buildDarkReader(in v: NSView) {
        var y = v.bounds.height - 40
        y = AddonStyle.banner("Dark Reader", tint: .systemIndigo, in: v, y: y)

        // Site button and On/Off, side by side, each half the pane.
        let half = (v.bounds.width - 40) / 2
        let site = NSButton(title: "\u{2713} " + siteLabel, target: self,
                            action: #selector(darkApply))
        site.frame = NSRect(x: 16, y: y, width: half, height: 26)
        site.bezelStyle = .rounded
        site.font = .systemFont(ofSize: 11.5)
        v.addSubview(site)

        let onOff = NSSegmentedControl(labels: ["On", "Off"], trackingMode: .selectOne,
                                       target: self, action: #selector(darkToggled(_:)))
        onOff.frame = NSRect(x: 24 + half, y: y, width: half, height: 26)
        onOff.selectedSegment = (browser?.currentTab?.darkMode ?? false) ? 0 : 1
        v.addSubview(onOff)
        y -= 18
        AddonStyle.caption("Configure website toggling", in: v, y: y, x: 16, width: half)
        AddonStyle.caption("Configure automation", in: v, y: y, x: 24 + half, width: half)
        y -= 22

        y = AddonStyle.tabs(["Filter", "Site list", "More"], selected: darkTab, in: v, y: y,
                            target: self, action: #selector(darkTabChanged(_:)))

        switch darkTab {
        case 1:
            let host = browser?.currentTab?.url.host
            let excluded = Prefs.isDarkExcluded(host: host)
            let toggle = NSButton(checkboxWithTitle: "Never use dark mode on \(siteLabel)",
                                  target: self, action: #selector(darkExcludeToggled(_:)))
            toggle.frame = NSRect(x: (v.bounds.width - 280) / 2, y: y - 6,
                                  width: 280, height: 20)
            toggle.state = excluded ? .on : .off
            toggle.isEnabled = host != nil
            v.addSubview(toggle)
            y -= 36

            y = AddonStyle.section("Excluded sites", in: v, y: y)
            let list = Prefs.darkExcludedHosts.sorted()
            if list.isEmpty {
                let none = NSTextField(labelWithString: "none")
                none.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 16)
                none.alignment = .center
                none.font = .systemFont(ofSize: 11)
                none.textColor = .tertiaryLabelColor
                v.addSubview(none)
            } else {
                for h in list.prefix(7) {
                    let row = NSTextField(labelWithString: h)
                    row.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 16)
                    row.alignment = .center
                    row.font = .systemFont(ofSize: 11)
                    v.addSubview(row)
                    y -= 20
                }
            }

            let why = NSTextField(wrappingLabelWithString:
                "Some pages theme badly — custom form controls and accent colours can be "
                + "lost. Excluding a site is more reliable than fighting the theming.")
            why.frame = NSRect(x: 16, y: 46, width: v.bounds.width - 32, height: 50)
            why.alignment = .center
            why.font = .systemFont(ofSize: 9.5)
            why.textColor = .tertiaryLabelColor
            v.addSubview(why)
        case 2:
            let def = NSButton(checkboxWithTitle: "Enable on every site by default",
                               target: self, action: #selector(darkDefaultToggled(_:)))
            def.frame = NSRect(x: (v.bounds.width - 240) / 2, y: y - 8, width: 240, height: 20)
            def.state = Prefs.darkByDefault ? .on : .off
            v.addSubview(def)
            y -= 44
            AddonStyle.wideButton("Reset filter to defaults", in: v, y: y, target: self,
                                  action: #selector(darkReset))
        default:
            for (title, key, value, setter) in
                [("Brightness", "brightness", Prefs.drBrightness, 0),
                 ("Contrast", "contrast", Prefs.drContrast, 1),
                 ("Sepia", "sepia", Prefs.drSepia, 2),
                 ("Grayscale", "grayscale", Prefs.drGrayscale, 3)] {
                y = AddonStyle.barSlider(title, value: value, tint: .systemIndigo, in: v,
                                         y: y, target: self,
                                         stepAction: #selector(darkStep(_:)), key: key) { v in
                    switch setter {
                    case 0: Prefs.drBrightness = v
                    case 1: Prefs.drContrast = v
                    case 2: Prefs.drSepia = v
                    default: Prefs.drGrayscale = v
                    }
                }
            }
            y -= 4
            AddonStyle.wideButton("Only for \(siteLabel)", in: v, y: y, target: self,
                                  action: #selector(darkApply), prominent: true)
        }

        let engine = NSTextField(wrappingLabelWithString:
            DarkReaderBridge.isAvailable
            ? "Dark Reader \(DarkReaderBridge.version)"
            : "Built-in CSS invert — npm install darkreader for per-colour theming")
        engine.frame = NSRect(x: 16, y: 10, width: v.bounds.width - 32, height: 32)
        engine.alignment = .center
        engine.font = .systemFont(ofSize: 9.5)
        engine.textColor = .tertiaryLabelColor
        v.addSubview(engine)
    }

    private func buildAdBlock(in v: NSView) {
        let host = siteLabel
        var y = v.bounds.height - 40
        y = AddonStyle.banner("Ad Blocker", tint: .systemRed, in: v, y: y)
        y = AddonStyle.section("Block ads on", in: v, y: y)
        y = AddonStyle.toggleRow("This website", subtitle: host,
                                 on: Prefs.isBlockingEnabled(host: host), in: v, y: y,
                                 target: self, action: #selector(adblockSiteToggled(_:)))

        let custom = ContentBlocker.customStats?.blocked ?? 0
        y = AddonStyle.section("Rules active", in: v, y: y - 2)
        y = AddonStyle.statPanel([("built in", "\(ContentBlocker.ruleCount)"),
                                  ("filters.txt", "\(custom)")], in: v, y: y)

        AddonStyle.wideButton("Reload filters.txt", in: v, y: y - 4, target: self,
                              action: #selector(adblockReload))
        AddonStyle.wideButton("Open ~/.kestrel", in: v, y: y - 38, target: self,
                              action: #selector(openKestrelFolder))

        let note = NSTextField(wrappingLabelWithString:
            "Compiled into WebKit rather than run in JavaScript, so blocking costs "
            + "approximately nothing per tab. WebKit does not report what it blocked, "
            + "so there is no per-page count to show.")
        note.frame = NSRect(x: 16, y: 10, width: v.bounds.width - 32, height: 56)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
    }

    private func buildUserScripts(in v: NSView) {
        let scripts = UserScriptStore.loadAll()
        var y = v.bounds.height - 40
        y = AddonStyle.banner("Userscripts", tint: .systemTeal, in: v, y: y)
        let enabled = NSTextField(labelWithString:
            scripts.isEmpty ? "\u{2717}  No script is running"
                            : "\u{2713}  \(scripts.count) script(s) enabled")
        enabled.frame = NSRect(x: 0, y: y - 4, width: v.bounds.width, height: 20)
        enabled.alignment = .center
        enabled.font = .systemFont(ofSize: 13)
        enabled.textColor = scripts.isEmpty ? .secondaryLabelColor : .systemGreen
        v.addSubview(enabled)
        y -= 34

        if !scripts.isEmpty {
            y = AddonStyle.section("Running here", in: v, y: y)
            for s in scripts.prefix(5) {
                let row = NSTextField(labelWithString: s.name)
                row.frame = NSRect(x: 16, y: y, width: v.bounds.width - 32, height: 16)
                row.font = .systemFont(ofSize: 12)
                v.addSubview(row)
                let m = NSTextField(labelWithString: s.matches.joined(separator: ", "))
                m.frame = NSRect(x: 16, y: y - 14, width: v.bounds.width - 32, height: 14)
                m.font = .systemFont(ofSize: 9.5)
                m.textColor = .tertiaryLabelColor
                m.lineBreakMode = .byTruncatingTail
                v.addSubview(m)
                y -= 32
            }
        }

        y -= 6
        for (title, sel) in [("Create a new script\u{2026}", #selector(scriptsNew)),
                             ("Open scripts folder", #selector(openScriptsFolder)),
                             ("Dashboard\u{2026}", #selector(scriptsDashboard))] {
            AddonStyle.wideButton(title, in: v, y: y, target: self, action: sel)
            y -= 34
        }

        let note = NSTextField(wrappingLabelWithString:
            "*.user.js in ~/.kestrel/userscripts/ with @name, @match and @run-at. "
            + "Reopen a tab to apply changes.")
        note.frame = NSRect(x: 16, y: 10, width: v.bounds.width - 32, height: 44)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
    }

    private func buildBitwarden(in v: NSView) {
        var y = v.bounds.height - 40
        y = AddonStyle.banner("Bitwarden", tint: .systemBlue, in: v, y: y)

        switch bwTab {
        case 1:  buildGenerator(in: v, from: y)
        default: buildVaultPane(in: v, from: y)
        }
        buildBWTabBar(in: v)
    }

    /// Bottom tab bar: Vault | Generator | Send | Settings.
    private func buildBWTabBar(in v: NSView) {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: v.bounds.width, height: 46))
        let sep = NSBox(frame: NSRect(x: 0, y: 45, width: v.bounds.width, height: 1))
        sep.boxType = .separator
        bar.addSubview(sep)

        let items: [(String, String)] = [("Vault", "lock.square"),
                                         ("Generator", "arrow.triangle.2.circlepath"),
                                         ("Send", "paperplane"),
                                         ("Settings", "gearshape")]
        let w = v.bounds.width / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(bwTabChanged(_:)))
            b.frame = NSRect(x: CGFloat(i) * w, y: 4, width: w, height: 38)
            b.isBordered = false
            b.tag = i
            b.imagePosition = .imageAbove
            if let img = NSImage(systemSymbolName: item.1, accessibilityDescription: item.0) {
                img.isTemplate = true
                b.image = img.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            }
            b.title = item.0
            b.font = .systemFont(ofSize: 9.5)
            b.contentTintColor = i == bwTab ? .controlAccentColor : .secondaryLabelColor
            // Send and Settings are not implemented; disable rather than pretend.
            b.isEnabled = i < 2
            bar.addSubview(b)
        }
        v.addSubview(bar)
    }

    private func buildVaultPane(in v: NSView, from top: CGFloat) {
        var y = top
        let status = Bitwarden.status()
        let ready: Bool
        if case .ready = status { ready = true } else { ready = false }

        let badge = NSTextField(labelWithString:
            ready ? "\u{2713}  Vault unlocked" : "\u{1F512}  " + status.shortLabel)
        badge.frame = NSRect(x: 0, y: y - 4, width: v.bounds.width, height: 20)
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 13, weight: .medium)
        badge.textColor = ready ? .systemGreen : .systemOrange
        v.addSubview(badge)
        y -= 36

        y = AddonStyle.section("This page", in: v, y: y)
        let hostLabel = NSTextField(labelWithString: siteLabel)
        hostLabel.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 18)
        hostLabel.alignment = .center
        hostLabel.font = .systemFont(ofSize: 12)
        v.addSubview(hostLabel)
        y -= 36

        let fill = AddonStyle.wideButton("Fill password", in: v, y: y, target: self,
                                         action: #selector(bwFill), prominent: ready)
        fill.isEnabled = ready
        y -= 40

        let readyText = "A credential is only offered when the page's domain matches the "
            + "URI saved on the vault item, over HTTPS, and only when you ask. "
            + "Filling never submits the form."
        let note = NSTextField(wrappingLabelWithString: ready ? readyText : status.message)
        note.frame = NSRect(x: 16, y: 56, width: v.bounds.width - 32, height: max(40, y - 56))
        note.alignment = .center
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        v.addSubview(note)
    }

    private func buildGenerator(in v: NSView, from top: CGFloat) {
        var y = top

        let out = NSTextField(string: PasswordGenerator.generate(genOptions))
        out.frame = NSRect(x: 16, y: y - 6, width: v.bounds.width - 32, height: 30)
        out.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        out.alignment = .center
        out.isEditable = false
        out.isSelectable = true
        out.identifier = NSUserInterfaceItemIdentifier("gen-out")
        v.addSubview(out)
        generatedField = out
        y -= 44

        let bits = NSTextField(labelWithString:
            "\(PasswordGenerator.entropyBits(genOptions)) bits of entropy")
        bits.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 14)
        bits.alignment = .center
        bits.font = .systemFont(ofSize: 9.5)
        bits.textColor = .tertiaryLabelColor
        bits.identifier = NSUserInterfaceItemIdentifier("gen-bits")
        v.addSubview(bits)
        entropyLabel = bits
        y -= 26

        // Length
        let lenLabel = NSTextField(labelWithString: "Length")
        lenLabel.frame = NSRect(x: 16, y: y, width: 70, height: 18)
        lenLabel.font = .systemFont(ofSize: 11.5)
        v.addSubview(lenLabel)
        let stepper = NSStepper(frame: NSRect(x: v.bounds.width - 40, y: y - 2,
                                              width: 20, height: 22))
        stepper.minValue = 5; stepper.maxValue = 128
        stepper.integerValue = genOptions.length
        stepper.target = self; stepper.action = #selector(genLength(_:))
        v.addSubview(stepper)
        let lenValue = NSTextField(labelWithString: "\(genOptions.length)")
        lenValue.frame = NSRect(x: v.bounds.width - 86, y: y, width: 40, height: 18)
        lenValue.alignment = .right
        lenValue.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        lenValue.identifier = NSUserInterfaceItemIdentifier("gen-len")
        v.addSubview(lenValue)
        lengthLabel = lenValue
        y -= 30

        y = AddonStyle.section("Include", in: v, y: y)
        let cols: [(String, Int, Bool)] = [("A-Z", 0, genOptions.upper),
                                           ("a-z", 1, genOptions.lower),
                                           ("0-9", 2, genOptions.digits),
                                           ("!@#$", 3, genOptions.special)]
        for (i, c) in cols.enumerated() {
            let b = NSButton(checkboxWithTitle: c.0, target: self,
                             action: #selector(genToggle(_:)))
            b.frame = NSRect(x: 16 + CGFloat(i) * ((v.bounds.width - 32) / 4),
                             y: y, width: (v.bounds.width - 32) / 4, height: 20)
            b.tag = c.1
            b.state = c.2 ? .on : .off
            b.font = .systemFont(ofSize: 11)
            v.addSubview(b)
        }
        y -= 32

        let amb = NSButton(checkboxWithTitle: "Avoid ambiguous characters",
                           target: self, action: #selector(genToggle(_:)))
        amb.frame = NSRect(x: (v.bounds.width - 220) / 2, y: y, width: 220, height: 20)
        amb.tag = 4
        amb.state = genOptions.avoidAmbiguous ? .on : .off
        amb.font = .systemFont(ofSize: 11)
        v.addSubview(amb)
        y -= 36

        AddonStyle.wideButton("Regenerate", in: v, y: y, target: self,
                              action: #selector(genRegenerate))
        AddonStyle.wideButton("Copy to clipboard", in: v, y: y - 34, target: self,
                              action: #selector(genCopy), prominent: true)

        let note = NSTextField(wrappingLabelWithString:
            "Generated with SecRandomCopyBytes and rejection sampling, so the "
            + "distribution is uniform. Nothing is stored or sent anywhere.")
        note.frame = NSRect(x: 16, y: 54, width: v.bounds.width - 32, height: 40)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
    }

    private func buildRefresh(in v: NSView) {
        var y = v.bounds.height - 44
        let l = NSTextField(labelWithString: "Reload this tab every…")
        l.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 18)
        l.alignment = .center
        l.font = .systemFont(ofSize: 12, weight: .medium)
        v.addSubview(l)
        y -= 30

        for (i, choice) in BrowserWindowController.refreshChoices.enumerated() {
            let b = NSButton(radioButtonWithTitle: choice.0, target: self,
                             action: #selector(refreshPicked(_:)))
            b.frame = NSRect(x: (v.bounds.width - 180) / 2, y: y, width: 180, height: 20)
            b.tag = i
            b.state = (browser?.currentTab?.refreshInterval == choice.1) ? .on : .off
            v.addSubview(b)
            y -= 24
        }

        let note = NSTextField(wrappingLabelWithString:
            "A tab on a refresh timer is a live dashboard, so the scheduler pins it LIVE "
            + "and it pays full memory price. It is the one feature here that costs "
            + "memory rather than saving it.")
        note.frame = NSRect(x: 16, y: 12, width: v.bounds.width - 32, height: 60)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
    }

    private func buildCapture(in v: NSView) {
        var y = v.bounds.height - 44
        // "Then" and "Format" mirror the capture popover so both routes agree.
        for (label, options, initial, sel) in
            [("Then", ["Open in editor", "Save to file", "Copy to clipboard"],
              Prefs.shotThen, #selector(thenChanged(_:))),
             ("Format", ["PNG", "JPEG", "PDF"], Prefs.shotFormat, #selector(formatChanged(_:)))] {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 16, y: y + 2, width: 56, height: 18)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            v.addSubview(l)
            let p = NSPopUpButton(frame: NSRect(x: 76, y: y - 2,
                                                width: v.bounds.width - 92, height: 26))
            p.addItems(withTitles: options)
            p.selectItem(withTitle: initial)
            p.target = self
            p.action = sel
            v.addSubview(p)
            y -= 34
        }
        y -= 6
        for (title, sel) in [("Entire page", #selector(capFull)),
                             ("Visible area", #selector(capVisible)),
                             ("Select region", #selector(capRegion)),
                             ("Pick element", #selector(capElement)),
                             ("Entire page as PDF", #selector(capPDF))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: 16, y: y, width: v.bounds.width - 32, height: 30)
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 12.5)
            v.addSubview(b)
            y -= 34
        }
        let note = NSTextField(wrappingLabelWithString:
            "Full-page capture flattens sticky headers, primes lazy images, and scales "
            + "down anything over 80 megapixels rather than allocating it.")
        note.frame = NSRect(x: 16, y: 12, width: v.bounds.width - 32, height: 48)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)
    }

    // MARK: - navigation

    private func push(_ v: NSView, animated: Bool) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.addSubview(v)
        stack.append(v)
    }

    @objc private func pop() {
        stack.removeLast()
        contentView.subviews.forEach { $0.removeFromSuperview() }
        showRoot()
    }

    // MARK: - actions

    @objc private func darkToggled(_ s: NSSegmentedControl) {
        browser?.toggleDark()
    }
    @objc private func darkDefaultToggled(_ b: NSButton) {
        browser?.toggleDarkByDefault()
    }
    @objc private func darkSlider(_ s: NSSlider) {
        let v = Int(s.doubleValue)
        switch s.identifier?.rawValue {
        case "brightness": Prefs.drBrightness = v
        case "contrast":   Prefs.drContrast = v
        case "sepia":      Prefs.drSepia = v
        case "grayscale":  Prefs.drGrayscale = v
        default: break
        }
        if let id = s.identifier?.rawValue,
           let label = s.superview?.subviews.first(where: {
               $0.identifier?.rawValue == id + "-label" }) as? NSTextField {
            label.stringValue = "\(v)"
        }
    }
    @objc private func darkApply() { browser?.applyDarkSettings() }
    @objc private func darkExcludeToggled(_ b: NSButton) {
        browser?.toggleDarkExclusion()
        if let addon = addons.first(where: { $0.id == "darkreader" }) { showDetail(addon) }
    }
    @objc private func darkTabChanged(_ c: NSSegmentedControl) {
        darkTab = c.selectedSegment
        if let addon = addons.first(where: { $0.id == "darkreader" }) { showDetail(addon) }
    }
    @objc private func darkReset() {
        Prefs.drBrightness = 100; Prefs.drContrast = 90
        Prefs.drSepia = 10; Prefs.drGrayscale = 0
        if let addon = addons.first(where: { $0.id == "darkreader" }) { showDetail(addon) }
        browser?.applyDarkSettings()
    }

    @objc private func adblockSiteToggled(_ s: NSSwitch) {
        guard let host = browser?.currentTab?.url.host else { return }
        Prefs.setBlocking(enabled: s.state == .on, host: host)
        browser?.applySiteBlocking()
    }
    @objc private func adblockReload() { browser?.reloadBlocklist() }
    @objc private func openKestrelFolder() { NSWorkspace.shared.open(Store.dir) }
    @objc private func openScriptsFolder() { NSWorkspace.shared.open(UserScriptStore.dir) }
    @objc private func scriptsDashboard() { browser?.openScriptManager() }
    @objc private func scriptsNew() {
        browser?.openScriptManager()
    }
    @objc private func darkStep(_ b: NSButton) {
        guard let id = b.identifier?.rawValue, let parent = b.superview else { return }
        let up = id.hasSuffix("-up")
        let key = String(id.dropLast(up ? 3 : 5))
        for sub in parent.subviews {
            if sub.identifier?.rawValue == key, let bar = sub as? BarSliderView {
                bar.step(up ? 5 : -5)
            }
        }
        browser?.applyDarkSettings()
    }
    @objc private func scriptsReload() { browser?.reloadUserScripts() }
    @objc private func bwFill() { browser?.bitwardenFill() }

    @objc private func bwTabChanged(_ b: NSButton) {
        bwTab = b.tag
        if let addon = addons.first(where: { $0.id == "bitwarden" }) { showDetail(addon) }
    }
    @objc private func genLength(_ s: NSStepper) {
        genOptions.length = s.integerValue
        lengthLabel?.stringValue = "\(genOptions.length)"
        regenerate()
    }
    @objc private func genToggle(_ b: NSButton) {
        let on = b.state == .on
        switch b.tag {
        case 0: genOptions.upper = on
        case 1: genOptions.lower = on
        case 2: genOptions.digits = on
        case 3: genOptions.special = on
        default: genOptions.avoidAmbiguous = on
        }
        // Never leave every class off — that would generate an empty password.
        if !(genOptions.upper || genOptions.lower || genOptions.digits || genOptions.special) {
            genOptions.lower = true
            b.state = b.tag == 1 ? .on : b.state
        }
        regenerate()
    }
    @objc private func genRegenerate() { regenerate() }
    private func regenerate() {
        generatedField?.stringValue = PasswordGenerator.generate(genOptions)
        entropyLabel?.stringValue =
            "\(PasswordGenerator.entropyBits(genOptions)) bits of entropy"
    }
    @objc private func genCopy() {
        guard let pw = generatedField?.stringValue, !pw.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pw, forType: .string)
        browser?.flash("password copied — \(PasswordGenerator.entropyBits(genOptions)) bits")
    }
    @objc private func refreshPicked(_ b: NSButton) {
        let item = NSMenuItem(); item.tag = b.tag
        browser?.setRefresh(item)
    }
    @objc private func capVisible() { browser?.shotVisible() }
    @objc private func capFull() { browser?.shotFullPage() }
    @objc private func capRegion() { browser?.shotRegion() }
    @objc private func capPDF() { browser?.shotPDF() }
    @objc private func capElement() { browser?.shotElement() }
    @objc private func thenChanged(_ p: NSPopUpButton) {
        Prefs.shotThen = p.titleOfSelectedItem ?? "Open in editor"
    }
    @objc private func formatChanged(_ p: NSPopUpButton) {
        Prefs.shotFormat = p.titleOfSelectedItem ?? "PNG"
    }
}

/// One row in the add-ons list: icon, name, status, chevron.
final class AddonRow: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var onOpen: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.frame = NSRect(x: 10, y: frame.height / 2 - 14, width: 28, height: 28)
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        name.frame = NSRect(x: 50, y: frame.height / 2 + 2, width: frame.width - 80, height: 18)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(name)
        status.frame = NSRect(x: 50, y: frame.height / 2 - 17, width: frame.width - 80, height: 16)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        if let c = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            c.isTemplate = true
            chevron.image = c
            chevron.contentTintColor = .tertiaryLabelColor
        }
        chevron.frame = NSRect(x: frame.width - 24, y: frame.height / 2 - 7, width: 12, height: 14)
        addSubview(chevron)
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ a: AddonsPopoverController.Addon) {
        name.stringValue = a.name
        status.stringValue = a.status()
        if let img = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.name) {
            img.isTemplate = true
            icon.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            icon.contentTintColor = a.available() ? a.tint : .tertiaryLabelColor
        }
        status.textColor = a.available() ? .secondaryLabelColor : .tertiaryLabelColor
        toolTip = a.status()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { onOpen?() }
}
