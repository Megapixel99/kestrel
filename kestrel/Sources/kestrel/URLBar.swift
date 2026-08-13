import AppKit

/// Shared helper: an SF Symbol button, falling back to a text glyph if the symbol is
/// unavailable so the toolbar never renders as blank squares.
enum Toolbar {
    static func iconButton(symbol: String, fallback: String, tip: String,
                           size: CGFloat = 15, target: AnyObject?,
                           action: Selector) -> NSButton {
        let b = NSButton(title: "", target: target, action: action)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            img.isTemplate = true
            b.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
            b.imagePosition = .imageOnly
        } else {
            b.title = fallback
            b.font = .systemFont(ofSize: size)
        }
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }
}

/// The address bar: a rounded pill holding a security indicator, the editable field,
/// and trailing actions — the shape every current browser converged on.
final class URLBarView: NSView {
    let field = NSTextField()
    private let shield = NSImageView()
    private(set) var qrButton: NSButton!
    private(set) var starButton: NSButton!

    var onQR: (() -> Void)?
    var onBookmark: (() -> Void)?

    /// Drives the leading indicator: a lock for https, a shield when the blocker acted,
    /// a warning for plain http.
    enum Security { case secure, insecure, blocked(Int), blank }
    var security: Security = .blank { didSet { updateShield() } }
    var isBookmarked = false { didSet { updateStar() } }

    /// 0 when idle, 0..1 while loading — drawn as a thin fill behind the text.
    var loadProgress: Double = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        shield.frame = NSRect(x: 10, y: (frame.height - 15) / 2, width: 15, height: 15)
        shield.autoresizingMask = [.minYMargin, .maxYMargin]
        shield.imageScaling = .scaleProportionallyDown
        addSubview(shield)

        field.frame = NSRect(x: 32, y: (frame.height - 18) / 2,
                             width: frame.width - 32 - 64, height: 18)
        field.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)

        qrButton = Toolbar.iconButton(symbol: "qrcode", fallback: "QR",
                                      tip: "QR code for this page", size: 13,
                                      target: self, action: #selector(qrPressed))
        starButton = Toolbar.iconButton(symbol: "star", fallback: "☆",
                                        tip: "Bookmark this page", size: 13,
                                        target: self, action: #selector(starPressed))
        for (i, b) in [qrButton!, starButton!].enumerated() {
            b.frame = NSRect(x: frame.width - 58 + CGFloat(i) * 27,
                             y: (frame.height - 22) / 2, width: 24, height: 22)
            b.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            addSubview(b)
        }
        updateShield()
        updateStar()
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 0)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2,
                                yRadius: r.height / 2)
        (NSColor.textBackgroundColor.withAlphaComponent(0.55)).setFill()
        path.fill()

        // Progress fill, clipped to the pill so it keeps the rounded ends.
        if loadProgress > 0.001 && loadProgress < 0.999 {
            NSGraphicsContext.saveGraphicsState()
            path.setClip()
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(loadProgress),
                   height: r.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        (field.currentEditor() != nil
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func updateShield() {
        var symbol = "magnifyingglass"
        var tint = NSColor.tertiaryLabelColor
        var tip = "Search or enter an address"
        switch security {
        case .secure:   symbol = "lock.fill"; tint = .secondaryLabelColor; tip = "Secure connection"
        case .insecure: symbol = "exclamationmark.triangle.fill"; tint = .systemOrange
                        tip = "Not secure — this page is served over plain HTTP"
        case .blocked(let n):
            symbol = "shield.lefthalf.filled"; tint = .systemGreen
            tip = "\(n) ad/tracker rules active on this page"
        case .blank: break
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            img.isTemplate = true
            shield.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            shield.contentTintColor = tint
        }
        shield.toolTip = tip
    }

    private func updateStar() {
        let name = isBookmarked ? "star.fill" : "star"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Bookmark") {
            img.isTemplate = true
            starButton.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        }
        starButton.contentTintColor = isBookmarked ? .systemYellow : .secondaryLabelColor
    }

    @objc private func qrPressed() { onQR?() }
    @objc private func starPressed() { onBookmark?() }

    /// Repaint the focus ring when editing starts or stops.
    func noteFocusChanged() { needsDisplay = true }
}
