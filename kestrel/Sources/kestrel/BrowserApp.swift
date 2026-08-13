import AppKit
import WebKit

/// A working tabbed browser whose tabs live on the DESIGN.md §2 ladder, with the budget
/// as a visible, user-settable control (DESIGN.md §7 -- memory as a product surface).
final class BrowserWindowController: NSObject, WKNavigationDelegate, WKUIDelegate,
                                     NSTextFieldDelegate, NSTableViewDataSource,
                                     NSTableViewDelegate {
    let window: NSWindow
    let webContainer = NSView()
    let placeholder = NSImageView()
    let placeholderLabel = NSTextField(labelWithString: "")
    let tabStrip = TabStripView()
    let sidebar = NSScrollView()
    let sidebarTable = NSTableView()
    var urlBar: URLBarView!
    let statusLabel = NSTextField(labelWithString: "")
    let memoryBar = MemoryBar()
    let budgetSlider = NSSlider()
    let budgetLabel = NSTextField(labelWithString: "")
    let capPopup = NSPopUpButton()
    let legend = NSTextField(labelWithString: "")

    public var tabs: [Tab] = []
    var nextId = 0
    var foregroundId = -1
    let scheduler = Scheduler(budgetBytes: Int64(Prefs.budgetMB) * 1024 * 1024,
                              perTabCapBytes: Int64(Prefs.perTabCapMB) * 1024 * 1024,
                              keepLive: 3)
    var timer: Timer?
    private var sampling = false
    var backButton: NSButton?
    var forwardButton: NSButton?
    var qrPanel: NSPanel?
    var qrImage: NSImage?
    var flashUntil = Date.distantPast
    var pendingCreds: ([Bitwarden.Credential], String, Tab)?
    var shotToClipboard = false
    var addonsPopover: NSPopover?
    var taskManager: DevTools.TaskManagerController?
    var consoleController: DevTools.ConsoleController?
    var viewportPreset = 0
    var findBar: FindBar?
    var scriptManager: ScriptManagerController?
    var capturePop: NSPopover?
    var editors: [EditorWindowController] = []
    var recentlyClosed: [(url: URL, title: String, image: Data?)] = []
    var spinnerTimer: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Kestrel"
        window.minSize = NSSize(width: 900, height: 500)
        buildUI()
        window.center()
        window.makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private let sidebarW: CGFloat = 260
    private let stripH: CGFloat = 38
    private let navH: CGFloat = 42
    private let bottomH: CGFloat = 52

    private func buildUI() {
        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        let H = root.bounds.height, W = root.bounds.width

        // ---- tab strip, along the top ----
        tabStrip.frame = NSRect(x: 0, y: H - stripH, width: W, height: stripH)
        tabStrip.autoresizingMask = [.width, .minYMargin]
        tabStrip.onSelect = { [weak self] id in
            guard let self, let tab = self.tabs.first(where: { $0.id == id }) else { return }
            self.select(tab)
        }
        tabStrip.onClose = { [weak self] id in self?.closeTab(id: id) }
        tabStrip.onNewTab = { [weak self] in self?.newTabPressed() }
        root.addSubview(tabStrip)

        // Vertical tabs: the same tabs, with room for state and megabytes per row.
        sidebar.frame = NSRect(x: 0, y: bottomH, width: sidebarW,
                               height: H - bottomH - navH)
        sidebar.autoresizingMask = [.height]
        sidebar.hasVerticalScroller = true
        sidebar.drawsBackground = false
        sidebarTable.headerView = nil
        sidebarTable.rowHeight = 50
        sidebarTable.backgroundColor = .clear
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        let col = NSTableColumn(identifier: .init("tab"))
        col.width = sidebarW - 10
        sidebarTable.addTableColumn(col)
        sidebar.documentView = sidebarTable
        sidebar.isHidden = true
        root.addSubview(sidebar)

        // ---- nav bar ----
        let navY = H - stripH - navH
        var x: CGFloat = 10
        func navIcon(_ symbol: String, _ fallback: String, _ sel: Selector,
                     _ tip: String) -> NSButton {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: tip,
                                       size: 14, target: self, action: sel)
            b.frame = NSRect(x: x, y: navY + 8, width: 28, height: 26)
            b.autoresizingMask = [.minYMargin]
            x += 30
            root.addSubview(b)
            return b
        }
        backButton = navIcon("arrow.left", "\u{2190}", #selector(goBack), "Back")
        forwardButton = navIcon("arrow.right", "\u{2192}", #selector(goForward), "Forward")
        _ = navIcon("arrow.clockwise", "\u{21BB}", #selector(reload), "Reload")

        // Three grouped menus on the right, as in the reference: page tools, add-ons,
        // and the application menu.
        let rightW: CGFloat = 108
        urlBar = URLBarView(frame: NSRect(x: x + 6, y: navY + 7,
                                          width: W - x - rightW - 22, height: 28))
        urlBar.autoresizingMask = [.width, .minYMargin]
        urlBar.field.placeholderString =
            "Search \(NewTabPage.searchEngineName) or enter address"
        urlBar.field.target = self
        urlBar.field.action = #selector(navigate)
        urlBar.field.delegate = self
        urlBar.onQR = { [weak self] in self?.showQR() }
        urlBar.onBookmark = { [weak self] in self?.toggleBookmark() }
        root.addSubview(urlBar)

        var bx = W - rightW - 8
        func rightIcon(_ symbol: String, _ fallback: String, _ sel: Selector, _ tip: String) {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: tip,
                                       size: 15, target: self, action: sel)
            b.frame = NSRect(x: bx, y: navY + 8, width: 30, height: 26)
            b.autoresizingMask = [.minXMargin, .minYMargin]
            bx += 33
            root.addSubview(b)
        }
        rightIcon("wrench.adjustable", "\u{2692}", #selector(pageToolsMenu),
                  "Page tools — dark mode, capture, auto-refresh")
        rightIcon("puzzlepiece.extension", "\u{29C9}", #selector(addonsMenu),
                  "Add-ons — userscripts, ad blocker, passwords")
        rightIcon("line.3.horizontal", "\u{2630}", #selector(appMenu),
                  "Kestrel menu")

        // ---- web content ----
        webContainer.frame = NSRect(x: 0, y: bottomH, width: W,
                                    height: H - bottomH - stripH - navH)
        webContainer.autoresizingMask = [.width, .height]
        webContainer.wantsLayer = true
        root.addSubview(webContainer)

        placeholder.frame = webContainer.bounds
        placeholder.autoresizingMask = [.width, .height]
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        placeholder.isHidden = true
        webContainer.addSubview(placeholder)

        placeholderLabel.frame = NSRect(x: 0, y: webContainer.bounds.midY,
                                        width: webContainer.bounds.width, height: 20)
        placeholderLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        placeholderLabel.alignment = .center
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.isHidden = true
        webContainer.addSubview(placeholderLabel)

        // ---- bottom bar: memory as a product surface (DESIGN.md §7) ----
        budgetLabel.frame = NSRect(x: 8, y: 28, width: 150, height: 15)
        budgetLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        root.addSubview(budgetLabel)

        budgetSlider.frame = NSRect(x: 8, y: 6, width: 160, height: 20)
        budgetSlider.minValue = 300
        budgetSlider.maxValue = 8000
        budgetSlider.doubleValue = Prefs.budgetMB
        budgetSlider.target = self
        budgetSlider.action = #selector(budgetChanged)
        root.addSubview(budgetSlider)

        let capLabel = NSTextField(labelWithString: "per-tab cap")
        capLabel.frame = NSRect(x: 176, y: 28, width: 90, height: 15)
        capLabel.font = .systemFont(ofSize: 9.5)
        capLabel.textColor = .secondaryLabelColor
        root.addSubview(capLabel)

        capPopup.frame = NSRect(x: 174, y: 5, width: 96, height: 22)
        capPopup.addItems(withTitles: ["none", "256 MB", "384 MB", "512 MB", "768 MB"])
        capPopup.selectItem(at: [0, 256, 384, 512, 768].firstIndex(of: Prefs.perTabCapMB) ?? 0)
        capPopup.font = .systemFont(ofSize: 10)
        capPopup.target = self
        capPopup.action = #selector(capChanged)
        root.addSubview(capPopup)

        memoryBar.frame = NSRect(x: 282, y: 28, width: W - 292, height: 14)
        memoryBar.autoresizingMask = [.width]
        root.addSubview(memoryBar)

        statusLabel.frame = NSRect(x: 282, y: 8, width: W - 292, height: 14)
        statusLabel.autoresizingMask = [.width]
        statusLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        root.addSubview(statusLabel)

        updateBudgetLabel()
        applyTabLayout()
    }

    /// Switch between the horizontal strip and the vertical sidebar.
    func applyTabLayout() {
        guard let root = window.contentView else { return }
        let vertical = Prefs.verticalTabs
        let H = root.bounds.height, W = root.bounds.width
        tabStrip.isHidden = vertical
        sidebar.isHidden = !vertical

        let topInset = vertical ? navH : stripH + navH
        if vertical {
            sidebar.frame = NSRect(x: 0, y: bottomH, width: sidebarW,
                                   height: H - bottomH - navH)
            webContainer.frame = NSRect(x: sidebarW, y: bottomH,
                                        width: W - sidebarW, height: H - bottomH - topInset)
        } else {
            tabStrip.frame = NSRect(x: 0, y: H - stripH, width: W, height: stripH)
            webContainer.frame = NSRect(x: 0, y: bottomH, width: W,
                                        height: H - bottomH - topInset)
        }
        for sub in webContainer.subviews where sub is WKWebView {
            sub.frame = webContainer.bounds
        }
        placeholder.frame = webContainer.bounds
        refreshTabStrip()
    }

    @objc func toggleVerticalTabs() {
        Prefs.verticalTabs.toggle()
        applyTabLayout()
        flash(Prefs.verticalTabs ? "vertical tabs — state and memory shown per tab"
                                 : "horizontal tabs")
    }

    // MARK: - actions

    @objc public func newTabPressed() {
        openTab(url: NewTabPage.url())
        window.makeFirstResponder(urlBar.field)
        urlBar.field.stringValue = ""
    }

    // MARK: - navigation

    @objc func goBack() { currentTab?.webView?.goBack() }
    @objc func goForward() { currentTab?.webView?.goForward() }
    @objc func reload() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        // The new tab page is loaded from a string, so its document URL is about:blank
        // and reload() would faithfully reload *that* — a blank page.
        if NewTabPage.isNewTab(tab.url) {
            wv.loadHTMLString(NewTabPage.html, baseURL: nil)
        } else {
            wv.reload()
        }
    }
    @objc func goHome() {
        guard let tab = currentTab else { newTabPressed(); return }
        tab.url = NewTabPage.sentinel
        tab.title = "New Tab"
        tab.webView?.loadHTMLString(NewTabPage.html, baseURL: nil)
        urlBar.field.stringValue = ""
        refreshTabStrip()
    }

    private func updateNavButtons() {
        backButton?.isEnabled = currentTab?.webView?.canGoBack ?? false
        forwardButton?.isEnabled = currentTab?.webView?.canGoForward ?? false
    }

    /// Enter navigates the current tab; a query that is not a URL becomes a search.
    @objc func navigate() {
        guard let url = NewTabPage.resolve(urlBar.field.stringValue) else { return }
        if let tab = currentTab, tab.state == .live, tab.webView != nil {
            tab.url = url
            tab.webView?.load(URLRequest(url: url))
            refreshTabStrip()
        } else {
            openTab(url: url)
        }
        window.makeFirstResponder(nil)
    }

    @objc func budgetChanged() {
        scheduler.budgetBytes = Int64(budgetSlider.doubleValue) * 1024 * 1024
        Prefs.budgetMB = budgetSlider.doubleValue
        updateBudgetLabel()
        applyBudgetAndRefresh()      // cheap: cached values only, so dragging stays smooth
    }

    @objc func capChanged() {
        let mb: Int64 = [0, 256, 384, 512, 768][capPopup.indexOfSelectedItem]
        scheduler.perTabCapBytes = mb * 1024 * 1024
        Prefs.perTabCapMB = Int(mb)
        applyBudgetAndRefresh()
    }

    @objc public func closeSelectedTab() { closeTab(id: foregroundId) }

    // MARK: - feature actions

    public var currentTab: Tab? { tabs.first { $0.id == foregroundId } }

    @objc public func toggleDark() {
        guard let tab = currentTab else { return }
        tab.toggleDarkMode { [weak self] on in
            self?.flash((on ? "dark mode on — " : "dark mode off — ")
                        + DarkReaderBridge.modeDescription)
        }
    }

    // MARK: - screenshots

    @objc func screenshotMenu(_ sender: NSButton) {   // kept for the keyboard path
        let menu = NSMenu(title: "Capture")
        for (title, sel) in [("Visible Area", #selector(shotVisible)),
                             ("Full Page", #selector(shotFullPage)),
                             ("Region…", #selector(shotRegion)),
                             ("Full Page as PDF", #selector(shotPDF))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clip = NSMenuItem(title: "Copy to clipboard instead of saving",
                              action: #selector(toggleShotToClipboard), keyEquivalent: "")
        clip.target = self
        clip.state = shotToClipboard ? .on : .off
        menu.addItem(clip)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4),
                   in: sender)
    }

    @objc public func toggleShotToClipboard() { shotToClipboard.toggle() }

    /// Turns dark mode on for every page, now and in future sessions. Applies to open
    /// tabs immediately rather than only to ones opened later.
    @objc public func toggleDarkByDefault() {
        Prefs.darkByDefault.toggle()
        let on = Prefs.darkByDefault
        for tab in tabs where tab.darkMode != on {
            tab.toggleDarkMode()
        }
        flash(on ? "dark mode on by default — \(DarkReaderBridge.modeDescription)"
                 : "dark mode default off")
        refreshTabStrip()
    }

    @objc public func shotVisible() {
        guard let wv = currentTab?.webView else { return }
        flash("capturing visible area…")
        Screenshot.captureVisible(wv) { [weak self] image, note in
            self?.deliver(image, note: note)
        }
    }

    @objc public func shotFullPage() {
        guard let wv = currentTab?.webView else { return }
        flash("capturing full page…")
        Screenshot.captureFullPage(wv, progress: { [weak self] msg in
            self?.flash(msg)
        }) { [weak self] image, note in
            self?.deliver(image, note: note)
        }
    }

    @objc public func shotPDF() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        flash("rendering PDF…")
        Screenshot.capturePDF(wv) { [weak self] data, note in
            guard let self else { return }
            guard let data else { self.flash(note); return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = Screenshot.suggestedFilename(for: tab.url, ext: "pdf")
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                try? data.write(to: url)
                self.flash("saved \(note)")
            }
        }
    }

    @objc public func shotRegion() {
        guard let wv = currentTab?.webView else { return }
        let overlay = RegionOverlay(frame: webContainer.bounds)
        overlay.autoresizingMask = [.width, .height]
        webContainer.addSubview(overlay)
        window.makeFirstResponder(overlay)
        flash("drag to select a region")
        overlay.onFinish = { [weak self] rect in
            guard let self else { return }
            guard let rect else { self.flash("region capture cancelled"); return }
            Screenshot.captureVisible(wv) { image, note in
                guard let image,
                      let cropped = Screenshot.crop(image, to: rect, viewSize: wv.bounds.size)
                else { self.flash("region capture failed: \(note)"); return }
                self.deliver(cropped, note: "region \(Int(rect.width))×\(Int(rect.height))")
            }
        }
    }

    /// Click an element to capture just that element, Longshot's "Pick element".
    @objc public func shotElement() {
        guard let wv = currentTab?.webView else { return }
        flash("click an element to capture it — Esc to cancel")
        let picker = RegionOverlay(frame: webContainer.bounds)
        picker.autoresizingMask = [.width, .height]
        picker.pickMode = true
        webContainer.addSubview(picker)
        window.makeFirstResponder(picker)
        picker.onPick = { [weak self] point in
            guard let self else { return }
            guard let point else { self.flash("element capture cancelled"); return }
            let js = """
            (function () {
              const el = document.elementFromPoint(\(point.x), \(point.y));
              if (!el) return null;
              const r = el.getBoundingClientRect();
              return {x: r.left, y: r.top, w: r.width, h: r.height, tag: el.tagName};
            })();
            """
            wv.evaluateJavaScript(js) { result, _ in
                guard let d = result as? [String: Any],
                      let x = d["x"] as? CGFloat, let y = d["y"] as? CGFloat,
                      let w = d["w"] as? CGFloat, let h = d["h"] as? CGFloat,
                      w > 1, h > 1 else { self.flash("no element there"); return }
                Screenshot.captureVisible(wv) { image, note in
                    guard let image,
                          let cropped = Screenshot.crop(image,
                                                        to: NSRect(x: x, y: y, width: w, height: h),
                                                        viewSize: wv.bounds.size)
                    else { self.flash("element capture failed: \(note)"); return }
                    self.deliver(cropped,
                                 note: "element \((d["tag"] as? String) ?? "") "
                                       + "\(Int(w))×\(Int(h))")
                }
            }
        }
    }

    /// Capture popover: what to capture, and what happens next.
    @objc public func capturePopover(_ sender: NSView) {
        let vc = NSViewController()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        var y: CGFloat = 258

        for (label, options, initial, sel) in
            [("Then", ["Open in editor", "Save to file", "Copy to clipboard"],
              Prefs.shotThen, #selector(shotThenChanged(_:))),
             ("Format", ["PNG", "JPEG", "PDF"], Prefs.shotFormat,
              #selector(shotFormatChanged(_:)))] {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 16, y: y, width: 60, height: 20)
            l.textColor = .secondaryLabelColor
            v.addSubview(l)
            let pop = NSPopUpButton(frame: NSRect(x: 82, y: y - 4, width: 220, height: 26))
            pop.addItems(withTitles: options)
            pop.selectItem(withTitle: initial)
            pop.target = self
            pop.action = sel
            v.addSubview(pop)
            y -= 36
        }

        let sep = NSBox(frame: NSRect(x: 12, y: y, width: 296, height: 1))
        sep.boxType = .separator
        v.addSubview(sep)
        y -= 12

        for (title, sel) in [("Entire page", #selector(shotFullPage)),
                             ("Visible area", #selector(shotVisible)),
                             ("Select region", #selector(shotRegion)),
                             ("Pick element", #selector(shotElement))] {
            let b = NSButton(title: "  " + title, target: self, action: sel)
            b.frame = NSRect(x: 12, y: y - 34, width: 296, height: 34)
            b.bezelStyle = .rounded
            b.alignment = .left
            b.font = .systemFont(ofSize: 13)
            v.addSubview(b)
            y -= 38
        }

        vc.view = v
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = v.frame.size
        pop.behavior = .transient
        capturePop = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc func shotThenChanged(_ p: NSPopUpButton) { Prefs.shotThen = p.titleOfSelectedItem ?? "" }
    @objc func shotFormatChanged(_ p: NSPopUpButton) { Prefs.shotFormat = p.titleOfSelectedItem ?? "" }

    private func deliver(_ image: NSImage?, note: String) {
        guard let image else { flash(note); return }
        capturePop?.close()
        switch Prefs.shotThen {
        case "Copy to clipboard":
            Screenshot.copyToClipboard(image)
            flash("copied to clipboard — \(note)")
            return
        case "Open in editor":
            let ed = EditorWindowController(image: image, url: currentTab?.url,
                                            title: currentTab?.title ?? "", browser: self)
            editors.append(ed)
            ed.show()
            flash(note)
            return
        default: break
        }
        if shotToClipboard {
            Screenshot.copyToClipboard(image)
            flash("copied to clipboard — \(note)")
            return
        }
        guard let png = Screenshot.png(image) else { flash("could not encode PNG"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Screenshot.suggestedFilename(
            for: currentTab?.url ?? URL(string: "https://page")!, ext: "png")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            try? png.write(to: url)
            self?.flash("saved \(note) — \(png.count / 1024) KB")
        }
    }

    @objc func showQR() {
        guard let tab = currentTab,
              let image = QRCode.image(for: tab.url.absoluteString) else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "QR — " + (tab.url.host ?? "")
        let iv = NSImageView(frame: NSRect(x: 20, y: 90, width: 320, height: 320))
        iv.image = image
        panel.contentView?.addSubview(iv)
        let label = NSTextField(wrappingLabelWithString: tab.url.absoluteString)
        label.frame = NSRect(x: 20, y: 40, width: 320, height: 44)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .secondaryLabelColor
        panel.contentView?.addSubview(label)
        let save = NSButton(title: "Save PNG…", target: self, action: #selector(saveQR))
        save.frame = NSRect(x: 20, y: 8, width: 100, height: 26)
        panel.contentView?.addSubview(save)
        qrImage = image
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        qrPanel = panel
    }

    @objc func saveQR() {
        guard let image = qrImage else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "qr.png"
        save.begin { resp in
            guard resp == .OK, let url = save.url,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    public static let refreshChoices: [(String, TimeInterval?)] = [
        ("Off", nil), ("Every 5s", 5), ("Every 15s", 15),
        ("Every 30s", 30), ("Every 60s", 60), ("Every 5m", 300),
    ]

    @objc public func setRefresh(_ sender: NSMenuItem) {
        guard let tab = currentTab else { return }
        tab.refreshInterval = Self.refreshChoices[sender.tag].1
        tab.lastRefresh = Date()
        flash(tab.refreshInterval == nil
              ? "auto-refresh off"
              : "auto-refresh every \(Int(tab.refreshInterval!))s — tab pinned LIVE")
        refreshTabStrip()
    }

    /// Developer tools, behind the wrench — matching where Firefox puts them.
    @objc func pageToolsMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Developer")
        func add(_ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = [], enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            i.keyEquivalentModifierMask = mods
            i.isEnabled = enabled
            menu.addItem(i)
        }
        add("Web Inspector", #selector(openInspector), "i", [.command, .option])
        add("Task Manager", #selector(openTaskManager), "\u{1b}", [.shift])
        add("Browser Console", #selector(openConsole), "j", [.command, .shift])
        menu.addItem(.separator())

        let responsive = NSMenuItem(title: "Responsive Design Mode", action: nil,
                                    keyEquivalent: "")
        let rMenu = NSMenu()
        for (i, preset) in DevTools.devicePresets.enumerated() {
            let item = NSMenuItem(title: preset.0, action: #selector(setViewport(_:)),
                                  keyEquivalent: "")
            item.target = self; item.tag = i
            item.state = viewportPreset == i ? .on : .off
            rMenu.addItem(item)
        }
        responsive.submenu = rMenu
        menu.addItem(responsive)

        add("Eyedropper", #selector(eyedropper))
        add("Reset Camera/Mic Permissions", #selector(resetMediaPermissions),
            enabled: !Prefs.mediaDecisions.isEmpty)
        add("Page Source", #selector(viewSource), "u", [.command])
        popUp(menu, from: sender)
    }

    // MARK: - developer tools

    @objc func openInspector() {
        guard let wv = currentTab?.webView else { return }
        if #available(macOS 13.3, *) {
            wv.isInspectable = true
            flash("Web Inspector enabled — right-click the page and choose Inspect Element")
        } else {
            flash("Web Inspector requires macOS 13.3 or later")
        }
    }

    @objc func openTaskManager() {
        if taskManager == nil { taskManager = DevTools.TaskManagerController(browser: self) }
        taskManager?.show()
    }

    @objc func openConsole() {
        if consoleController == nil {
            consoleController = DevTools.ConsoleController()
        }
        // Console forwarding is attached per web view, so wire up the current tab now.
        if let wv = currentTab?.webView, let cc = consoleController {
            let ucc = wv.configuration.userContentController
            ucc.removeScriptMessageHandler(forName: "kestrelConsole")
            ucc.add(cc, name: "kestrelConsole")
            wv.evaluateJavaScript(DevTools.consoleScript, completionHandler: nil)
        }
        consoleController?.show()
        flash("console attached to this tab — reload to catch load-time messages")
    }

    @objc func setViewport(_ sender: NSMenuItem) {
        viewportPreset = sender.tag
        let preset = DevTools.devicePresets[sender.tag]
        guard let wv = currentTab?.webView else { return }
        if preset.1 == 0 {
            wv.frame = webContainer.bounds
            wv.autoresizingMask = [.width, .height]
            flash("responsive mode off")
        } else {
            wv.autoresizingMask = []
            wv.frame = NSRect(x: (webContainer.bounds.width - preset.1) / 2,
                              y: max(0, webContainer.bounds.height - preset.2),
                              width: preset.1, height: min(preset.2, webContainer.bounds.height))
            flash("viewport set to \(preset.0)")
        }
    }

    /// NSColorSampler is the system eyedropper, so this is a real picker rather than a
    /// screenshot-and-guess.
    @objc func eyedropper() {
        NSColorSampler().show { [weak self] color in
            guard let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X",
                             Int(color.redComponent * 255), Int(color.greenComponent * 255),
                             Int(color.blueComponent * 255))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            self?.flash("\(hex) copied to the clipboard")
        }
    }

    @objc func resetMediaPermissions() {
        let n = Prefs.mediaDecisions.count
        Prefs.mediaDecisions = [:]
        flash("cleared \(n) camera/microphone decision(s) — sites will ask again")
    }

    @objc func viewSource() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        DevTools.showSource(of: wv, title: tab.title)
    }

    /// The add-ons popover, in the shape browsers use: a list that pushes to detail
    /// panes, rather than a flat NSMenu.
    @objc func addonsMenu(_ sender: NSButton) {
        let vc = AddonsPopoverController(browser: self)
        vc.showRoot()
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = vc.preferredContentSize
        pop.behavior = .transient
        addonsPopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Sites on the exclusion list get dark mode turned back off after they load. The
    /// user script is attached when the web view is created, so a tab that later
    /// navigates to an excluded host would otherwise stay themed.
    func enforceDarkExclusion(for tab: Tab) {
        guard let wv = tab.webView else { return }
        guard Prefs.isDarkExcluded(host: tab.url.host) else { return }
        wv.evaluateJavaScript(DarkReaderBridge.disableJS) { [weak self] _, _ in
            tab.darkMode = false
            self?.flash("dark mode is off for \(tab.url.host ?? "this site")")
        }
    }

    @objc func toggleDarkExclusion() {
        guard let tab = currentTab, let host = tab.url.host else { return }
        let nowExcluded = !Prefs.isDarkExcluded(host: host)
        Prefs.setDarkExcluded(nowExcluded, host: host)
        if nowExcluded {
            tab.webView?.evaluateJavaScript(DarkReaderBridge.disableJS, completionHandler: nil)
            tab.darkMode = false
            flash("\(host) added to the dark mode exclusion list")
        } else {
            tab.darkMode = true
            tab.webView?.evaluateJavaScript(DarkReaderBridge.reapplyJS(), completionHandler: nil)
            flash("\(host) removed from the exclusion list")
        }
    }

    /// Re-apply Dark Reader's slider settings to the current page.
    func applyDarkSettings() {
        guard let wv = currentTab?.webView else { return }
        wv.evaluateJavaScript(DarkReaderBridge.reapplyJS()) { [weak self] r, _ in
            self?.flash((r as? String) == "applied"
                        ? "dark settings applied" : "turn dark mode on first")
        }
    }

    /// Per-site blocking: detach or reattach the compiled rules for this tab.
    func applySiteBlocking() {
        guard let tab = currentTab, let wv = tab.webView,
              let host = tab.url.host else { return }
        let controller = wv.configuration.userContentController
        if Prefs.isBlockingEnabled(host: host) {
            ContentBlocker.apply(to: controller)
            flash("ad blocking enabled on \(host) — reload to take effect")
        } else {
            controller.removeAllContentRuleLists()
            flash("ad blocking disabled on \(host) — reload to take effect")
        }
    }

    @objc func addonsMenuLegacy(_ sender: NSButton) {
        let menu = NSMenu(title: "Add-ons")
        func add(_ title: String, _ sel: Selector?, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.isEnabled = enabled
            menu.addItem(i)
        }
        let custom = ContentBlocker.customStats.map { " + \($0.blocked) from filters.txt" } ?? ""
        add("Ad blocker: \(ContentBlocker.ruleCount) built-in rules\(custom)", nil, enabled: false)
        add("Reload Blocklist from ~/.kestrel/filters.txt", #selector(reloadBlocklist))
        menu.addItem(.separator())
        add("Dark Reader: \(DarkReaderBridge.version)", nil, enabled: false)
        let scripts = UserScriptStore.loadAll()
        add("Userscripts: \(scripts.count) loaded", nil, enabled: false)
        for s in scripts.prefix(6) { add("    \(s.name)", nil, enabled: false) }
        add("Reload Userscripts", #selector(reloadUserScripts))
        menu.addItem(.separator())
        add("Bitwarden: \(Bitwarden.status().shortLabel)", nil, enabled: false)
        add("Fill Password on This Page", #selector(bitwardenFill))
        popUp(menu, from: sender)
    }

    /// Application menu.
    @objc func appMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Kestrel")
        func add(_ title: String, _ sel: Selector?, state: NSControl.StateValue = .off,
                 enabled: Bool = true, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = state; i.isEnabled = enabled; i.tag = tag
            menu.addItem(i)
        }
        add("New Tab", #selector(newTabPressed))
        add("Close Tab", #selector(closeSelectedTab))
        add("Reopen Closed Tab", #selector(undoCloseTab), enabled: !recentlyClosed.isEmpty)
        menu.addItem(.separator())

        let bm = NSMenuItem(title: "Bookmarks (\(Store.bookmarks.count))",
                            action: nil, keyEquivalent: "")
        let bookmarksMenu = NSMenu()
        if Store.bookmarks.isEmpty {
            let e = NSMenuItem(title: "None yet — press the star", action: nil,
                               keyEquivalent: "")
            e.isEnabled = false
            bookmarksMenu.addItem(e)
        }
        for b in Store.bookmarks.suffix(20).reversed() {
            let i = NSMenuItem(title: b.title.isEmpty ? b.url : b.title,
                               action: #selector(openStoredURL(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = b.url
            bookmarksMenu.addItem(i)
        }
        bm.submenu = bookmarksMenu
        menu.addItem(bm)

        let hist = NSMenuItem(title: "Recent history", action: nil, keyEquivalent: "")
        let hMenu = NSMenu()
        for h in Store.history.sorted(by: { $0.visited > $1.visited }).prefix(15) {
            let i = NSMenuItem(title: h.title.isEmpty ? h.url : h.title,
                               action: #selector(openStoredURL(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = h.url
            hMenu.addItem(i)
        }
        hist.submenu = hMenu
        menu.addItem(hist)
        menu.addItem(.separator())

        let budget = NSMenuItem(title: "Memory budget", action: nil, keyEquivalent: "")
        let bMenu = NSMenu()
        for mb in [600, 1200, 2000, 3000, 4000, 6000] {
            let i = NSMenuItem(title: "\(String(format: "%.1f", Double(mb)/1024)) GB",
                               action: #selector(setBudget(_:)), keyEquivalent: "")
            i.target = self; i.tag = mb
            i.state = Int(Prefs.budgetMB) == mb ? .on : .off
            bMenu.addItem(i)
        }
        budget.submenu = bMenu
        menu.addItem(budget)
        add("    \(Int(Double(scheduler.totalBytes(tabs)) / 1_048_576)) MB in use across "
            + "\(tabs.count) tabs", nil, enabled: false)
        menu.addItem(.separator())
        menu.addItem(.separator())
        add("Print…", #selector(printPage))
        add("Save Page As…", #selector(savePageAs))
        add("Find in Page…", #selector(findInPage))

        let zoom = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let zMenu = NSMenu()
        for (t, sel) in [("Zoom In", #selector(zoomIn)), ("Zoom Out", #selector(zoomOut)),
                         ("Actual Size", #selector(zoomReset))] {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self
            zMenu.addItem(i)
        }
        zoom.submenu = zMenu
        menu.addItem(zoom)
        add("    currently \(Int((currentTab?.webView?.pageZoom ?? 1) * 100))%", nil,
            enabled: false)
        menu.addItem(.separator())
        add("Vertical Tabs", #selector(toggleVerticalTabs),
            state: Prefs.verticalTabs ? .on : .off)
        add("Userscript Dashboard…", #selector(openScriptManager))
        add("Task Manager…", #selector(openTaskManager))
        menu.addItem(.separator())
        add("Quit Kestrel", #selector(NSApplication.terminate(_:)))
        popUp(menu, from: sender)
    }

    private func popUp(_ menu: NSMenu, from sender: NSButton) {
        menu.popUp(positioning: nil,
                   at: NSPoint(x: sender.bounds.width - 240, y: sender.bounds.height + 4),
                   in: sender)
    }

    @objc func openScriptManager() {
        if scriptManager == nil { scriptManager = ScriptManagerController(browser: self) }
        scriptManager?.show()
    }

    @objc func printPage() {
        guard let wv = currentTab?.webView else { return }
        let op = wv.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Saves the page as a web archive — WebKit's own format, so it reopens intact.
    @objc func savePageAs() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        wv.createWebArchiveData { [weak self] result in
            guard case .success(let data) = result else {
                self?.flash("could not archive this page"); return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                Screenshot.suggestedFilename(for: tab.url, ext: "webarchive")
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                try? data.write(to: url)
                self?.flash("saved \(data.count / 1024) KB web archive")
            }
        }
    }

    @objc func openStoredURL(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s)
        else { return }
        openTab(url: url)
    }

    @objc func setBudget(_ sender: NSMenuItem) {
        budgetSlider.doubleValue = Double(sender.tag)
        budgetChanged()
    }

    @objc public func reloadBlocklist() {
        ContentBlocker.loadCustomList { [weak self] _, note in self?.flash(note) }
    }

    @objc func toggleBookmark() {
        guard let tab = currentTab, !NewTabPage.isNewTab(tab.url) else { return }
        let added = Store.toggleBookmark(tab.url, title: tab.title)
        urlBar.isBookmarked = added
        flash(added ? "bookmarked \(tab.title)" : "removed bookmark")
    }

    // MARK: - find, zoom, session

    @objc func findInPage() {
        guard let wv = currentTab?.webView else { return }
        if findBar == nil {
            let bar = FindBar(frame: NSRect(x: 0, y: webContainer.bounds.height - 34,
                                            width: webContainer.bounds.width, height: 34))
            bar.autoresizingMask = [.width, .minYMargin]
            bar.onClose = { [weak self] in
                self?.findBar?.removeFromSuperview(); self?.findBar = nil
            }
            findBar = bar
        }
        if findBar?.superview == nil { webContainer.addSubview(findBar!) }
        findBar?.frame = NSRect(x: 0, y: webContainer.bounds.height - 34,
                                width: webContainer.bounds.width, height: 34)
        findBar?.attach(to: wv)
    }

    @objc func zoomIn()    { setZoom((currentTab?.webView?.pageZoom ?? 1) + 0.1) }
    @objc func zoomOut()   { setZoom((currentTab?.webView?.pageZoom ?? 1) - 0.1) }
    @objc func zoomReset() { setZoom(1) }
    private func setZoom(_ z: CGFloat) {
        guard let wv = currentTab?.webView else { return }
        wv.pageZoom = min(3, max(0.3, z))
        flash(String(format: "zoom %.0f%%", wv.pageZoom * 100))
    }

    /// Reopen the most recently closed tab, restoring its session image so it comes back
    /// where it was rather than at the top of the page.
    @objc func undoCloseTab() {
        guard let closed = recentlyClosed.popLast() else { flash("nothing to reopen"); return }
        let tab = Tab(id: nextId, url: closed.url, title: closed.title)
        tab.sessionImage = closed.image
        nextId += 1
        tabs.append(tab)
        select(tab)
        flash("reopened \(closed.title)")
    }

    func saveSession() {
        Store.saveSession(tabs.compactMap { tab in
            guard !NewTabPage.isNewTab(tab.url) else { return nil }
            return Store.SessionTab(url: tab.url.absoluteString, title: tab.title,
                                    interactionState: tab.sessionImage
                                        ?? (tab.webView?.interactionState as? Data),
                                    pinned: tab.pinned)
        })
        Store.flush()
    }

    func restoreSession() -> Bool {
        let saved = Store.loadSession()
        guard !saved.isEmpty else { return false }
        for st in saved {
            guard let url = URL(string: st.url) else { continue }
            let tab = Tab(id: nextId, url: url, title: st.title)
            tab.sessionImage = st.interactionState
            tab.pinned = st.pinned
            nextId += 1
            tabs.append(tab)
        }
        // Restored tabs start COLD: the whole point is that reopening 20 tabs should not
        // cost 20 live pages. They load when selected.
        if let first = tabs.first { select(first) }
        refreshTabStrip()
        flash("restored \(saved.count) tab(s) — they load when you open them")
        return true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { urlBar.noteFocusChanged() }
    func controlTextDidEndEditing(_ obj: Notification) { urlBar.noteFocusChanged() }


    // MARK: - tabs

    private func updateBudgetLabel() {
        budgetLabel.stringValue = String(format: "budget  %.1f GB",
                                         budgetSlider.doubleValue / 1024)
    }

    func openTab(url: URL) {
        let tab = Tab(id: nextId, url: url)
        nextId += 1
        tabs.append(tab)
        select(tab)
    }

    func closeTab(id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        if !NewTabPage.isNewTab(closing.url) {
            recentlyClosed.append((closing.url, closing.title,
                                   closing.sessionImage
                                    ?? (closing.webView?.interactionState as? Data)))
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }
        tabs[idx].demote(to: .stub)
        tabs.remove(at: idx)
        if foregroundId == id {
            // Prefer the tab to the right, as every other browser does.
            let next = tabs.indices.contains(idx) ? tabs[idx] : tabs.last
            if let next { select(next) } else { foregroundId = -1; newTabPressed() }
        }
        refreshTabStrip()
    }

    func select(_ tab: Tab) {
        let needsLoad = tab.state < .live

        for other in tabs where other.id != tab.id { other.webView?.removeFromSuperview() }

        // The snapshot placeholder is only correct while a tab is actually restoring.
        // It hides on didFinish -- which never fires for an already-loaded tab -- so it
        // must be cleared explicitly when no load is coming.
        if needsLoad, let snap = tab.snapshot {
            placeholder.image = snap
            placeholder.isHidden = false
            placeholderLabel.stringValue = "restoring \(tab.title)…"
            placeholderLabel.isHidden = false
        } else {
            placeholder.isHidden = true
            placeholderLabel.isHidden = true
        }

        let ms = tab.promote(to: .live, in: webContainer)   // no-op when already LIVE
        tab.ensureAttached(to: webContainer)                // ...which is why this is separate
        tab.webView?.navigationDelegate = self
        tab.webView?.uiDelegate = self
        tab.lastUsed = Date()
        tab.uses += 1
        foregroundId = tab.id
        if ms > 0 { tab.lastRestoreMs = ms }
        urlBar.field.stringValue = NewTabPage.isNewTab(tab.url) ? "" : tab.url.absoluteString
        urlBar.isBookmarked = Store.isBookmarked(tab.url)
        updateSecurityIndicator(for: tab)

        placeholder.removeFromSuperview(); webContainer.addSubview(placeholder)
        placeholderLabel.removeFromSuperview(); webContainer.addSubview(placeholderLabel)

        updateNavButtons()
        refreshTabStrip()
    }

    func updateSecurityIndicator(for tab: Tab) {
        if NewTabPage.isNewTab(tab.url) { urlBar.security = .blank }
        else if tab.url.scheme == "https" {
            let rules = ContentBlocker.ruleCount
                + (ContentBlocker.customStats?.blocked ?? 0)
            urlBar.security = rules > 0 ? .blocked(rules) : .secure
        } else { urlBar.security = .insecure }
    }

    func refreshTabStrip() {
        sidebarTable.reloadData()
        tabStrip.items = tabs.map {
            TabStripView.Item(id: $0.id,
                              title: $0.title.isEmpty ? "New Tab" : $0.title,
                              state: $0.state, bytes: $0.currentBytes,
                              isCurrent: $0.id == foregroundId, pinned: $0.pinned,
                              isLoading: $0.isLoading)
        }
    }

    // MARK: - the loop that makes it a budget

    /// Attach newly-compiled blocking rules to tabs that already exist.
    func retrofitBlocker() {
        for tab in tabs {
            guard let wv = tab.webView else { continue }
            ContentBlocker.apply(to: wv.configuration.userContentController)
        }
    }

    func blockerReady(_ ok: Bool, rules: Int) {
        flash(ok ? "ad blocker: \(rules) rules compiled" : "ad blocker failed to compile")
    }

    func customBlocklistReady(_ note: String) { flash(note) }

    /// Samples every tab's footprint on a background queue, then updates the UI from the
    /// cache. Nothing here may block the main thread: one `footprint` call costs ~226 ms,
    /// and doing that inline is what made scrolling drop a quarter of its frames.
    func sampleMemory() {
        guard !sampling else { return }
        sampling = true
        let live = tabs.compactMap { tab -> (Tab, Int32)? in tab.pid.map { (tab, $0) } }
        DispatchQueue.global(qos: .utility).async {
            let sampled = live.map { (tab, pid) -> (Tab, Int64) in
                (tab, MemoryProbe.isAlive(pid) ? (MemoryProbe.footprint(pid: pid) ?? 0) : 0)
            }
            let pids = Set(MemoryProbe.webContentPids())
            DispatchQueue.main.async {
                Tab.lastKnownPids = pids
                for (tab, bytes) in sampled { tab.cachedBytes = bytes }
                self.sampling = false
                self.applyBudgetAndRefresh()
            }
        }
    }

    func tick() {
        for tab in tabs { tab.refreshIfDue() }
        sampleMemory()
        applyBudgetAndRefresh()
    }

    /// Enforce the budget and repaint, reading only cached measurements — cheap enough
    /// to run on every tick and on every slider drag.
    func applyBudgetAndRefresh() {
        for tab in tabs where tab.state == .live && tab.cachedBytes > 0 {
            tab.measuredLiveBytes = tab.cachedBytes
        }
        scheduler.enforce(tabs, foreground: foregroundId)

        var byState: [TabState: Int64] = [:]
        for tab in tabs { byState[tab.state, default: 0] += tab.currentBytes }
        let total = byState.values.reduce(0, +)

        memoryBar.segments = [.live, .warm, .cold, .stub].map {
            MemoryBar.Segment(bytes: byState[$0] ?? 0,
                              color: MemoryBar.color(for: $0), label: $0.description)
        }
        memoryBar.budgetBytes = scheduler.budgetBytes
        memoryBar.totalBytes = total
        memoryBar.needsDisplay = true

        let counts = Dictionary(grouping: tabs, by: \.state).mapValues(\.count)
        let over = total > scheduler.budgetBytes
        refreshTabStrip()
        guard Date() >= flashUntil else { return }
        statusLabel.stringValue = String(
            format: "%.0f MB of %.0f MB %@   ·   LIVE %d  WARM %d  COLD %d  STUB %d   ·   %d demotions, %d discarded%@",
            Double(total) / 1_048_576, Double(scheduler.budgetBytes) / 1_048_576,
            over ? "OVER BUDGET" : "",
            counts[.live] ?? 0, counts[.warm] ?? 0, counts[.cold] ?? 0, counts[.stub] ?? 0,
            scheduler.demotions, scheduler.stateLosses,
            scheduler.gaveUp > 0 ? "   ·   budget unreachable (holding rather than discarding)" : "")
        statusLabel.textColor = over ? .systemOrange : .secondaryLabelColor
    }

    func flash(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .labelColor
        flashUntil = Date().addingTimeInterval(4)
    }

    // MARK: - add-ons

    @objc public func reloadUserScripts() {
        flash("\(UserScriptStore.loadAll().count) userscript(s) loaded — reopen tabs to apply")
    }

    /// Bitwarden autofill. Explicit user action only, origin-gated, never submits.
    @objc public func bitwardenFill() {
        guard let tab = currentTab, let host = tab.url.host else { return }
        guard tab.url.scheme == "https" else {
            flash("autofill refused: page is not HTTPS"); return
        }
        switch Bitwarden.credentials(forHost: host) {
        case .failure(let status):
            flash(status.message)
        case .success(let creds):
            guard !creds.isEmpty else { flash("no Bitwarden entry matches \(host)"); return }
            if creds.count == 1 { fill(creds[0], host: host, in: tab) }
            else {
                let menu = NSMenu(title: "Choose credential")
                for (i, c) in creds.enumerated() {
                    let item = NSMenuItem(title: "\(c.name) — \(c.username)",
                                          action: #selector(pickCredential(_:)),
                                          keyEquivalent: "")
                    item.target = self; item.tag = i
                    menu.addItem(item)
                }
                pendingCreds = (creds, host, tab)
                menu.popUp(positioning: nil,
                           at: NSPoint(x: window.frame.width - 260,
                                       y: window.frame.height - 90),
                           in: window.contentView)
            }
        }
    }

    @objc func pickCredential(_ sender: NSMenuItem) {
        guard let (creds, host, tab) = pendingCreds, sender.tag < creds.count else { return }
        fill(creds[sender.tag], host: host, in: tab)
        pendingCreds = nil
    }

    private func fill(_ cred: Bitwarden.Credential, host: String, in tab: Tab) {
        // The script re-checks the origin itself; if the page navigated between the
        // vault query and this call it refuses rather than filling the wrong site.
        tab.webView?.evaluateJavaScript(Bitwarden.fillScript(cred, expectedHost: host)) {
            [weak self] result, _ in
            switch result as? String {
            case "filled":            self?.flash("filled \(cred.name) — review, then submit")
            case "no-password-field": self?.flash("no password field found on this page")
            case "origin-changed":    self?.flash("autofill aborted: page changed origin")
            case "not-https":         self?.flash("autofill refused: page is not HTTPS")
            default:                  self?.flash("autofill did not run")
            }
        }
    }

    // MARK: - vertical tab list

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < tabs.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("vrow")
        let view = (t.makeView(withIdentifier: id, owner: self) as? TabRowView)
            ?? TabRowView(frame: NSRect(x: 0, y: 0, width: sidebarW - 10, height: 50))
        view.identifier = id
        view.configure(tabs[row], isCurrent: tabs[row].id == foregroundId)
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        guard row >= 0, row < tabs.count, tabs[row].id != foregroundId else { return }
        select(tabs[row])
    }

    // MARK: - UI delegate

    /// Camera and microphone requests.
    ///
    /// WKWebView's default for this delegate method is to **deny** — not to prompt — so
    /// omitting it makes getUserMedia fail with "camera not found" and no way for the
    /// user to allow it. Kestrel asks per origin and remembers the answer, which is what
    /// every other browser does.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.isEmpty ? "this site" : origin.host
        let what: String
        switch type {
        case .camera: what = "camera"
        case .microphone: what = "microphone"
        case .cameraAndMicrophone: what = "camera and microphone"
        @unknown default: what = "camera and microphone"
        }
        let key = "\(host)|\(what)"

        if let remembered = Prefs.mediaDecision(for: key) {
            decisionHandler(remembered ? .grant : .deny)
            flash("\(host): \(what) \(remembered ? "allowed" : "blocked") (remembered)")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use your \(what)?"
        alert.informativeText =
            "Kestrel will remember this choice for \(host). You can change it later under "
            + "the wrench menu."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        alert.alertStyle = .informational
        let allow = alert.runModal() == .alertFirstButtonReturn
        Prefs.setMediaDecision(allow, for: key)
        decisionHandler(allow ? .grant : .deny)
        flash("\(host): \(what) \(allow ? "allowed" : "blocked")")
    }

    /// WKWebView returns nil for window.open by default, which silently breaks links
    /// that use it. Route them into a tab instead.
    func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openTab(url: url) }
        return nil
    }

    // MARK: - loading indicator

    /// Runs only while something is loading. An idle browser should not be repainting
    /// a spinner sixty times a second.
    func updateLoadingAnimation() {
        let anyLoading = tabs.contains { $0.isLoading }
        if anyLoading, spinnerTimer == nil {
            spinnerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20,
                                                repeats: true) { [weak self] _ in
                guard let self else { return }
                self.tabStrip.spinnerPhase += 0.05
                for tab in self.tabs where tab.isLoading {
                    tab.progress = tab.webView?.estimatedProgress ?? 0
                }
                if let t = self.currentTab {
                    self.urlBar.loadProgress = t.isLoading ? t.progress : 0
                }
                self.tabStrip.needsDisplay = true
                self.sidebarTable.reloadData()
            }
        } else if !anyLoading, let t = spinnerTimer {
            t.invalidate()
            spinnerTimer = nil
            urlBar.loadProgress = 0
            tabStrip.needsDisplay = true
        }
    }

    func setLoading(_ loading: Bool, for webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        tab.isLoading = loading
        if !loading { tab.progress = 0 }
        updateLoadingAnimation()
        refreshTabStrip()
    }

    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        setLoading(true, for: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshTabStrip()
    }

    // MARK: - navigation delegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
        if let t = webView.title, !t.isEmpty {
            tab.title = t
        } else if NewTabPage.isNewTab(tab.url) {
            tab.title = "New Tab"
        }
        // A new-tab page has no URL of its own; leave the sentinel in place so the tab
        // does not adopt "about:blank" as its identity.
        if let u = webView.url, !NewTabPage.isNewTab(u) {
            tab.url = u
            Store.recordVisit(u, title: tab.title)
            if tab.id == foregroundId {
                urlBar.field.stringValue = u.absoluteString
                urlBar.isBookmarked = Store.isBookmarked(u)
                updateSecurityIndicator(for: tab)
            }
        }
        placeholder.isHidden = true
        placeholderLabel.isHidden = true
        setLoading(false, for: webView)
        enforceDarkExclusion(for: tab)
        updateNavButtons()
        refreshTabStrip()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        placeholder.isHidden = true; placeholderLabel.isHidden = true
        setLoading(false, for: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError e: Error) {
        placeholder.isHidden = true; placeholderLabel.isHidden = true
        setLoading(false, for: webView)
        // A cancelled navigation is normal (redirects, stopped loads); anything else
        // is worth surfacing rather than leaving the user on a blank page.
        let ns = e as NSError
        if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) {
            flash("could not load: \(ns.localizedDescription)")
        }
    }
}

enum BrowserApp {
    /// Without a main menu an AppKit app has no Cmd-Q, no Cmd-W, and no way to quit
    /// except killing it from a terminal.
    private static func installMenu(target: BrowserWindowController) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kestrel", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kestrel",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        for (t, sel, key, mods) in [
            ("Reopen Closed Tab", #selector(BrowserWindowController.undoCloseTab),
             "t", NSEvent.ModifierFlags([.command, .shift])),
        ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            fileMenu.addItem(i)
        }
        let newTab = NSMenuItem(title: "New Tab",
                                action: #selector(BrowserWindowController.newTabPressed),
                                keyEquivalent: "t")
        newTab.target = target
        fileMenu.addItem(newTab)
        let closeTab = NSMenuItem(title: "Close Tab",
                                  action: #selector(BrowserWindowController.closeSelectedTab),
                                  keyEquivalent: "w")
        closeTab.target = target
        fileMenu.addItem(closeTab)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        for (t, sel, key, mods) in [
            ("Find in Page…", #selector(BrowserWindowController.findInPage), "f",
             NSEvent.ModifierFlags.command),
            ("Zoom In", #selector(BrowserWindowController.zoomIn), "+", .command),
            ("Zoom Out", #selector(BrowserWindowController.zoomOut), "-", .command),
            ("Actual Size", #selector(BrowserWindowController.zoomReset), "0", .command),
            ("Bookmark This Page", #selector(BrowserWindowController.toggleBookmark), "d",
             .command),
        ] as [(String, Selector, String, NSEvent.ModifierFlags)] {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            viewMenu.addItem(i)
        }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (t, s, k) in [("Cut", #selector(NSText.cut(_:)), "x"),
                          ("Copy", #selector(NSText.copy(_:)), "c"),
                          ("Paste", #selector(NSText.paste(_:)), "v"),
                          ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: t, action: s, keyEquivalent: k)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApplication.shared.mainMenu = main
    }

    static func run() {
        let controller = BrowserWindowController()
        installMenu(target: controller)
        // Compile the blocklist once; WebKit caches the compiled rules in its own store.
        // Compilation is async. Opening tabs before it completes gives them no rule
        // list at all -- which is exactly why the starter tabs showed ads.
        ContentBlocker.compile { list in
            controller.blockerReady(list != nil, rules: ContentBlocker.ruleCount)
            controller.retrofitBlocker()
            ContentBlocker.loadCustomList { custom, note in
                controller.retrofitBlocker()
                if custom != nil || note.hasPrefix("custom blocklist failed") {
                    controller.customBlocklistReady(note)
                }
            }
            if controller.tabs.isEmpty && !controller.restoreSession() {
                controller.openTab(url: NewTabPage.url())
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Persist the session on quit so restore has something to work with.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in controller.saveSession() }
        withExtendedLifetime(controller) { NSApplication.shared.run() }
    }
}
