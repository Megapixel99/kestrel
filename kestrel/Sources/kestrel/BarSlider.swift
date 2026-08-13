import AppKit

/// The slider style Dark Reader uses: a filled bar with its label centred inside it,
/// flanked by ‹ › steppers, with the current value as a caption underneath.
final class BarSliderView: NSView {
    var label: String = ""
    var value: Int = 100 { didSet { needsDisplay = true; onChange?(value) } }
    var minValue = 0
    var maxValue = 150
    var onChange: ((Int) -> Void)?
    var tint: NSColor = .systemTeal

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Fill proportional to the value.
        let frac = CGFloat(value - minValue) / CGFloat(max(1, maxValue - minValue))
        if frac > 0 {
            let fill = NSRect(x: r.minX, y: r.minY, width: r.width * frac, height: r.height)
            NSGraphicsContext.saveGraphicsState()
            path.setClip()
            tint.withAlphaComponent(0.55).setFill()
            fill.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        s.draw(at: NSPoint(x: r.midX - s.size().width / 2,
                           y: r.midY - s.size().height / 2))
    }

    override func mouseDown(with e: NSEvent) { setFrom(e) }
    override func mouseDragged(with e: NSEvent) { setFrom(e) }
    private func setFrom(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let frac = max(0, min(1, p.x / bounds.width))
        value = minValue + Int((CGFloat(maxValue - minValue) * frac).rounded())
    }

    func step(_ delta: Int) { value = max(minValue, min(maxValue, value + delta)) }
}
