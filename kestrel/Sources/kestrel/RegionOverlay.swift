import AppKit

/// Drag-to-select overlay for region capture. Sits over the web view, dims everything
/// outside the selection, and reports the rect in view points.
final class RegionOverlay: NSView {
    var onFinish: ((NSRect?) -> Void)?
    /// Element-picker mode: a single click reports a point instead of a drag rect.
    var pickMode = false
    var onPick: ((NSPoint?) -> Void)?
    private var origin: NSPoint?
    private var current: NSRect = .zero

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()
        guard current.width > 0, current.height > 0 else {
            let hint = NSAttributedString(
                string: pickMode ? "Click an element to capture it  ·  Esc to cancel"
                                 : "Drag to select a region  ·  Esc to cancel",
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: NSColor.white])
            hint.draw(at: NSPoint(x: bounds.midX - hint.size().width / 2, y: 24))
            return
        }
        // Punch the selection back out of the dimming.
        NSColor.clear.setFill()
        current.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let p = NSBezierPath(rect: current); p.lineWidth = 1.5; p.stroke()
        let label = NSAttributedString(
            string: "\(Int(current.width)) × \(Int(current.height))",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: NSColor.white])
        label.draw(at: NSPoint(x: current.minX + 4, y: max(2, current.minY - 16)))
    }

    override func mouseDown(with e: NSEvent) {
        if pickMode {
            let p = convert(e.locationInWindow, from: nil)
            removeFromSuperview()
            onPick?(p)
            return
        }
        origin = convert(e.locationInWindow, from: nil)
        current = .zero
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        guard let o = origin else { return }
        let p = convert(e.locationInWindow, from: nil)
        current = NSRect(x: min(o.x, p.x), y: min(o.y, p.y),
                         width: abs(p.x - o.x), height: abs(p.y - o.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        let r = current
        finish(r.width >= 4 && r.height >= 4 ? r : nil)
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { finish(nil) } else { super.keyDown(with: e) }
    }
    private func finish(_ rect: NSRect?) {
        removeFromSuperview()
        if pickMode { onPick?(nil) } else { onFinish?(rect) }
    }
}
