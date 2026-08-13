import AppKit
import WebKit

/// The row of add-on buttons in the nav bar, and the browser-side hooks the extension
/// runtime calls back into.
extension BrowserWindowController {

    /// Rebuilds the toolbar buttons for every enabled add-on that declares an action.
    /// Called on load, on tab switch, and whenever an extension changes its own badge.
    func refreshExtensionButtons() {
        guard #available(macOS 15.4, *) else { return }
        MainActor.assumeIsolated {
            extensionBar.subviews.forEach { $0.removeFromSuperview() }

            let actions = ExtensionRuntime.shared.actions(for: currentTab)
            let size: CGFloat = 30
            extensionBar.frame.size.width = CGFloat(actions.count) * size
            extensionBar.frame.origin.x =
                navBar.bounds.width - 116 - extensionBar.frame.width

            for (i, entry) in actions.enumerated() {
                let b = NSButton(frame: NSRect(x: CGFloat(i) * size, y: 0,
                                               width: size - 4, height: 26))
                b.isBordered = false
                b.bezelStyle = .regularSquare
                b.imageScaling = .scaleProportionallyDown
                b.image = entry.action.icon(for: NSSize(width: 18, height: 18))
                if b.image == nil {
                    // An add-on with no usable icon still needs something clickable.
                    b.title = String(entry.action.label.prefix(1)).uppercased()
                    b.font = .systemFont(ofSize: 13, weight: .semibold)
                }
                b.toolTip = entry.action.label
                    + (entry.action.badgeText.isEmpty ? "" : " — \(entry.action.badgeText)")
                b.identifier = NSUserInterfaceItemIdentifier(entry.id)
                b.target = self
                b.action = #selector(extensionActionPressed(_:))
                b.menu = contextMenu(for: entry.id, action: entry.action)
                extensionBar.addSubview(b)
            }

            // The address bar gives up exactly the width the buttons took.
            if let urlBar {
                urlBar.frame.size.width =
                    extensionBar.frame.minX - urlBar.frame.minX - 6
            }
        }
    }

    /// Right-click on an add-on's button: whatever menu items the add-on itself provides,
    /// then its options page. Without this the options page is only reachable if the
    /// add-on happens to call `runtime.openOptionsPage()` itself.
    @available(macOS 15.4, *)
    private func contextMenu(for id: String, action: WKWebExtension.Action) -> NSMenu {
        let menu = NSMenu()
        for item in action.menuItems { menu.addItem(item) }
        if !action.menuItems.isEmpty { menu.addItem(.separator()) }

        let ctx = MainActor.assumeIsolated { ExtensionRuntime.shared.contexts[id] }
        if ctx?.optionsPageURL != nil {
            let options = NSMenuItem(title: "Options", action: #selector(extensionOptions(_:)),
                                     keyEquivalent: "")
            options.target = self
            options.representedObject = id
            menu.addItem(options)
        }
        let off = NSMenuItem(title: "Turn Off", action: #selector(extensionTurnOff(_:)),
                             keyEquivalent: "")
        off.target = self
        off.representedObject = id
        menu.addItem(off)
        return menu
    }

    @objc func extensionOptions(_ sender: NSMenuItem) {
        guard #available(macOS 15.4, *), let id = sender.representedObject as? String else { return }
        MainActor.assumeIsolated {
            guard let url = ExtensionRuntime.shared.contexts[id]?.optionsPageURL else {
                flash("this add-on has no options page")
                return
            }
            if !openExtensionPage(url) { flash("could not open the options page") }
        }
    }

    @objc func extensionTurnOff(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ext = ExtensionStore.installed().first(where: { $0.id == id }) else { return }
        disableExtension(ext)
        flash("\(ext.name) turned off")
    }

    @objc func extensionActionPressed(_ sender: NSButton) {
        guard #available(macOS 15.4, *), let id = sender.identifier?.rawValue else { return }
        MainActor.assumeIsolated {
            ExtensionRuntime.shared.performAction(id: id, tab: currentTab, from: sender)
        }
    }

    /// Opens an extension's own page — options, or anything under its base URL — in a tab
    /// built from that extension's configuration.
    ///
    /// WebKit is explicit about this and unforgiving: "navigations will be cancelled if a
    /// web view not configured with this configuration attempts to navigate to a URL that
    /// does originate from this extension's base URL." A normal tab therefore shows
    /// nothing at all, with no error — which is exactly how the options page failed.
    @available(macOS 15.4, *)
    @discardableResult
    func openExtensionPage(_ url: URL) -> Bool {
        let controller = MainActor.assumeIsolated { ExtensionRuntime.shared.controller }
        guard let ctx = controller.extensionContext(for: url),
              let cfg = ctx.webViewConfiguration else { return false }
        let tab = Tab(id: nextId, url: url,
                      title: ctx.webExtension.displayName ?? "Extension")
        tab.extensionConfig = cfg
        nextId += 1
        tabs.append(tab)
        select(tab)
        return true
    }

    /// Where an extension's popup should point when the extension asks to open it
    /// itself rather than being clicked.
    @available(macOS 15.4, *)
    func extensionAnchor(for context: WKWebExtensionContext) -> NSView? {
        let id = ExtensionRuntime.shared.contexts.first { $0.value === context }?.key
        return extensionBar.subviews.first { $0.identifier?.rawValue == id }
            ?? extensionBar.subviews.first
    }

    /// Installs an add-on from a file the user picked, showing what it asks for before
    /// enabling it. Nothing is granted until this dialog is accepted.
    @objc func installExtension() {
        let panel = NSOpenPanel()
        panel.title = "Install add-on"
        panel.message = "Choose a Firefox add-on (.xpi) or an unpacked extension folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.allowedFileTypes = ["xpi", "zip"]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let installed: ExtensionStore.Installed
        do {
            installed = try ExtensionStore.install(from: url)
        } catch {
            let a = NSAlert()
            a.messageText = "Could not install that add-on"
            a.informativeText = error.localizedDescription
            a.runModal()
            return
        }

        guard confirmPermissions(for: installed) else {
            ExtensionStore.remove(installed)
            return
        }
        Prefs.setExtensionEnabled(true, id: installed.id)
        enableExtension(installed)
    }

    /// The permission sheet. This is the consent step for everything the manifest asks
    /// for, so it lists the hosts explicitly rather than summarising them — "this add-on
    /// wants some permissions" is not consent.
    func confirmPermissions(for ext: ExtensionStore.Installed) -> Bool {
        var lines: [String] = []
        if !ext.apiPermissions.isEmpty {
            lines.append("Browser features: " + ext.apiPermissions.sorted().joined(separator: ", "))
        }
        let hosts = ext.hostPatterns.sorted()
        if hosts.contains("<all_urls>") || hosts.contains(where: { $0.hasPrefix("*://*/") }) {
            lines.append("Read and change data on ALL websites you visit")
        } else if !hosts.isEmpty {
            lines.append("Read and change data on: " + hosts.joined(separator: ", "))
        }
        if lines.isEmpty { lines.append("No special permissions requested.") }

        let gaps = ExtensionStore.gaps(in: ext)
        if !gaps.isEmpty {
            lines.append("")
            lines.append("Will not work here (Gecko-only): " + gaps.joined(separator: ", "))
        }

        let a = NSAlert()
        a.messageText = "Add \(ext.name) \(ext.version)?"
        a.informativeText = lines.joined(separator: "\n")
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func enableExtension(_ ext: ExtensionStore.Installed) {
        guard #available(macOS 15.4, *) else {
            flash("add-ons need macOS 15.4 — WebKit's extension runtime ships with it")
            return
        }
        MainActor.assumeIsolated {
            ExtensionRuntime.shared.browser = self
            ExtensionRuntime.shared.load(ext) { [weak self] error in
                guard let self else { return }
                if let error {
                    Prefs.setExtensionEnabled(false, id: ext.id)
                    self.flash("\(ext.name) failed to load — \(error)")
                } else {
                    self.flash("\(ext.name) is running — reload a tab to inject it")
                }
                self.refreshExtensionButtons()
            }
        }
    }

    func disableExtension(_ ext: ExtensionStore.Installed) {
        Prefs.setExtensionEnabled(false, id: ext.id)
        guard #available(macOS 15.4, *) else { return }
        MainActor.assumeIsolated {
            ExtensionRuntime.shared.unload(ext.id)
            refreshExtensionButtons()
        }
    }

    /// Called once at startup, after the first tab exists.
    func startExtensions() {
        guard #available(macOS 15.4, *) else { return }
        MainActor.assumeIsolated {
            ExtensionRuntime.shared.browser = self
            ExtensionRuntime.shared.loadEnabled { [weak self] in
                self?.refreshExtensionButtons()
            }
        }
    }
}
