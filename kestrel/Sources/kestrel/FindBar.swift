import AppKit
import WebKit

/// Find-in-page. WKWebView gained a native `find(_:configuration:)` in macOS 11, which
/// highlights and scrolls properly — far better than injecting a JS highlighter.
final class FindBar: NSView {
    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private weak var webView: WKWebView?
    var onClose: (() -> Void)?
    private var lastQuery = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        field.frame = NSRect(x: 10, y: 6, width: 260, height: 22)
        field.placeholderString = "Find in page"
        field.font = .systemFont(ofSize: 12)
        field.target = self
        field.action = #selector(findNext)
        addSubview(field)

        countLabel.frame = NSRect(x: 278, y: 8, width: 120, height: 18)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        addSubview(countLabel)

        var x: CGFloat = 404
        for (title, sel) in [("\u{2039}", #selector(findPrevious)),
                             ("\u{203A}", #selector(findNext)),
                             ("Done", #selector(close))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: x, y: 4, width: title == "Done" ? 56 : 30, height: 24)
            b.bezelStyle = .rounded
            addSubview(b)
            x += (title == "Done" ? 60 : 34)
        }
    }
    required init?(coder: NSCoder) { nil }

    func attach(to webView: WKWebView) {
        self.webView = webView
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc func findNext() { search(forward: true) }
    @objc func findPrevious() { search(forward: false) }
    @objc func close() { onClose?() }

    private func search(forward: Bool) {
        let q = field.stringValue
        guard !q.isEmpty, let wv = webView else { countLabel.stringValue = ""; return }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(q, configuration: cfg) { [weak self] result in
            self?.countLabel.stringValue = result.matchFound ? "match" : "no matches"
            self?.countLabel.textColor = result.matchFound
                ? .secondaryLabelColor : .systemRed
        }
        lastQuery = q
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}
