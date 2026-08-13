import AppKit

/// The address bar dropdown: history and bookmarks, ranked, under the field as you type.
///
/// `Store.suggestions(for:)` has existed since bookmarks were added — bookmarks first, then
/// history scored by visits over age, which is Firefox's frecency idea in miniature. Nothing
/// ever called it. This is the missing half: a list under the field, arrow keys to move
/// through it, Enter to take one.
///
/// Deliberately not a `WKWebView`: a browser with a memory budget should not spend a web
/// process on its own address bar.
final class SuggestionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    struct Row {
        let url: String
        let title: String
        let kind: Kind
        enum Kind { case bookmark, history, search }
    }

    private let panel: NSPanel
    private let table = NSTableView()
    private var rows: [Row] = []
    private weak var anchor: NSView?

    /// Called with the chosen URL string, or the raw query for a search row.
    var onChoose: ((String) -> Void)?

    var isVisible: Bool { panel.isVisible }
    var selection: Int { table.selectedRow }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let backing = NSVisualEffectView()
        backing.material = .popover
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 8
        backing.layer?.masksToBounds = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]
        let col = NSTableColumn(identifier: .init("s"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        backing.addSubview(scroll)
        panel.contentView = backing
    }

    // MARK: - showing

    func update(query: String, under field: NSView) {
        anchor = field
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return hide() }

        var found: [Row] = Store.suggestions(for: trimmed, limit: 6).map { url, title in
            Row(url: url, title: title,
                kind: Store.isBookmarked(URL(string: url) ?? URL(fileURLWithPath: "/"))
                    ? .bookmark : .history)
        }
        // A search row last, always, so the list never becomes a dead end when nothing
        // matches — and so pressing Down once has somewhere to go.
        if NewTabPage.resolve(trimmed)?.host == nil || !trimmed.contains(".") {
            found.append(Row(url: trimmed, title: "Search \(NewTabPage.searchEngineName)",
                             kind: .search))
        }
        guard !found.isEmpty else { return hide() }

        rows = found
        table.reloadData()
        table.deselectAll(nil)

        let h = min(CGFloat(rows.count) * table.rowHeight + 8, 260)
        guard let window = field.window else { return }
        let originInWindow = field.convert(NSPoint(x: 0, y: 0), to: nil)
        let screen = window.convertPoint(toScreen: originInWindow)
        panel.setFrame(NSRect(x: screen.x, y: screen.y - h - 2,
                              width: field.bounds.width, height: h), display: true)
        panel.contentView?.subviews.first?.frame = panel.contentView?.bounds ?? .zero
        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
    }

    /// Arrow keys and Enter, forwarded from the field's delegate. Returns true when the
    /// list consumed the key.
    func handle(_ selector: Selector) -> Bool {
        guard isVisible, !rows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(min(table.selectedRow + 1, rows.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(max(table.selectedRow - 1, 0))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard rows.indices.contains(table.selectedRow) else { return false }
            take(rows[table.selectedRow])
            return true
        default:
            return false
        }
    }

    private func select(_ i: Int) {
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func clicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        take(rows[table.clickedRow])
    }

    private func take(_ row: Row) {
        hide()
        onChoose?(row.url)
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 34))

        let icon = NSImageView(frame: NSRect(x: 8, y: 9, width: 16, height: 16))
        let symbol: String
        switch r.kind {
        case .bookmark: symbol = "star.fill"
        case .history:  symbol = "clock"
        case .search:   symbol = "magnifyingglass"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            icon.image = img
            icon.contentTintColor = r.kind == .bookmark ? .systemYellow : .secondaryLabelColor
        }
        v.addSubview(icon)

        let title = NSTextField(labelWithString: r.title.isEmpty ? r.url : r.title)
        title.frame = NSRect(x: 32, y: 17, width: v.bounds.width - 44, height: 15)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.autoresizingMask = [.width]
        v.addSubview(title)

        let sub = NSTextField(labelWithString: r.kind == .search ? r.url : r.url)
        sub.frame = NSRect(x: 32, y: 3, width: v.bounds.width - 44, height: 13)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        sub.autoresizingMask = [.width]
        v.addSubview(sub)
        return v
    }
}
