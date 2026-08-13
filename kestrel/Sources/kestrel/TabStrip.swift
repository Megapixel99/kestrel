import AppKit

/// A horizontal tab strip, in the shape people expect from Firefox/Chrome/Zen.
///
/// The sidebar it replaces had room to print each tab's state and megabytes inline.
/// A horizontal strip does not, and that information is the entire point of this
/// browser — so each tab keeps a coloured state dot, memory moves to the tooltip, and
/// the aggregate stays on the bar along the bottom.
final class TabStripView: NSView {

    struct Item {
        let id: Int
        let title: String
        let state: TabState
        let bytes: Int64
        let isCurrent: Bool
        let pinned: Bool
        var isLoading: Bool = false
    }

    /// Advanced by the controller only while a load is in flight, so an idle browser
    /// does no drawing at all.
    var spinnerPhase: CGFloat = 0

    var items: [Item] = [] { didSet { rebuild() } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let minTabW: CGFloat = 66
    private let maxTabW: CGFloat = 220
    private let tabH: CGFloat = 34
    private let newTabW: CGFloat = 30
    private var frames: [(id: Int, rect: NSRect, close: NSRect)] = []
    private var newTabRect: NSRect = .zero
    private var hoverId: Int?

    override var isFlipped: Bool { true }

    override func layout() { super.layout(); rebuild() }

    private func rebuild() {
        frames.removeAll()
        let available = max(0, bounds.width - newTabW - 12)
        let count = max(1, items.count)
        let w = min(maxTabW, max(minTabW, available / CGFloat(count)))
        var x: CGFloat = 4
        for item in items {
            let r = NSRect(x: x, y: (bounds.height - tabH) / 2, width: w - 2, height: tabH)
            // Close box only when the tab is wide enough for it to not swallow the title.
            let close = w > 92
                ? NSRect(x: r.maxX - 22, y: r.midY - 8, width: 16, height: 16)
                : .zero
            frames.append((item.id, r, close))
            x += w
        }
        newTabRect = NSRect(x: min(x + 4, bounds.width - newTabW - 4),
                            y: (bounds.height - 26) / 2, width: 26, height: 26)
        needsDisplay = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        for (i, f) in frames.enumerated() {
            guard i < items.count else { break }
            let item = items[i]
            let path = NSBezierPath(roundedRect: f.rect.insetBy(dx: 1, dy: 3),
                                    xRadius: 7, yRadius: 7)
            if item.isCurrent {
                NSColor.controlBackgroundColor.setFill(); path.fill()
                NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1; path.stroke()
            } else if hoverId == item.id {
                NSColor.labelColor.withAlphaComponent(0.08).setFill(); path.fill()
            }

            // While loading, the state dot becomes a spinner; the state is still
            // conveyed by its colour.
            let dot = NSRect(x: f.rect.minX + 10, y: f.rect.midY - 4, width: 8, height: 8)
            if item.isLoading {
                drawSpinner(in: dot.insetBy(dx: -2, dy: -2),
                            color: MemoryBar.color(for: item.state))
            } else {
                MemoryBar.color(for: item.state).setFill()
                NSBezierPath(ovalIn: dot).fill()
                if item.state == .live && item.bytes == 0 {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(ovalIn: dot.insetBy(dx: 2, dy: 2)).fill()
                }
            }

            let textX = dot.maxX + 7
            let textW = max(0, (f.close.width > 0 ? f.close.minX - 4 : f.rect.maxX - 8) - textX)
            if textW > 14 {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5,
                                             weight: item.isCurrent ? .medium : .regular),
                    .foregroundColor: item.isCurrent
                        ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
                let title = (item.pinned ? "📌 " : "") + item.title
                let s = NSAttributedString(string: title, attributes: attrs)
                let clip = NSRect(x: textX, y: f.rect.midY - 8, width: textW, height: 16)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: clip).setClip()
                s.draw(at: NSPoint(x: textX, y: f.rect.midY - 8))
                NSGraphicsContext.restoreGraphicsState()
            }

            if f.close.width > 0 && (item.isCurrent || hoverId == item.id) {
                NSColor.secondaryLabelColor.setStroke()
                let p = NSBezierPath()
                let c = f.close.insetBy(dx: 4.5, dy: 4.5)
                p.move(to: NSPoint(x: c.minX, y: c.minY)); p.line(to: NSPoint(x: c.maxX, y: c.maxY))
                p.move(to: NSPoint(x: c.maxX, y: c.minY)); p.line(to: NSPoint(x: c.minX, y: c.maxY))
                p.lineWidth = 1.3
                p.stroke()
            }
        }

        // "+" button
        NSColor.secondaryLabelColor.setStroke()
        let p = NSBezierPath()
        let c = newTabRect.insetBy(dx: 8, dy: 8)
        p.move(to: NSPoint(x: c.minX, y: c.midY)); p.line(to: NSPoint(x: c.maxX, y: c.midY))
        p.move(to: NSPoint(x: c.midX, y: c.minY)); p.line(to: NSPoint(x: c.midX, y: c.maxY))
        p.lineWidth = 1.4
        p.stroke()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// A 270° arc that rotates with the phase — the conventional indeterminate spinner.
    private func drawSpinner(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        let r = min(rect.width, rect.height) / 2
        let start = spinnerPhase * 360
        path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: r,
                       startAngle: start, endAngle: start + 270)
        path.lineWidth = 2
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if newTabRect.contains(pt) { onNewTab?(); return }
        for f in frames {
            if f.close.width > 0 && f.close.contains(pt) { onClose?(f.id); return }
            if f.rect.contains(pt) { onSelect?(f.id); return }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let id = frames.first { $0.rect.contains(pt) }?.id
        if id != hoverId { hoverId = id; needsDisplay = true }
        toolTip = items.first { $0.id == id }.map {
            "\($0.title)\n\($0.state.description) · \(String(format: "%.0f MB", Double($0.bytes) / 1_048_576))"
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverId != nil { hoverId = nil; needsDisplay = true }
    }
}
