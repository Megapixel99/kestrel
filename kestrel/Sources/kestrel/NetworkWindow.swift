import AppKit

/// The network panel: a request list, and the headers for whichever row is selected.
///
/// Laid out like Firefox's, because that is the shape the columns want: status, method,
/// domain, file, type, transferred, size, and a `source` column this one needs and
/// Firefox's does not — see `NetworkMonitor` for why a row's headers may be unavailable.
final class NetworkWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = NSTextField(labelWithString: "")
    private let filterField = NSTextField()
    private let recordButton = NSButton()
    private var rows: [NetworkMonitor.Entry] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Network"
        window.contentMinSize = NSSize(width: 760, height: 360)

        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]
        let W = root.bounds.width, H = root.bounds.height
        let toolbarH: CGFloat = 34, statusH: CGFloat = 26

        // --- toolbar ---
        recordButton.frame = NSRect(x: 10, y: H - toolbarH + 4, width: 90, height: 24)
        recordButton.bezelStyle = .rounded
        recordButton.title = NetworkMonitor.isRecording ? "Pause" : "Record"
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.autoresizingMask = [.minYMargin]
        root.addSubview(recordButton)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        clear.frame = NSRect(x: 106, y: H - toolbarH + 4, width: 70, height: 24)
        clear.bezelStyle = .rounded
        clear.autoresizingMask = [.minYMargin]
        root.addSubview(clear)

        filterField.frame = NSRect(x: 184, y: H - toolbarH + 4, width: 240, height: 24)
        filterField.placeholderString = "Filter URLs"
        filterField.target = self
        filterField.action = #selector(reload)
        filterField.autoresizingMask = [.minYMargin]
        root.addSubview(filterField)

        // --- request list, left half ---
        let listW = (W * 0.62).rounded()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: statusH, width: listW,
                                                height: H - toolbarH - statusH))
        scroll.autoresizingMask = [.height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        for (id, title, w) in [("status", "Status", 52), ("method", "Method", 60),
                               ("domain", "Domain", 150), ("file", "File", 190),
                               ("type", "Type", 62), ("transferred", "Transferred", 80),
                               ("size", "Size", 70), ("time", "Time", 62),
                               ("source", "Source", 74)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 18
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        root.addSubview(scroll)

        // --- headers, right half ---
        let dScroll = NSScrollView(frame: NSRect(x: listW + 1, y: statusH,
                                                 width: W - listW - 1,
                                                 height: H - toolbarH - statusH))
        dScroll.autoresizingMask = [.width, .height]
        dScroll.hasVerticalScroller = true
        dScroll.borderType = .noBorder
        // An NSTextView made with NSTextView() has a zero frame, and a zero-sized
        // documentView draws nothing at all — not even its placeholder text. That is
        // what made this pane look like it was failing to populate.
        detail.frame = NSRect(origin: .zero, size: dScroll.contentSize)
        detail.minSize = NSSize(width: 0, height: dScroll.contentSize.height)
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.containerSize =
            NSSize(width: dScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        detail.textContainer?.widthTracksTextView = true
        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textContainerInset = NSSize(width: 10, height: 8)
        detail.string = "Select a request."
        dScroll.documentView = detail
        root.addSubview(dScroll)

        summary.frame = NSRect(x: 10, y: 5, width: W - 20, height: 16)
        summary.autoresizingMask = [.width]
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        root.addSubview(summary)

        window.contentView = root
        window.center()

        NetworkMonitor.onChange = { [weak self] in self?.reload() }
        reload()
    }

    deinit { NetworkMonitor.onChange = nil }

    func show() { window.makeKeyAndOrderFront(nil) }

    @objc private func toggleRecording() {
        NetworkMonitor.isRecording.toggle()
        recordButton.title = NetworkMonitor.isRecording ? "Pause" : "Record"
    }

    @objc private func clearAll() {
        NetworkMonitor.clear()
        detail.string = "Select a request."
    }

    @objc func reload() {
        let needle = filterField.stringValue.lowercased()
        rows = NetworkMonitor.entries.filter {
            needle.isEmpty || $0.url.absoluteString.lowercased().contains(needle)
        }
        let selected = table.selectedRow
        table.reloadData()
        if rows.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        let t = NetworkMonitor.totals
        summary.stringValue =
            "\(rows.count) shown of \(t.count) requests · "
            + "\(bytes(t.transferred)) transferred · \(bytes(t.size)) decoded"
            + (NetworkMonitor.isRecording ? "" : " · paused")
    }

    private func bytes(_ n: Int) -> String {
        if n <= 0 { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f kB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else {
            return nil
        }
        let e = rows[row]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        switch id {
        case "status":
            label.stringValue = e.status.map(String.init) ?? "—"
            if let s = e.status {
                label.textColor = s >= 400 ? .systemRed : s >= 300 ? .systemOrange : .systemGreen
            } else {
                label.textColor = .tertiaryLabelColor
            }
        case "method":      label.stringValue = e.method
        case "domain":      label.stringValue = e.host
        case "file":        label.stringValue = e.file
        case "type":        label.stringValue = e.type
        case "transferred": label.stringValue = bytes(e.transferred)
        case "size":        label.stringValue = bytes(e.size)
        case "time":
            label.stringValue = e.durationMs > 0
                ? String(format: "%.0f ms", e.durationMs) : "—"
        case "source":
            label.stringValue = e.source.rawValue
            label.textColor = .secondaryLabelColor
        default: break
        }
        return label
    }

    @objc private func rowClicked() { showSelection() }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    private func showSelection() {
        let r = table.selectedRow
        guard rows.indices.contains(r) else { return }
        detail.string = describe(rows[r])
        detail.scrollToBeginningOfDocument(nil)
    }

    private func describe(_ e: Entry) -> String {
        var out = "\(e.method) \(e.url.absoluteString)\n\n"
        out += "Status:      \(e.status.map(String.init) ?? "not observable")\n"
        out += "Type:        \(e.type)\n"
        out += "Transferred: \(bytes(e.transferred))\n"
        out += "Size:        \(bytes(e.size))\n"
        if e.durationMs > 0 { out += String(format: "Duration:    %.1f ms\n", e.durationMs) }
        out += "Observed by: \(e.source.rawValue)\n"

        func section(_ title: String, _ h: [String: String]) -> String {
            guard !h.isEmpty else { return "" }
            var s = "\n\(title) (\(h.count))\n"
            for k in h.keys.sorted() { s += "  \(k): \(h[k] ?? "")\n" }
            return s
        }
        out += section("Request Headers", e.requestHeaders)
        out += section("Response Headers", e.responseHeaders)

        if e.requestHeaders.isEmpty && e.responseHeaders.isEmpty {
            out += """

            No headers for this request.

            WKWebView exposes no request observer, so headers are only available where
            something hands them over: fetch and XMLHttpRequest, which the page makes
            through wrappers Kestrel installs, and the main document, whose HTTPURLResponse
            arrives in the navigation delegate. A script, stylesheet or image fetched by
            the engine itself is visible to PerformanceObserver — which is where this row's
            size and timing came from — but its headers are not observable from here.
            """
        }
        return out
    }

    typealias Entry = NetworkMonitor.Entry
}
