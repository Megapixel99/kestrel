import AppKit

/// Userscript dashboard, in the shape Tampermonkey uses: a table of installed scripts
/// with enable toggles and per-script detail.
///
/// Tampermonkey itself is GPLv3 and only open-source up to 2.9, so nothing here is
/// derived from it. The *metadata block* is a published specification, and that is what
/// this reads.
final class ScriptManagerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private var scripts: [UserScript] = []
    weak var browser: BrowserWindowController?

    init(browser: BrowserWindowController?) {
        self.browser = browser
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Userscripts"

        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]

        let header = NSTextField(labelWithString: "Installed Userscripts")
        header.frame = NSRect(x: 14, y: root.bounds.height - 32, width: 300, height: 20)
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        header.autoresizingMask = [.minYMargin]
        root.addSubview(header)

        for (title, sel, x) in [("Open Folder", #selector(openFolder), CGFloat(600)),
                                ("New Script", #selector(newScript), CGFloat(700))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: root.bounds.height - 36, width: 96, height: 26)
            b.autoresizingMask = [.minXMargin, .minYMargin]
            b.bezelStyle = .rounded
            root.addSubview(b)
        }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 34, width: root.bounds.width,
                                                height: root.bounds.height - 34 - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        for (id, t, w) in [("enabled", "Enabled", 62), ("name", "Name", 260),
                           ("run", "Run at", 110), ("sites", "Sites", 300)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = t; c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        root.addSubview(scroll)

        let note = NSTextField(labelWithString:
            "~/.kestrel/userscripts/*.user.js  ·  @name @match @include @run-at supported"
            + "  ·  reopen a tab to apply changes")
        note.frame = NSRect(x: 14, y: 9, width: root.bounds.width - 28, height: 16)
        note.autoresizingMask = [.width]
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        root.addSubview(note)

        window.contentView = root
    }

    func show() {
        reload()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        scripts = UserScriptStore.loadAll()
        table.reloadData()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(UserScriptStore.dir)
    }

    @objc private func newScript() {
        let template = """
        // ==UserScript==
        // @name        New Script
        // @match       https://example.com/*
        // @run-at      document-end
        // ==/UserScript==

        console.log('hello from a userscript');
        """
        let url = UserScriptStore.dir.appendingPathComponent("new-script.user.js")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { scripts.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < scripts.count else { return nil }
        let s = scripts[row]
        switch column?.identifier.rawValue {
        case "enabled":
            let sw = NSSwitch()
            sw.state = Prefs.isScriptEnabled(s.name) ? .on : .off
            sw.tag = row
            sw.target = self
            sw.action = #selector(toggleScript(_:))
            return sw
        case "name":  return label(s.name, mono: false)
        case "run":   return label(s.runAtStart ? "document-start" : "document-end")
        case "sites": return label(s.matches.joined(separator: ", "))
        default: return nil
        }
    }

    private func label(_ text: String, mono: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = mono ? .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                      : .systemFont(ofSize: 12)
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    @objc private func toggleScript(_ sender: NSSwitch) {
        guard sender.tag < scripts.count else { return }
        Prefs.setScript(scripts[sender.tag].name, enabled: sender.state == .on)
        browser?.flash("\(scripts[sender.tag].name) "
                       + (sender.state == .on ? "enabled" : "disabled")
                       + " — reopen tabs to apply")
    }
}
