import AppKit

/// A stacked bar showing where the browser's memory actually is, segmented by tab state,
/// with the budget drawn as a hard line across it.
///
/// This is DESIGN.md §7 -- "about:memory is excellent and no user has ever opened it".
/// The point of the ladder is invisible unless you can see tabs moving down it.
final class MemoryBar: NSView {
    struct Segment { let bytes: Int64; let color: NSColor; let label: String }

    var segments: [Segment] = []
    var budgetBytes: Int64 = 0
    var totalBytes: Int64 = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()

        // Scale to whichever is larger so going over budget is visible rather than clipped.
        let scale = Double(max(totalBytes, budgetBytes)) * 1.05
        guard scale > 0 else { return }

        var x = r.minX
        for seg in segments where seg.bytes > 0 {
            let w = r.width * CGFloat(Double(seg.bytes) / scale)
            let piece = NSRect(x: x, y: r.minY, width: max(1, w), height: r.height)
            seg.color.setFill()
            NSBezierPath(roundedRect: piece, xRadius: 2, yRadius: 2).fill()
            x += w
        }

        // The budget line.
        if budgetBytes > 0 {
            let bx = r.minX + r.width * CGFloat(Double(budgetBytes) / scale)
            let over = totalBytes > budgetBytes
            (over ? NSColor.systemRed : NSColor.labelColor).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bx, y: r.minY - 2))
            line.line(to: NSPoint(x: bx, y: r.maxY + 2))
            line.lineWidth = over ? 2 : 1
            line.stroke()
        }
    }
}

/// A small thumbnail + title + state row for the tab strip.
final class TabRowView: NSView {
    /// Custom row views do not get NSTableView's selection highlight, so the active tab
    /// has to draw its own. Without it there is no feedback that a click did anything.
    var isCurrent = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard isCurrent else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2),
                     xRadius: 5, yRadius: 5).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 4, width: 3, height: bounds.height - 8),
                     xRadius: 1.5, yRadius: 1.5).fill()
    }

    let thumb = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let statePill = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.frame = NSRect(x: 6, y: 6, width: 56, height: 36)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 3
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(thumb)

        title.frame = NSRect(x: 70, y: 27, width: 224, height: 16)
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 12)
        addSubview(title)

        statePill.frame = NSRect(x: 70, y: 8, width: 46, height: 14)
        statePill.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        statePill.alignment = .center
        statePill.wantsLayer = true
        statePill.layer?.cornerRadius = 3
        addSubview(statePill)

        detail.frame = NSRect(x: 120, y: 8, width: 174, height: 14)
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        addSubview(detail)
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ tab: Tab, isCurrent: Bool = false) {
        self.isCurrent = isCurrent
        title.font = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        title.stringValue = tab.title
        thumb.image = tab.snapshot
        thumb.isHidden = tab.snapshot == nil

        statePill.stringValue = tab.state.description
        let c = MemoryBar.color(for: tab.state)
        statePill.textColor = c
        statePill.layer?.backgroundColor = c.withAlphaComponent(0.15).cgColor

        let mb = Double(tab.currentBytes) / 1_048_576
        var bits = [tab.isLoading ? "loading…" : String(format: "%.0f MB", mb)]
        if tab.pinned { bits.append("pinned") }
        if tab.audible { bits.append("audio") }
        if tab.lastRestoreMs > 0 && tab.state == .live {
            bits.append(String(format: "%.0fms", tab.lastRestoreMs))
        }
        detail.stringValue = bits.joined(separator: "  ")
    }
}

extension MemoryBar {
    static func color(for state: TabState) -> NSColor {
        switch state {
        case .live: return .systemGreen
        case .warm: return .systemOrange
        case .cold: return .systemBlue
        case .stub: return .systemGray
        }
    }
}
