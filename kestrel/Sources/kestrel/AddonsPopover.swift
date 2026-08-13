import AppKit

/// The add-ons popover: the Firefox add-ons that are installed, and a way to install more.
///
/// It used to list six of Kestrel's own features dressed as extensions — an ad blocker,
/// dark mode, userscripts, a password manager, a tab reloader, a screenshot tool — because
/// there was no extension runtime and those were the nearest thing. There is one now, and
/// every one of those six exists as a real Firefox add-on that runs here, so the
/// imitations were deleted rather than left to compete with the real thing.
final class AddonsPopoverController: NSViewController {

    weak var browser: BrowserWindowController?
    static let width: CGFloat = 360
    private static let rowH: CGFloat = 54
    private static let headerH: CGFloat = 44
    private static let footerH: CGFloat = 172

    /// Sized to its content. A fixed height drew the footer over the last row, which is
    /// the bug the layout test was originally written for.
    static func preferredHeight(rows: Int) -> CGFloat {
        headerH + CGFloat(max(1, rows)) * rowH + footerH
    }

    private let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                                   height: preferredHeight(rows: 1)))

    override func loadView() { view = contentView }

    init(browser: BrowserWindowController?) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    /// Rebuilds the whole popover. There is only one pane now, so "show" and "refresh"
    /// are the same operation.
    func showRoot() {
        let installed = ExtensionStore.installed()
        let h = Self.preferredHeight(rows: installed.count)
        contentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: h)
        preferredContentSize = contentView.frame.size

        let v = NSView(frame: contentView.bounds)
        var y = v.bounds.height - 30

        let title = NSTextField(labelWithString: "Add-ons")
        title.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 22)
        title.alignment = .center
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        v.addSubview(title)

        let rule = NSBox(frame: NSRect(x: 12, y: y - 12, width: v.bounds.width - 24, height: 1))
        rule.boxType = .separator
        v.addSubview(rule)
        y -= 26

        if !ExtensionStore.isSupportedOS {
            y -= 44
            let none = NSTextField(wrappingLabelWithString:
                "WebKit's extension runtime ships with macOS 15.4. This Mac is older, so "
                + "add-ons cannot run here.")
            none.frame = NSRect(x: 16, y: y, width: v.bounds.width - 32, height: 40)
            none.alignment = .center
            none.font = .systemFont(ofSize: 11)
            none.textColor = .secondaryLabelColor
            v.addSubview(none)
        } else if installed.isEmpty {
            y -= 44
            let none = NSTextField(labelWithString: "No add-ons installed")
            none.frame = NSRect(x: 0, y: y + 12, width: v.bounds.width, height: 20)
            none.alignment = .center
            none.font = .systemFont(ofSize: 13)
            none.textColor = .secondaryLabelColor
            v.addSubview(none)
        }

        // One row per add-on: click the name to run it, which is what makes hiding it
        // from the toolbar a real option rather than a way to lose track of it.
        for ext in installed {
            y -= Self.rowH
            let row = ExtensionRow(frame: NSRect(x: 8, y: y, width: v.bounds.width - 16,
                                                 height: 48))
            row.configure(name: ext.name, subtitle: subtitle(for: ext),
                          enabled: Prefs.isExtensionEnabled(ext.id),
                          inToolbar: Prefs.isExtensionInToolbar(ext.id))
            row.onRun = { [weak self] anchor in self?.run(ext, from: anchor) }
            row.onToggle = { [weak self] want in self?.setExtension(ext, enabled: want) }
            row.onOptions = { [weak self] in self?.openOptions(ext) }
            row.onRemove = { [weak self] in self?.remove(ext) }
            row.onToolbar = { [weak self] show in
                Prefs.setExtensionInToolbar(show, id: ext.id)
                self?.browser?.refreshExtensionButtons()
                self?.showRoot()
            }
            v.addSubview(row)
        }

        y -= 26
        AddonStyle.wideButton("Install add-on\u{2026}", in: v, y: y, target: self,
                              action: #selector(install))
        y -= 34
        AddonStyle.wideButton("Open add-ons folder", in: v, y: y, target: self,
                              action: #selector(openFolder))

        let sep = NSBox(frame: NSRect(x: 12, y: 78, width: v.bounds.width - 24, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)

        let note = NSTextField(wrappingLabelWithString:
            "Firefox add-ons are WebExtensions, and WebKit runs them natively since "
            + "macOS 15.4 — so an .xpi installs and runs here without a compatibility "
            + "layer. Gecko-only pieces (sidebars, themes, container tabs) do not, and "
            + "each add-on says which of those it uses before you enable it.")
        note.frame = NSRect(x: 16, y: 8, width: v.bounds.width - 32, height: 62)
        note.alignment = .center
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)

        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.addSubview(v)
    }

    private func subtitle(for ext: ExtensionStore.Installed) -> String {
        let base = "v\(ext.version) · MV\(ext.manifestVersion)"
        if let err = loadError(ext.id) { return "failed: \(err)" }
        if !Prefs.isExtensionEnabled(ext.id) { return base + " · off" }
        if !Prefs.isExtensionInToolbar(ext.id) { return base + " · hidden from toolbar" }
        let gaps = ExtensionStore.gaps(in: ext)
        return gaps.isEmpty ? base : base + " · no " + gaps.joined(separator: ", ")
    }

    private func loadError(_ id: String) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        return MainActor.assumeIsolated { ExtensionRuntime.shared.loadErrors[id] }
    }

    // MARK: - actions

    private func run(_ ext: ExtensionStore.Installed, from anchor: NSView) {
        guard Prefs.isExtensionEnabled(ext.id) else {
            browser?.flash("\(ext.name) is turned off")
            return
        }
        browser?.openExtensionAction(id: ext.id, from: anchor)
    }

    private func setExtension(_ ext: ExtensionStore.Installed, enabled: Bool) {
        if enabled {
            guard browser?.confirmPermissions(for: ext) == true else { showRoot(); return }
            Prefs.setExtensionEnabled(true, id: ext.id)
            browser?.enableExtension(ext)
        } else {
            browser?.disableExtension(ext)
        }
        showRoot()
    }

    private func openOptions(_ ext: ExtensionStore.Installed) {
        guard #available(macOS 15.4, *) else { return }
        MainActor.assumeIsolated {
            guard let url = ExtensionRuntime.shared.contexts[ext.id]?.optionsPageURL else {
                browser?.flash("\(ext.name) has no options page")
                return
            }
            _ = browser?.openExtensionPage(url)
        }
    }

    /// Uninstalling is destructive and stray clicks happen, so it asks first.
    private func remove(_ ext: ExtensionStore.Installed) {
        let a = NSAlert()
        a.messageText = "Remove \(ext.name)?"
        a.informativeText = "Its files and any data it stored are deleted."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        browser?.disableExtension(ext)
        ExtensionStore.remove(ext)
        browser?.refreshExtensionButtons()
        showRoot()
    }

    @objc private func install() {
        browser?.installExtension()
        showRoot()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(ExtensionStore.dir)
    }
}

/// A row for one installed Firefox add-on: click the name to run it, a switch to turn it
/// on or off, and a checkbox for whether it takes a slot in the toolbar.
///
/// The click target matters more than it looks. Hiding an add-on from the toolbar is only
/// a real option if there is somewhere else to click it, otherwise "hidden" means "lost".
final class ExtensionRow: NSView {
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let onOff = NSSwitch()
    private let toolbar = NSButton(checkboxWithTitle: "Toolbar", target: nil, action: nil)
    private var hovering = false { didSet { needsDisplay = true } }

    var onRun: ((NSView) -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onToolbar: ((Bool) -> Void)?
    var onOptions: (() -> Void)?
    var onRemove: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.frame = NSRect(x: 12, y: frame.height - 26, width: frame.width - 70, height: 18)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        addSubview(name)

        onOff.frame = NSRect(x: frame.width - 52, y: frame.height - 30, width: 40, height: 22)
        onOff.target = self
        onOff.action = #selector(switched)
        addSubview(onOff)

        toolbar.font = .systemFont(ofSize: 10.5)
        toolbar.frame = NSRect(x: 0, y: 2, width: toolbar.fittingSize.width.rounded(.up),
                               height: 18)
        toolbar.frame.origin.x = frame.width - 12 - toolbar.frame.width
        toolbar.target = self
        toolbar.action = #selector(toolbarChanged)
        addSubview(toolbar)

        // Stops short of the Toolbar checkbox rather than running the full width: the
        // two share the row's second line.
        subtitle.frame = NSRect(x: 12, y: frame.height - 44,
                                width: toolbar.frame.minX - 20, height: 16)
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)

        let m = NSMenu()
        for (t, sel) in [("Options", #selector(optionsPicked)),
                         ("Remove\u{2026}", #selector(removePicked))] {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        menu = m
    }
    required init?(coder: NSCoder) { nil }

    func configure(name n: String, subtitle s: String, enabled: Bool, inToolbar: Bool) {
        name.stringValue = n
        subtitle.stringValue = s
        onOff.state = enabled ? .on : .off
        toolbar.state = inToolbar ? .on : .off
        toolbar.isEnabled = enabled
        toolTip = enabled ? "Click to open \(n)" : "\(n) is turned off"
    }

    @objc private func switched() { onToggle?(onOff.state == .on) }
    @objc private func toolbarChanged() { onToolbar?(toolbar.state == .on) }
    @objc private func optionsPicked() { onOptions?() }
    @objc private func removePicked() { onRemove?() }

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

    /// Only the name area runs the add-on; the controls handle their own clicks.
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard p.x < bounds.width - 60 else { return }
        onRun?(self)
    }
}
