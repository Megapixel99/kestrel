import AppKit
import WebKit

// MARK: - Inspector

/// A DOM tree, the selected element's computed styles, and a highlight in the page.
///
/// Built by asking the page for a snapshot rather than by driving WebKit's own inspector,
/// which cannot be docked into a host app's window. The snapshot is capped: a tree with
/// 40,000 nodes helps nobody, and building it eagerly would cost more than the page.
final class InspectorPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    final class Node {
        let label: String
        let path: String
        var children: [Node] = []
        init(label: String, path: String) { self.label = label; self.path = path }
    }

    weak var webView: WKWebView?
    private let outline = NSOutlineView()
    private let styles = NSTextView()
    private let breadcrumb = NSTextField(labelWithString: "")
    private var root: Node?
    private var lastReload = Date.distantPast

    /// How much of the document to walk. Deep enough for real pages, bounded enough that
    /// the snapshot stays cheap.
    private static let maxNodes = 1500
    private static let maxDepth = 14

    private let treeScroll = NSScrollView()
    private let styleScroll = NSScrollView()

    /// Positioned here rather than in `init`, because a pane built at one size and then
    /// resized by its container keeps init-time arithmetic and stops matching its own
    /// bounds — which layouttest caught the moment this pane was added to it.
    override func layout() {
        super.layout()
        let treeW = (bounds.width * 0.58).rounded()
        let crumbH: CGFloat = 20
        treeScroll.frame = NSRect(x: 0, y: crumbH, width: treeW, height: bounds.height - crumbH)
        styleScroll.frame = NSRect(x: treeW + 1, y: crumbH, width: bounds.width - treeW - 1,
                                   height: bounds.height - crumbH)
        breadcrumb.frame = NSRect(x: 8, y: 2, width: max(0, bounds.width - 16), height: 16)
        styles.textContainer?.containerSize =
            NSSize(width: styleScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let treeW = (frame.width * 0.58).rounded()
        let crumbH: CGFloat = 20

        let scroll = treeScroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("dom"))
        col.width = treeW - 20
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 17
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = outline
        addSubview(scroll)

        let sScroll = styleScroll
        sScroll.frame = NSRect(x: treeW + 1, y: crumbH, width: frame.width - treeW - 1,
                               height: frame.height - crumbH)
        sScroll.hasVerticalScroller = true
        styles.frame = NSRect(origin: .zero, size: sScroll.contentSize)
        styles.minSize = NSSize(width: 0, height: 0)
        styles.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        styles.isVerticallyResizable = true
        styles.isHorizontallyResizable = false
        styles.autoresizingMask = [.width]
        styles.textContainer?.containerSize =
            NSSize(width: sScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        styles.textContainer?.widthTracksTextView = true
        styles.isEditable = false
        styles.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        styles.textContainerInset = NSSize(width: 8, height: 6)
        styles.string = "Select an element."
        sScroll.documentView = styles
        addSubview(sScroll)

        breadcrumb.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        breadcrumb.textColor = .secondaryLabelColor
        breadcrumb.lineBreakMode = .byTruncatingHead
        addSubview(breadcrumb)
    }
    required init?(coder: NSCoder) { nil }

    /// Rebuilds only when the panel has been idle a moment: the browser ticks every 1.5 s
    /// and re-walking the DOM that often would be its own performance problem.
    func reloadIfNeeded() {
        // 2 s, from the measurement in sessiontest: the walk costs about 2 ms on a
        // 3,600-element page. The 4 s here before was a guess made when it cost 127 ms,
        // and guarding a cost nobody had measured.
        guard Date().timeIntervalSince(lastReload) > 2 else { return }
        reload()
    }

    func reload(selecting path: String? = nil) {
        lastReload = Date()
        guard let wv = webView else {
            root = nil; outline.reloadData()
            styles.string = "No page."
            return
        }
        wv.evaluateJavaScript(Self.snapshotScript) { [weak self] value, _ in
            guard let self, let json = value as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return }
            self.root = Self.build(obj)
            self.outline.reloadData()
            if let first = self.root { self.outline.expandItem(first, expandChildren: false) }
            if let path { self.select(path: path) }
        }
    }

    private func select(path: String) {
        guard let root else { return }
        // Searched exhaustively rather than descended by prefix. A path restarts at any
        // element with an id — `div#wrap` rather than `html > body > div#wrap` — so a
        // child's path is not always its parent's plus a segment, and prefix descent walks
        // straight past the node it wants.
        func find(_ n: Node) -> Node? {
            if n.path == path { return n }
            for c in n.children {
                if let hit = find(c) {
                    outline.expandItem(c)
                    return hit
                }
            }
            return nil
        }
        outline.expandItem(root)
        if let hit = find(root) {
            let row = outline.row(forItem: hit)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                showStyles(for: hit)
            }
        } else {
            // The element may be deeper than the snapshot cap; still show its styles.
            showStyles(for: Node(label: path, path: path))
        }
    }

    private func showStyles(for node: Node) {
        breadcrumb.stringValue = node.path
        highlight(node.path)
        webView?.evaluateJavaScript(Self.stylesScript(for: node.path)) { [weak self] v, _ in
            self?.styles.string = (v as? String) ?? "No element matched that path."
            self?.styles.scrollToBeginningOfDocument(nil)
        }
    }

    private func highlight(_ path: String) {
        webView?.evaluateJavaScript(Self.highlightScript(for: path))
    }

    // MARK: outline

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? (root == nil ? 0 : 1)
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? root!
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Node)?.children.isEmpty ?? true)
    }
    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        let label = NSTextField(labelWithString: (item as? Node)?.label ?? "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        showStyles(for: node)
    }

    // MARK: the page side

    private static func build(_ obj: Any) -> Node? {
        guard let d = obj as? [String: Any],
              let label = d["label"] as? String,
              let path = d["path"] as? String else { return nil }
        let n = Node(label: label, path: path)
        for c in (d["children"] as? [Any]) ?? [] {
            if let child = build(c) { n.children.append(child) }
        }
        return n
    }

    /// Test hooks: the scripts are the contract with the page, so the tests use the same
    /// text the pane does rather than a copy that can drift.
    static var snapshotScriptForTest: String { snapshotScript }
    static func stylesScriptForTest(_ path: String) -> String { stylesScript(for: path) }

    /// Walks the document once, building each node's path from its parent's.
    ///
    /// The first version measured 127 ms on a 3,600-element page, in the page's own
    /// process, every four seconds. Two reasons, both avoidable:
    ///
    /// - **`pathOf` re-walked the ancestor chain for every node**, scanning siblings at
    ///   each level to work out an `nth-of-type` index. A child's path is its parent's plus
    ///   one segment, so the whole thing is one downward pass if you carry it.
    /// - **`innerText` forces layout.** It is the property that respects CSS visibility, so
    ///   the engine has to lay the page out to answer. `textContent` does not, and a tree
    ///   label does not need the distinction.
    private static let snapshotScript = """
    (function () {
      var budget = \(maxNodes);

      function label(el, text) {
        var s = '<' + el.tagName.toLowerCase();
        if (el.id) s += ' id="' + el.id + '"';
        var cls = (el.getAttribute && el.getAttribute('class')) || '';
        if (cls) s += ' class="' + cls.slice(0, 48) + '"';
        s += '>';
        if (text) s += ' ' + text;
        return s;
      }

      // Indices for one parent's children, computed in a single pass over them.
      function segmentsFor(parent) {
        var kids = parent.children, counts = {}, totals = {}, segs = new Array(kids.length);
        for (var i = 0; i < kids.length; i++) {
          var tag = kids[i].tagName;
          totals[tag] = (totals[tag] || 0) + 1;
        }
        for (var j = 0; j < kids.length; j++) {
          var el = kids[j], t = el.tagName, lower = t.toLowerCase();
          counts[t] = (counts[t] || 0) + 1;
          segs[j] = el.id ? lower + '#' + el.id
                  : (totals[t] > 1 ? lower + ':nth-of-type(' + counts[t] + ')' : lower);
        }
        return segs;
      }

      function walk(el, depth, path) {
        if (budget-- <= 0 || depth > \(maxDepth)) return null;
        var text = '';
        if (el.children.length === 0) {
          // textContent, not innerText: innerText forces a layout pass.
          text = (el.textContent || '').trim().replace(/\\s+/g, ' ').slice(0, 40);
        }
        var node = { label: label(el, text), path: path, children: [] };
        var segs = segmentsFor(el);
        for (var i = 0; i < el.children.length; i++) {
          var seg = segs[i];
          // An id is unique, so a path may restart there rather than carrying the chain.
          var childPath = seg.indexOf('#') >= 0 ? seg : (path ? path + ' > ' + seg : seg);
          var c = walk(el.children[i], depth + 1, childPath);
          if (c) node.children.push(c);
        }
        return node;
      }

      return JSON.stringify(walk(document.documentElement, 0, 'html'));
    })();
    """

    private static func stylesScript(for path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          var el;
          try { el = document.querySelector('\(escaped)'); } catch (e) { el = null; }
          if (!el) return null;
          var cs = getComputedStyle(el);
          var r = el.getBoundingClientRect();
          var out = 'BOX\\n';
          out += '  ' + Math.round(r.width) + ' x ' + Math.round(r.height)
               + '  at (' + Math.round(r.left) + ', ' + Math.round(r.top) + ')\\n';
          out += '  margin ' + cs.marginTop + ' ' + cs.marginRight + ' '
               + cs.marginBottom + ' ' + cs.marginLeft + '\\n';
          out += '  padding ' + cs.paddingTop + ' ' + cs.paddingRight + ' '
               + cs.paddingBottom + ' ' + cs.paddingLeft + '\\n';
          out += '  border ' + cs.borderTopWidth + ' ' + cs.borderStyle + ' '
               + cs.borderTopColor + '\\n';
          if (el.getAttribute) {
            var attrs = el.attributes, list = [];
            for (var i = 0; i < attrs.length; i++)
              list.push(attrs[i].name + '="' + String(attrs[i].value).slice(0, 60) + '"');
            if (list.length) out += '\\nATTRIBUTES\\n  ' + list.join('\\n  ') + '\\n';
          }
          var keys = ['display','position','top','right','bottom','left','float','clear',
            'width','height','min-width','max-width','min-height','max-height',
            'flex-direction','flex-wrap','justify-content','align-items','gap',
            'grid-template-columns','grid-template-rows',
            'color','background-color','background-image','opacity','visibility',
            'font-family','font-size','font-weight','line-height','letter-spacing',
            'text-align','text-decoration','text-transform','white-space',
            'overflow','overflow-x','overflow-y','z-index','box-shadow','border-radius',
            'transform','transition','cursor','pointer-events'];
          out += '\\nCOMPUTED\\n';
          for (var j = 0; j < keys.length; j++) {
            var v = cs.getPropertyValue(keys[j]);
            if (v) out += '  ' + keys[j] + ': ' + v + ';\\n';
          }
          return out;
        })();
        """
    }

    /// A single overlay div, reused, so inspecting does not litter the page.
    private static func highlightScript(for path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function () {
          var id = '__kestrel_highlight';
          var box = document.getElementById(id);
          if (!box) {
            box = document.createElement('div');
            box.id = id;
            box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;'
              + 'background:rgba(0,122,255,0.22);outline:1px solid rgba(0,122,255,0.9);'
              + 'transition:all 80ms ease-out';
            document.documentElement.appendChild(box);
          }
          var el;
          try { el = document.querySelector('\(escaped)'); } catch (e) { el = null; }
          if (!el) { box.style.display = 'none'; return; }
          var r = el.getBoundingClientRect();
          box.style.display = 'block';
          box.style.left = r.left + 'px';
          box.style.top = r.top + 'px';
          box.style.width = r.width + 'px';
          box.style.height = r.height + 'px';
        })();
        """
    }
}

// MARK: - Network

/// The request list, embedded. Same data as the standalone window.
final class NetworkPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSTextView()
    private let summary = NSTextField(labelWithString: "")
    private var rows: [NetworkMonitor.Entry] = []

    private let listScroll = NSScrollView()
    private let detailScroll = NSScrollView()

    override func layout() {
        super.layout()
        let listW = (bounds.width * 0.58).rounded()
        let statusH: CGFloat = 18
        listScroll.frame = NSRect(x: 0, y: statusH, width: listW, height: bounds.height - statusH)
        detailScroll.frame = NSRect(x: listW + 1, y: statusH, width: bounds.width - listW - 1,
                                    height: bounds.height - statusH)
        summary.frame = NSRect(x: 8, y: 1, width: max(0, bounds.width - 16), height: 15)
        detail.textContainer?.containerSize =
            NSSize(width: detailScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let listW = (frame.width * 0.58).rounded()
        let statusH: CGFloat = 18

        let scroll = listScroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for (id, title, w) in [("status", "Status", 48), ("method", "Method", 54),
                               ("domain", "Domain", 130), ("file", "File", 160),
                               ("type", "Type", 56), ("size", "Size", 62),
                               ("source", "Source", 66)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.rowHeight = 17
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        addSubview(scroll)

        let dScroll = detailScroll
        dScroll.frame = NSRect(x: listW + 1, y: statusH, width: frame.width - listW - 1,
                               height: frame.height - statusH)
        dScroll.hasVerticalScroller = true
        detail.frame = NSRect(origin: .zero, size: dScroll.contentSize)
        detail.minSize = .zero
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.containerSize =
            NSSize(width: dScroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        detail.textContainer?.widthTracksTextView = true
        detail.isEditable = false
        detail.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detail.textContainerInset = NSSize(width: 8, height: 6)
        detail.string = "Select a request."
        dScroll.documentView = detail
        addSubview(dScroll)

        summary.font = .systemFont(ofSize: 10)
        summary.textColor = .secondaryLabelColor
        addSubview(summary)
    }
    required init?(coder: NSCoder) { nil }

    func reload() {
        let selected = table.selectedRow
        rows = NetworkMonitor.entries
        table.reloadData()
        if rows.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        let t = NetworkMonitor.totals
        summary.stringValue = "\(t.count) requests · \(bytes(t.transferred)) transferred"
    }

    private func bytes(_ n: Int) -> String {
        if n <= 0 { return "—" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f kB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row)
        else { return nil }
        let e = rows[row]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10.5)
        label.lineBreakMode = .byTruncatingMiddle
        switch id {
        case "status":
            label.stringValue = e.status.map(String.init) ?? "—"
            if let s = e.status {
                label.textColor = s >= 400 ? .systemRed : s >= 300 ? .systemOrange : .systemGreen
            } else { label.textColor = .tertiaryLabelColor }
        case "method": label.stringValue = e.method
        case "domain": label.stringValue = e.host
        case "file":   label.stringValue = e.file
        case "type":   label.stringValue = e.type
        case "size":   label.stringValue = bytes(e.transferred)
        case "source":
            label.stringValue = e.source.rawValue
            label.textColor = .secondaryLabelColor
        default: break
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { return }
        let e = rows[table.selectedRow]
        var out = "\(e.method) \(e.url.absoluteString)\n\n"
        out += "Status: \(e.status.map(String.init) ?? "not observable")\n"
        out += "Observed by: \(e.source.rawValue)\n"
        func section(_ t: String, _ h: [String: String]) -> String {
            guard !h.isEmpty else { return "" }
            var s = "\n\(t)\n"
            for k in h.keys.sorted() { s += "  \(k): \(h[k] ?? "")\n" }
            return s
        }
        out += section("Request Headers", e.requestHeaders)
        out += section("Response Headers", e.responseHeaders)
        if e.requestHeaders.isEmpty && e.responseHeaders.isEmpty {
            out += "\nNo headers: this row came from PerformanceObserver, which reports "
                 + "size and timing for engine-fetched resources but never their headers."
        }
        detail.string = out
        detail.scrollToBeginningOfDocument(nil)
    }
}

// MARK: - Memory

/// The budget, per tab, in the panel — the same figures as `about:memory`.
final class MemoryPane: NSView, NSTableViewDataSource {
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private var rows: [Tab] = []
    private var budget: Int64 = 0

    private let listScroll = NSScrollView()

    override func layout() {
        super.layout()
        let statusH: CGFloat = 18
        listScroll.frame = NSRect(x: 0, y: statusH, width: bounds.width,
                                  height: bounds.height - statusH)
        summary.frame = NSRect(x: 8, y: 1, width: max(0, bounds.width - 16), height: 15)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let statusH: CGFloat = 18
        let scroll = listScroll
        scroll.frame = NSRect(x: 0, y: statusH, width: frame.width, height: frame.height - statusH)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for (id, title, w) in [("state", "State", 60), ("title", "Tab", 320),
                               ("mb", "MB", 60), ("pid", "PID", 60),
                               ("restore", "Restore", 70), ("uses", "Visits", 54)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.rowHeight = 17
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.dataSource = self
        scroll.documentView = table
        addSubview(scroll)

        summary.font = .systemFont(ofSize: 10)
        summary.textColor = .secondaryLabelColor
        addSubview(summary)
    }
    required init?(coder: NSCoder) { nil }

    func reload(browser: BrowserWindowController?) {
        guard let browser else { return }
        rows = browser.tabs.sorted { $0.currentBytes > $1.currentBytes }
        budget = browser.scheduler.budgetBytes
        let total = browser.scheduler.totalBytes(browser.tabs)
        table.reloadData()
        let counts = [TabState.live, .warm, .cold, .stub].map { st in
            "\(st) \(browser.tabs.filter { $0.state == st }.count)"
        }.joined(separator: "  ")
        summary.stringValue =
            "\(total / 1_048_576) MB of \(budget / 1_048_576) MB   ·   " + counts
            + "   ·   this panel is not a web view and costs no process"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row)
        else { return nil }
        let t = rows[row]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10.5)
        label.lineBreakMode = .byTruncatingTail
        switch id {
        case "state":
            label.stringValue = "\(t.state)"
            label.textColor = MemoryBar.color(for: t.state)
        case "title":   label.stringValue = t.title.isEmpty ? t.url.absoluteString : t.title
        case "mb":
            label.stringValue = t.footprintKnown ? "\(t.currentBytes / 1_048_576)" : "?"
            if !t.footprintKnown { label.textColor = .systemRed }
        case "pid":     label.stringValue = t.pid.map(String.init) ?? "—"
        case "restore":
            label.stringValue = t.lastRestoreMs > 0
                ? String(format: "%.0f ms", t.lastRestoreMs) : "—"
        case "uses":    label.stringValue = "\(t.uses)"
        default: break
        }
        return label
    }
}
