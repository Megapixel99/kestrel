import AppKit
import WebKit

/// Developer tools docked under the page: Inspector, Network, Memory.
///
/// Firefox's are docked at the bottom with a tab bar, and that shape is right — the tools
/// belong to the page you are looking at, not to a window that can drift behind it. The
/// three panes here are the three questions this browser can actually answer: what is in
/// the document, what it fetched, and what it costs.
///
/// None of the panes is a `WKWebView`. Firefox's devtools are themselves a web page;
/// spending a web content process on the tool that tells you about web content processes
/// would be a poor joke in a browser with a memory budget. Everything below is AppKit
/// reading the page through `evaluateJavaScript`.
final class DevPanel: NSView {

    enum Pane: Int { case inspector, network, memory }

    private let tabs = NSSegmentedControl(labels: ["Inspector", "Network", "Memory"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let closeButton = NSButton()
    private let divider = DividerView()
    private let container = NSView()

    private let inspector = InspectorPane()
    private let network = NetworkPane()
    private let memory = MemoryPane()

    weak var browser: BrowserWindowController?
    var onHeightChange: ((CGFloat) -> Void)?
    var onClose: (() -> Void)?

    private(set) var pane: Pane = .inspector

    static let minHeight: CGFloat = 140
    private let barH: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        divider.frame = NSRect(x: 0, y: frame.height - 4, width: frame.width, height: 4)
        divider.autoresizingMask = [.width, .minYMargin]
        divider.onDrag = { [weak self] dy in
            guard let self else { return }
            self.onHeightChange?(max(DevPanel.minHeight, self.frame.height - dy))
        }
        addSubview(divider)

        tabs.frame = NSRect(x: 8, y: frame.height - barH, width: 260, height: 22)
        tabs.autoresizingMask = [.minYMargin]
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(switchPane)
        tabs.segmentStyle = .texturedRounded
        addSubview(tabs)

        closeButton.frame = NSRect(x: frame.width - 28, y: frame.height - barH, width: 22,
                                   height: 22)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.isBordered = false
        closeButton.title = "\u{2715}"
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        addSubview(closeButton)

        container.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height - barH - 2)
        container.autoresizingMask = [.width, .height]
        addSubview(container)

        for p in [inspector, network, memory] {
            p.frame = container.bounds
            p.autoresizingMask = [.width, .height]
            p.isHidden = true
            container.addSubview(p)
        }
        inspector.isHidden = false
    }
    required init?(coder: NSCoder) { nil }

    @objc private func switchPane() {
        show(Pane(rawValue: tabs.selectedSegment) ?? .inspector)
    }

    @objc private func closePanel() { onClose?() }

    func show(_ p: Pane) {
        pane = p
        tabs.selectedSegment = p.rawValue
        inspector.isHidden = p != .inspector
        network.isHidden = p != .network
        memory.isHidden = p != .memory
        refresh()
    }

    /// Called on the browser's tick and when the panel opens.
    func refresh() {
        switch pane {
        case .inspector: inspector.reloadIfNeeded()
        case .network:   network.reload()
        case .memory:    memory.reload(browser: browser)
        }
    }

    func attach(to tab: Tab?) {
        inspector.webView = tab?.webView
        inspector.reload()
    }

    /// Opens on the inspector with a specific element selected — the right-click path.
    func inspect(path: String?, in tab: Tab?) {
        show(.inspector)
        inspector.webView = tab?.webView
        inspector.reload(selecting: path)
    }

    // MARK: - the draggable top edge

    private final class DividerView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        }
        override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaY) }
    }
}
