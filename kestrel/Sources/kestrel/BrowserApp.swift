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
    /// Nav controls live in a container so switching between horizontal and vertical
    /// tabs can move the whole bar; positioning them individually left a dead 38 pt
    /// gap where the hidden strip used to be.
    let navBar = NSView()
    let extensionBar = NSView()
    let sidebar = NSScrollView()
    let sidebarTable = NSTableView()
    var urlBar: URLBarView!
    let statusLabel = NSTextField(labelWithString: "")
    let memoryBar = MemoryBar()
    let budgetSlider = NSSlider()
    let budgetLabel = NSTextField(labelWithString: "")
    let capPopup = NSPopUpButton()

    public var tabs: [Tab] = []
    var nextId = 0
    var foregroundId = -1
    let scheduler = Scheduler(budgetBytes: Int64(Prefs.budgetMB) * 1024 * 1024,
                              perTabCapBytes: Int64(Prefs.perTabCapMB) * 1024 * 1024,
                              keepLive: 3)
    var timer: Timer?
    private var sampling = false
    var backButton: NSButton?
    var readerButton: NSButton?
    var forwardButton: NSButton?
    var qrPanel: NSPanel?
    var qrImage: NSImage?
    var flashUntil = Date.distantPast
    var addonsPopover: NSPopover?
    var taskManager: DevTools.TaskManagerController?
    var consoleController: DevTools.ConsoleController?
    var viewportPreset = 0
    var findBar: FindBar?
    var recentlyClosed: [(url: URL, title: String, image: Data?)] = []
    var spinnerTimer: Timer?
    var networkWindow: NetworkWindowController?
    let suggestions = SuggestionList()
    var devPanel: DevPanel?
    /// Remembered so reopening the panel returns it to the height you left it at.
    private var devPanelHeight: CGFloat = 320
    /// Session writes are cheap but not free; this throttles them to roughly every 10 s
    /// of ticks, plus the explicit saves on close and quit.
    private var ticksSinceSave = 0

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
        navBar.frame = NSRect(x: 0, y: H - stripH - navH, width: W, height: navH)
        navBar.autoresizingMask = [.width, .minYMargin]
        root.addSubview(navBar)
        let navY: CGFloat = 0          // relative to navBar
        var x: CGFloat = 10
        func navIcon(_ symbol: String, _ fallback: String, _ sel: Selector,
                     _ tip: String) -> NSButton {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: tip,
                                       size: 14, target: self, action: sel)
            b.frame = NSRect(x: x, y: navY + 8, width: 28, height: 26)
            x += 30
            navBar.addSubview(b)
            return b
        }
        backButton = navIcon("arrow.left", "\u{2190}", #selector(goBack), "Back")
        forwardButton = navIcon("arrow.right", "\u{2192}", #selector(goForward), "Forward")
        _ = navIcon("arrow.clockwise", "\u{21BB}", #selector(reload), "Reload")

        // Three grouped menus on the right, as in the reference: page tools, add-ons,
        // and the application menu.
        // Four icons now: reader, wrench, add-ons, menu. Adding the reader button
        // without widening this ran the hamburger 13 pt past the window edge, which
        // layouttest caught.
        let rightW: CGFloat = 141
        urlBar = URLBarView(frame: NSRect(x: x + 6, y: navY + 7,
                                          width: W - x - rightW - 22, height: 28))
        urlBar.autoresizingMask = [.width]
        urlBar.field.placeholderString =
            "Search \(NewTabPage.searchEngineName) or enter address"
        urlBar.field.target = self
        urlBar.field.action = #selector(navigate)
        urlBar.field.delegate = self
        urlBar.onQR = { [weak self] in self?.showQR() }
        urlBar.onBookmark = { [weak self] in self?.toggleBookmark() }
        navBar.addSubview(urlBar)

        // Extension toolbar buttons sit to the left of the built-in menus, where every
        // browser puts them. Width is decided by how many add-ons are enabled, so the
        // container is positioned and the URL bar trimmed in refreshExtensionButtons().
        extensionBar.frame = NSRect(x: W - rightW - 8, y: navY + 8, width: 0, height: 26)
        extensionBar.autoresizingMask = [.minXMargin]
        navBar.addSubview(extensionBar)

        var bx = W - rightW - 8
        func rightIcon(_ symbol: String, _ fallback: String, _ sel: Selector, _ tip: String) {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: tip,
                                       size: 15, target: self, action: sel)
            b.frame = NSRect(x: bx, y: navY + 8, width: 30, height: 26)
            b.autoresizingMask = [.minXMargin]
            bx += 33
            navBar.addSubview(b)
        }
        readerButton = Toolbar.iconButton(symbol: "doc.plaintext", fallback: "\u{2261}",
                                          tip: "Reader view", size: 15,
                                          target: self, action: #selector(toggleReader))
        readerButton?.frame = NSRect(x: bx, y: navY + 8, width: 30, height: 26)
        readerButton?.autoresizingMask = [.minXMargin]
        readerButton?.isHidden = true
        if let readerButton { navBar.addSubview(readerButton) }
        bx += 33

        rightIcon("wrench.adjustable", "\u{2692}", #selector(pageToolsMenu),
                  "Developer tools — inspector, task manager, console")
        rightIcon("puzzlepiece.extension", "\u{29C9}", #selector(addonsMenu),
                  "Add-ons — install and manage Firefox extensions")
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
        navBar.frame = NSRect(x: 0, y: H - topInset, width: W, height: navH)
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


    // MARK: - screenshots











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
        add("Toggle Developer Panel", #selector(toggleDevPanel), "i", [.command, .option])
        add("Network (window)", #selector(openNetworkPanel), "e", [.command, .option])
        add("Memory (about:memory)", #selector(openMemoryPage))
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
        menu.addItem(.separator())
        add("Protections…", #selector(showProtections))
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
        if ContainerStore.isSupported {
            let cItem = NSMenuItem(title: "New Container Tab", action: nil, keyEquivalent: "")
            let cMenu = NSMenu()
            for (i, c) in ContainerStore.all.enumerated() {
                let item = NSMenuItem(title: c.name, action: #selector(newContainerTab(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = i
                let dot = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                    c.color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
                }
                item.image = dot
                cMenu.addItem(item)
            }
            cItem.submenu = cMenu
            menu.addItem(cItem)
        }
        add("Vertical Tabs", #selector(toggleVerticalTabs),
            state: Prefs.verticalTabs ? .on : .off)
        add("Memory…", #selector(openMemoryPage))

        let importItem = NSMenuItem(title: "Import From…", action: nil, keyEquivalent: "")
        let importMenu = NSMenu()
        for (i, src) in Migration.sources.enumerated() {
            let item = NSMenuItem(title: src.name, action: #selector(importFrom(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = i
            item.isEnabled = src.available()
            importMenu.addItem(item)
        }
        importItem.submenu = importMenu
        menu.addItem(importItem)
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
            let stem = tab.url.host?.replacingOccurrences(of: ".", with: "-") ?? "page"
            panel.nameFieldStringValue = stem + ".webarchive"
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

    /// The page reports scroll, form contents and network activity through these.
    /// Registered once per web view; adding the same name twice traps.
    func attachPageHandlers(to tab: Tab) {
        guard let wv = tab.webView, !tab.handlersAttached else { return }
        tab.handlersAttached = true
        let ucc = wv.configuration.userContentController
        ucc.add(PageMessageHandler(browser: self, tab: tab), name: SessionStore.messageName)
        ucc.add(PageMessageHandler(browser: self, tab: tab), name: NetworkMonitor.messageName)
    }

    func saveSession(waitForIt: Bool = false) {
        Store.saveSession(tabs.compactMap { tab in
            guard !NewTabPage.isNewTab(tab.url) else { return nil }
            // An add-on's own pages are keyed by a per-install UUID, so a restored
            // webkit-extension:// URL points at nothing and the tab comes back blank.
            guard tab.url.scheme != "webkit-extension" else { return nil }
            return Store.SessionTab(url: tab.url.absoluteString, title: tab.title,
                                    interactionState: tab.sessionImage
                                        ?? (tab.webView?.interactionState as? Data),
                                    pinned: tab.pinned,
                                    scrollX: tab.pageState.scrollX,
                                    scrollY: tab.pageState.scrollY,
                                    formValues: tab.pageState.values,
                                    containerID: tab.container?.id.uuidString)
        }, waitForIt: waitForIt)
        Store.flush(waitForIt: waitForIt)
    }

    func restoreSession() -> Bool {
        let saved = Store.loadSession()
        guard !saved.isEmpty else { return false }
        for st in saved {
            guard let url = URL(string: st.url) else { continue }
            let tab = Tab(id: nextId, url: url, title: st.title)
            tab.sessionImage = st.interactionState
            tab.pinned = st.pinned
            tab.pageState = SessionStore.PageState(scrollX: st.scrollX, scrollY: st.scrollY,
                                                   values: st.formValues)
            tab.hasUnsubmittedInput = tab.pageState.hasInput
            // A container tab has to come back in the same jar or the restore is a lie.
            if let cid = st.containerID, let uuid = UUID(uuidString: cid) {
                tab.container = ContainerStore.all.first { $0.id == uuid }
            }
            nextId += 1
            tabs.append(tab)
        }
        // Restored tabs start COLD: the whole point is that reopening 20 tabs should not
        // cost 20 live pages. They load when selected.
        if let first = tabs.first { select(first) }
        refreshTabStrip()
        let withState = saved.filter { !$0.formValues.isEmpty }.count
        flash("restored \(saved.count) tab(s) — they load when you open them"
              + (withState > 0 ? ", \(withState) with unsent form input" : ""))
        return true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { urlBar.noteFocusChanged() }

    func controlTextDidEndEditing(_ obj: Notification) {
        urlBar.noteFocusChanged()
        suggestions.hide()
    }

    /// History and bookmarks under the address bar as you type.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlBar.field else { return }
        suggestions.onChoose = { [weak self] choice in
            guard let self else { return }
            self.urlBar.field.stringValue = choice
            self.navigate()
        }
        suggestions.update(query: urlBar.field.stringValue, under: urlBar)
    }

    /// Arrow keys belong to the list while it is open; everything else is the field's.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        suggestions.handle(selector)
    }


    // MARK: - tabs

    private func updateBudgetLabel() {
        budgetLabel.stringValue = String(format: "budget  %.1f GB",
                                         budgetSlider.doubleValue / 1024)
    }

    func openTab(url: URL, container: Container? = nil) {
        let tab = Tab(id: nextId, url: url)
        tab.container = container
        nextId += 1
        tabs.append(tab)
        select(tab)
        extensionsDidOpen(tab)
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
        extensionsDidClose(closing)
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
        let previous = currentTab
        // The highlight overlay belongs to the page being inspected; leaving it behind
        // paints a blue box on a tab nobody is inspecting any more.
        if previous?.id != tab.id, devPanel != nil {
            previous?.webView?.evaluateJavaScript(
                "var b=document.getElementById('__kestrel_highlight'); if(b) b.remove();")
        }
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
        attachPageHandlers(to: tab)
        if let page = tab.webView as? PageWebView {
            page.onInspect = { [weak self] path in self?.openDevPanel(inspecting: path) }
            page.onViewSource = { [weak self] in self?.viewSource() }
        }
        devPanel?.attach(to: tab)
        layoutDevPanel()
        tab.lastUsed = Date()
        tab.uses += 1
        foregroundId = tab.id
        if ms > 0 { tab.lastRestoreMs = ms }
        urlBar.field.stringValue = NewTabPage.isNewTab(tab.url) ? "" : tab.url.absoluteString
        if AboutMemory.isMemoryPage(tab.url) { refreshMemoryPages() }
        urlBar.isBookmarked = Store.isBookmarked(tab.url)
        updateSecurityIndicator(for: tab)

        placeholder.removeFromSuperview(); webContainer.addSubview(placeholder)
        placeholderLabel.removeFromSuperview(); webContainer.addSubview(placeholderLabel)

        updateNavButtons()
        refreshTabStrip()
        if previous?.id != tab.id { extensionsDidActivate(tab, previous: previous) }
        refreshExtensionButtons()   // per-tab badges and enabled state
        updateReaderButton()
    }

    func updateSecurityIndicator(for tab: Tab) {
        if NewTabPage.isNewTab(tab.url) { urlBar.security = .blank }
        else if tab.url.scheme == "https" { urlBar.security = .secure }
        else { urlBar.security = .insecure }
    }

    func refreshTabStrip() {
        sidebarTable.reloadData()
        tabStrip.items = tabs.map {
            TabStripView.Item(id: $0.id,
                              title: $0.title.isEmpty ? "New Tab" : $0.title,
                              state: $0.state, bytes: $0.currentBytes,
                              isCurrent: $0.id == foregroundId, pinned: $0.pinned,
                              isLoading: $0.isLoading,
                              containerColor: $0.container?.color,
                              containerName: $0.container?.name)
        }
    }

    // MARK: - the loop that makes it a budget



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

    /// Renders kestrel://memory into whichever tabs are showing it.
    func refreshMemoryPages() {
        // Nothing to do at all when no memory tab is open — this runs on every tick.
        let pages = tabs.filter { AboutMemory.isMemoryPage($0.url) }
        guard !pages.isEmpty else { return }

        var payload: String?
        for tab in pages {
            guard let wv = tab.webView else { continue }
            if tab.title != "Memory" { tab.title = "Memory" }
            if !tab.memoryShellLoaded {
                tab.memoryShellLoaded = true
                wv.loadHTMLString(AboutMemory.html(tabs: tabs, scheduler: scheduler,
                                                   foregroundId: foregroundId),
                                  baseURL: nil)
                continue
            }
            // The document is already there; only the numbers change. Reloading it every
            // 1.5 s threw away the scroll position and re-parsed the page 40 times a
            // minute — on the page whose entire job is to report what things cost.
            let json = payload ?? AboutMemory.payload(tabs: tabs, scheduler: scheduler,
                                                      foregroundId: foregroundId)
            payload = json
            wv.evaluateJavaScript("typeof updateMemory === 'function' && updateMemory(\(json))")
        }
    }

    @objc func openMemoryPage() {
        if let existing = tabs.first(where: { AboutMemory.isMemoryPage($0.url) }) {
            select(existing)
        } else {
            openTab(url: AboutMemory.sentinel)
        }
        refreshMemoryPages()
    }

    /// Bookmarks and history from another browser on this Mac. Read-only, and it says
    /// what it took rather than importing silently.
    @objc func importFrom(_ sender: NSMenuItem) {
        let sources = Migration.sources
        guard sources.indices.contains(sender.tag) else { return }
        let source = sources[sender.tag]
        flash("reading \(source.name)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let added = Migration.importFrom(source)
            DispatchQueue.main.async { [weak self] in
                if added.bookmarks == 0 && added.history == 0 {
                    self?.flash("nothing new from \(source.name) — "
                                + "already imported, or its files are not readable")
                } else {
                    self?.flash("imported \(added.bookmarks) bookmark(s) and "
                                + "\(added.history) history entr(ies) from \(source.name)")
                }
            }
        }
    }

    /// What is protecting this page, and who is responsible for each item.
    @objc func showProtections() {
        let host = currentTab?.url.host ?? ""
        let items = Protections.items(for: currentTab)
        let body = items.map { item -> String in
            let mark = item.state == .on ? "\u{2713}" : item.state == .off ? "\u{2717}" : "?"
            return "\(mark)  \(item.title)  [\(item.owner.rawValue)]\n     \(item.detail)"
        }.joined(separator: "\n\n")

        Protections.siteData(for: host) { [weak self] storage in
            let alert = NSAlert()
            alert.messageText = host.isEmpty ? "Protections" : "Protections — \(host)"
            alert.informativeText = body + (storage.isEmpty ? "" : "\n\n" + storage)
            alert.addButton(withTitle: "Done")
            if !host.isEmpty { alert.addButton(withTitle: "Clear Site Data") }
            if alert.runModal() == .alertSecondButtonReturn, !host.isEmpty {
                Protections.clearSiteData(for: host) {
                    self?.flash("cleared stored data for \(host)")
                }
            }
        }
    }

    /// Some add-ons ship an options page that is only a shell around an iframe of another
    /// of their own pages — Adblock Plus frames `desktop-options.html`. WebKit refuses that
    /// subframe unless the add-on declared `web_accessible_resources`, which Firefox and
    /// Chrome do not require, so the shell renders blank.
    ///
    /// Rather than rewrite the add-on's manifest to widen what any web page may read — a
    /// security change made on the user's behalf — the tab goes to the inner page itself.
    /// Same content, same origin, nothing loosened.
    /// Checked more than once, because the shell's script is usually deferred: at
    /// `didFinish` the iframe often carries only a `data-src`, and the real `src` appears a
    /// beat later. A single look at load time sees nothing and concludes wrongly.
    func unwrapExtensionFrame(_ tab: Tab, _ webView: WKWebView, tries: Int) {
        let js = """
        (function () {
          var frames = document.querySelectorAll('iframe');
          if (frames.length !== 1) return '';
          var f = frames[0];
          var src = f.getAttribute('src') || '';
          if (!src) return '';
          try {
            var d = f.contentDocument;
            if (d && d.URL !== 'about:blank') return '';   // a loaded frame is left alone
          } catch (e) { return ''; }
          return src;   // resolved by the browser against the tab's URL, not location
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            // Resolved here rather than in the page: `location.href` is not always the
            // document's real URL — a page loaded from a string reports a masked URL — and
            // the tab knows where it actually is.
            guard let src = value as? String, !src.isEmpty,
                  let url = URL(string: src, relativeTo: tab.url)?.absoluteURL,
                  url.scheme == "webkit-extension", tab.url != url
            else {
                if tries > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard tab.webView === webView else { return }
                        self?.unwrapExtensionFrame(tab, webView, tries: tries - 1)
                    }
                }
                return
            }
            tab.url = url
            webView.load(URLRequest(url: url))
            self?.flash("opened the add-on's own page directly — its frame could not load")
        }
    }

    func updateReaderButton() {
        readerButton?.isHidden = !(currentTab?.readerAvailable ?? false)
        readerButton?.contentTintColor =
            (currentTab?.readerActive ?? false) ? .controlAccentColor : nil
    }

    /// Reader view. Turning it on replaces the document with the extracted article, which
    /// is a fraction of the page — the only feature here that shrinks a tab without
    /// demoting it.
    @objc func toggleReader() {
        guard let tab = currentTab, let wv = tab.webView else { return }
        if tab.readerActive {
            tab.readerActive = false
            if let back = tab.preReaderURL {
                tab.url = back
                wv.load(URLRequest(url: back))
            } else {
                wv.reload()
            }
            updateReaderButton()
            return
        }
        wv.evaluateJavaScript(ReaderView.extractScript) { [weak self] raw, _ in
            guard let article = ReaderView.parse(raw) else {
                self?.flash("no article found on this page")
                tab.readerAvailable = false
                self?.updateReaderButton()
                return
            }
            tab.preReaderURL = tab.url
            tab.readerActive = true
            wv.loadHTMLString(ReaderView.page(article, url: tab.url), baseURL: tab.url)
            self?.flash("reader view — \(article.words) words")
            self?.updateReaderButton()
        }
    }

    @objc func newContainerTab(_ sender: NSMenuItem) {
        let all = ContainerStore.all
        guard all.indices.contains(sender.tag) else { return }
        let c = all[sender.tag]
        openTab(url: NewTabPage.url(), container: c)
        flash("\(c.name) container — its own cookies, cache and storage")
    }

    /// Opens the docked panel, optionally on a specific element.
    func openDevPanel(inspecting path: String? = nil) {
        if devPanel == nil {
            let p = DevPanel(frame: NSRect(x: 0, y: 0, width: webContainer.bounds.width,
                                           height: devPanelHeight))
            p.autoresizingMask = [.width]
            p.browser = self
            p.onClose = { [weak self] in self?.closeDevPanel() }
            p.onHeightChange = { [weak self] h in
                guard let self else { return }
                self.devPanelHeight = min(max(DevPanel.minHeight, h),
                                          self.webContainer.bounds.height - 80)
                self.layoutDevPanel()
            }
            webContainer.addSubview(p)
            devPanel = p
            // The web view's autoresizing would otherwise grow it back over the panel on
            // the next window resize.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.layoutDevPanel() } }
        }
        devPanel?.inspect(path: path, in: currentTab)
        NetworkMonitor.setCapturing(true, tabs: tabs)
        layoutDevPanel()
    }

    @objc func toggleDevPanel() {
        if devPanel == nil { openDevPanel() } else { closeDevPanel() }
    }

    func closeDevPanel() {
        devPanel?.removeFromSuperview()
        devPanel = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification,
                                                  object: window)
        currentTab?.webView?.autoresizingMask = [.width, .height]
        // Take the highlight overlay with it, or the page keeps a blue box on it.
        currentTab?.webView?.evaluateJavaScript(
            "var b=document.getElementById('__kestrel_highlight'); if(b) b.remove();")
        layoutDevPanel()
    }

    /// The panel takes its height off the bottom of the web view rather than floating
    /// over it: a tool that covers the thing it describes is not much of a tool.
    func layoutDevPanel() {
        let h = webContainer.bounds.height
        guard let panel = devPanel else {
            currentTab?.webView?.frame = webContainer.bounds
            placeholder.frame = webContainer.bounds
            return
        }
        let ph = min(max(DevPanel.minHeight, devPanelHeight), h - 80)
        panel.frame = NSRect(x: 0, y: 0, width: webContainer.bounds.width, height: ph)
        let above = NSRect(x: 0, y: ph, width: webContainer.bounds.width, height: h - ph)
        // Height is managed here, not by the autoresizing mask, or the web view springs
        // back over the panel on the next resize.
        currentTab?.webView?.autoresizingMask = [.width]
        currentTab?.webView?.frame = above
        placeholder.frame = above
        panel.refresh()
    }

    @objc func openNetworkPanel() {
        if networkWindow == nil { networkWindow = NetworkWindowController() }
        // Instrumentation starts when someone opens the panel, not when the browser does.
        NetworkMonitor.setCapturing(true, tabs: tabs)
        networkWindow?.show()
    }

    func tick() {
        sampleMemory()
        applyBudgetAndRefresh()
        refreshMemoryPages()
        devPanel?.refresh()
        // Firefox writes the session periodically rather than only at quit, so a crash
        // costs seconds of state instead of the whole window. ~10 s at this tick rate.
        ticksSinceSave += 1
        if ticksSinceSave >= 7 { ticksSinceSave = 0; saveSession() }
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

    /// Catches links to add-ons before WebKit tries to render one, and gives AMO the
    /// user agent it insists on.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        // Only AMO sees a Firefox UA, and only while it is the page being loaded. It
        // gates its install button on the UA and otherwise offers to install Firefox.
        if action.targetFrame?.isMainFrame ?? true {
            webView.customUserAgent = ExtensionWeb.isAddonSite(url)
                ? ExtensionWeb.firefoxUserAgent : nil
        }
        if let url, ExtensionWeb.isExtensionArchive(url) {
            decisionHandler(.cancel)
            downloadAndInstallExtension(from: url)
            return
        }
        // WebKit requires the web view to be swapped when navigating into an extension's
        // own pages, so a link to one is moved into a tab built for it.
        if #available(macOS 15.4, *), let url, url.scheme == "webkit-extension",
           webView.configuration.webExtensionController != nil,
           tabs.first(where: { $0.webView === webView })?.extensionConfig == nil {
            decisionHandler(.cancel)
            openExtensionPage(url)
            return
        }
        decisionHandler(.allow)
    }

    /// The URL is not always the tell — AMO serves add-ons from paths without a `.xpi`
    /// suffix — so the response MIME type gets the same treatment.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        NetworkMonitor.recordNavigation(response.response)
        if ExtensionWeb.isExtensionMIME(response.response), let url = response.response.url {
            decisionHandler(.cancel)
            downloadAndInstallExtension(from: url)
            return
        }
        decisionHandler(.allow)
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
        if let tab = tabs.first(where: { $0.webView === webView }) {
            // A real navigation replaces the reader document, so the state it describes is
            // gone. Leaving the flag set left the button lit on an ordinary page and made
            // the next click try to "leave" a reader view that was not there.
            if tab.readerActive, webView.url != nil { tab.readerActive = false }
            if tab.pageState.hasInput { tab.restorePending = true }
            if let u = webView.url, !NewTabPage.isNewTab(u) { tab.url = u }
            extensionsDidUpdate(tab, loading: true)
        }
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
        // interactionState restores scroll for a live tab; a tab that came back from COLD
        // or from a previous run needs its form contents put back explicitly.
        if tab.pageState.hasInput || tab.pageState.scrollY > 0 {
            let state = tab.pageState
            webView.evaluateJavaScript(SessionStore.restoreScript(state)) { [weak self] n, _ in
                tab.restorePending = false
                if let n = n as? Int, n > 0 {
                    self?.flash("restored \(n) field(s) you had filled in")
                }
            }
        } else {
            tab.restorePending = false
        }
        extensionsDidUpdate(tab, loading: false)
        if tab.extensionConfig != nil { unwrapExtensionFrame(tab, webView, tries: 4) }
        // Is this an article? Asked on every load, so the reader button is only offered
        // where it would work.
        if !tab.readerActive {
            webView.evaluateJavaScript(ReaderView.availabilityScript) { [weak self] v, _ in
                tab.readerAvailable = (v as? Bool) ?? false
                if tab.id == self?.foregroundId { self?.updateReaderButton() }
            }
        }
        updateNavButtons()
        refreshTabStrip()
        refreshExtensionButtons()   // badges often change on load
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

    static func run(startURL: URL? = nil) {
        let controller = BrowserWindowController()
        installMenu(target: controller)
        DispatchQueue.main.async {
            if let startURL {
                controller.openTab(url: startURL)
            } else if controller.tabs.isEmpty && !controller.restoreSession() {
                controller.openTab(url: NewTabPage.url())
            }
            // After the first tab exists: an extension asking `tabs.query` during load
            // should see a window with something in it.
            controller.startExtensions()
        }
        // Crash detection, the way Firefox does it: a flag that only exists while running.
        if SessionStore.lastRunCrashed() {
            controller.flash("Kestrel did not exit cleanly last time — session restored")
        }
        SessionStore.markRunning()
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Persist the session on quit so restore has something to work with.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // On the way out the write has to complete before the process does.
            controller.saveSession(waitForIt: true)
            SessionStore.markCleanExit()
        }
        withExtendedLifetime(controller) { NSApplication.shared.run() }
    }
}
