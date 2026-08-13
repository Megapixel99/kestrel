import AppKit

/// Annotation editor for captured screenshots, modelled on Longshot's.
///
/// Annotations are kept as a list of vector objects rather than being painted into the
/// bitmap, so undo is exact and everything stays editable until export. Blur, pixelate
/// and redact are the exception in spirit — they must destroy information — but they are
/// still applied at render time, so the original pixels survive until you save.
struct Annotation {
    enum Kind { case box, ellipse, arrow, line, pen, text, step, highlight, blur, pixelate, redact }
    var kind: Kind
    var rect: NSRect = .zero
    var points: [NSPoint] = []
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var text: String = ""
    var step: Int = 0
}

final class AnnotatorView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var redoStack: [Annotation] = []
    var tool: Annotation.Kind = .box
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var cropRect: NSRect?
    var isCropping = false
    var onChange: (() -> Void)?

    private var draft: Annotation?
    private var origin: NSPoint?
    private var stepCounter = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Image rect within the view, preserving aspect.
    var imageRect: NSRect {
        guard let image, image.size.width > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height, 1)
        let w = image.size.width * scale, h = image.size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image else { return }
        let r = imageRect
        image.draw(in: r)

        for a in annotations { render(a, in: r) }
        if let d = draft { render(d, in: r) }

        if let crop = cropRect {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let path = NSBezierPath(rect: r)
            path.append(NSBezierPath(rect: crop))
            path.windingRule = .evenOdd
            path.fill()
            NSColor.controlAccentColor.setStroke()
            let s = NSBezierPath(rect: crop); s.lineWidth = 1.5; s.stroke()
        }
    }

    private func render(_ a: Annotation, in r: NSRect) {
        a.color.setStroke()
        a.color.setFill()
        switch a.kind {
        case .box:
            let p = NSBezierPath(rect: a.rect); p.lineWidth = a.width; p.stroke()
        case .ellipse:
            let p = NSBezierPath(ovalIn: a.rect); p.lineWidth = a.width; p.stroke()
        case .line, .arrow:
            guard a.points.count >= 2 else { break }
            let p = NSBezierPath()
            p.move(to: a.points[0]); p.line(to: a.points[1])
            p.lineWidth = a.width
            p.stroke()
            if a.kind == .arrow { drawArrowHead(from: a.points[0], to: a.points[1], a: a) }
        case .pen:
            guard a.points.count >= 2 else { break }
            let p = NSBezierPath()
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            p.lineWidth = a.width
            p.lineJoinStyle = .round
            p.lineCapStyle = .round
            p.stroke()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(12, a.width * 6), weight: .semibold),
                .foregroundColor: a.color]
            NSAttributedString(string: a.text, attributes: attrs)
                .draw(at: NSPoint(x: a.rect.minX, y: a.rect.minY))
        case .step:
            let d = max(22, a.width * 8)
            let c = NSRect(x: a.rect.minX, y: a.rect.minY, width: d, height: d)
            NSBezierPath(ovalIn: c).fill()
            let s = NSAttributedString(
                string: "\(a.step)",
                attributes: [.font: NSFont.boldSystemFont(ofSize: d * 0.55),
                             .foregroundColor: NSColor.white])
            s.draw(at: NSPoint(x: c.midX - s.size().width / 2,
                               y: c.midY - s.size().height / 2))
        case .highlight:
            a.color.withAlphaComponent(0.32).setFill()
            NSBezierPath(rect: a.rect).fill()
        case .blur, .pixelate, .redact:
            renderObscured(a, in: r)
        }
    }

    /// Blur and pixelate resample the underlying image; redact just paints it out.
    private func renderObscured(_ a: Annotation, in r: NSRect) {
        guard a.rect.width > 1, a.rect.height > 1 else { return }
        if a.kind == .redact {
            NSColor.black.setFill()
            NSBezierPath(rect: a.rect).fill()
            return
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage else { return }
        // Map the view rect back into image pixels.
        let sx = CGFloat(rep.pixelsWide) / r.width
        let sy = CGFloat(rep.pixelsHigh) / r.height
        let px = NSRect(x: (a.rect.minX - r.minX) * sx, y: (a.rect.minY - r.minY) * sy,
                        width: a.rect.width * sx, height: a.rect.height * sy)
        guard let crop = cg.cropping(to: px) else { return }
        let ci = CIImage(cgImage: crop)
        let filtered: CIImage?
        if a.kind == .blur {
            let f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            f?.setValue(max(4, a.width * 3), forKey: kCIInputRadiusKey)
            filtered = f?.outputImage?.cropped(to: ci.extent)
        } else {
            let f = CIFilter(name: "CIPixellate")
            f?.setValue(ci, forKey: kCIInputImageKey)
            f?.setValue(max(6, a.width * 4), forKey: kCIInputScaleKey)
            filtered = f?.outputImage?.cropped(to: ci.extent)
        }
        guard let filtered,
              let out = CIContext().createCGImage(filtered, from: filtered.extent)
        else { return }
        NSGraphicsContext.current?.cgContext.saveGState()
        NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: bounds.height)
        NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSRect(x: a.rect.minX, y: bounds.height - a.rect.maxY,
                             width: a.rect.width, height: a.rect.height)
        NSGraphicsContext.current?.cgContext.draw(out, in: flipped)
        NSGraphicsContext.current?.cgContext.restoreGState()
    }

    private func drawArrowHead(from: NSPoint, to: NSPoint, a: Annotation) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len = max(10, a.width * 4)
        let p = NSBezierPath()
        p.move(to: to)
        p.line(to: NSPoint(x: to.x - len * cos(angle - .pi / 7),
                           y: to.y - len * sin(angle - .pi / 7)))
        p.line(to: NSPoint(x: to.x - len * cos(angle + .pi / 7),
                           y: to.y - len * sin(angle + .pi / 7)))
        p.close()
        p.fill()
    }

    // MARK: - input

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        origin = p
        if isCropping { cropRect = NSRect(origin: p, size: .zero); return }
        var a = Annotation(kind: tool, color: color, width: lineWidth)
        switch tool {
        case .pen: a.points = [p]
        case .line, .arrow: a.points = [p, p]
        case .step: stepCounter += 1; a.step = stepCounter; a.rect = NSRect(origin: p, size: .zero)
        default: a.rect = NSRect(origin: p, size: .zero)
        }
        draft = a
    }

    override func mouseDragged(with e: NSEvent) {
        guard let o = origin else { return }
        let p = convert(e.locationInWindow, from: nil)
        let r = NSRect(x: min(o.x, p.x), y: min(o.y, p.y),
                       width: abs(p.x - o.x), height: abs(p.y - o.y))
        if isCropping { cropRect = r; needsDisplay = true; return }
        switch draft?.kind {
        case .pen: draft?.points.append(p)
        case .line, .arrow: draft?.points = [o, p]
        case .step: break
        default: draft?.rect = r
        }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { origin = nil }
        if isCropping { needsDisplay = true; return }
        guard var a = draft else { return }
        draft = nil
        if a.kind == .text {
            promptForText { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                a.text = text
                self.commit(a)
            }
            return
        }
        // Discard accidental clicks, except for steps which are a single point.
        if a.kind != .step && a.rect.width < 3 && a.points.count < 2 { needsDisplay = true; return }
        commit(a)
    }

    private func commit(_ a: Annotation) {
        annotations.append(a)
        redoStack.removeAll()
        onChange?()
    }

    private func promptForText(_ done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Text annotation"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = f
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        done(alert.runModal() == .alertFirstButtonReturn ? f.stringValue : nil)
    }

    // MARK: - editing

    func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        onChange?()
    }
    func redo() {
        guard let a = redoStack.popLast() else { return }
        annotations.append(a)
        onChange?()
    }
    func deleteLast() { _ = annotations.popLast(); onChange?() }
    func clearAll() { annotations.removeAll(); redoStack.removeAll(); onChange?() }

    /// Flatten annotations into a new image at the original resolution.
    func flattened(header: String? = nil, footer: String? = nil,
                   watermark: String? = nil) -> NSImage? {
        guard let image else { return nil }
        let r = imageRect
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let pxW = rep.pixelsWide, pxH = rep.pixelsHigh
        let scale = CGFloat(pxW) / r.width

        let headerH: CGFloat = header?.isEmpty == false ? 34 : 0
        let footerH: CGFloat = footer?.isEmpty == false ? 30 : 0
        let outH = CGFloat(pxH) + headerH + footerH

        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW,
                                         pixelsHigh: Int(outH), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(pxW), height: outH).fill()
        image.draw(in: NSRect(x: 0, y: footerH, width: CGFloat(pxW), height: CGFloat(pxH)))

        // Annotations are stored in view space; scale into image space.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: 0, y: footerH)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        for a in annotations { render(a, in: r) }
        ctx.restoreGState()

        func drawBar(_ text: String, y: CGFloat, h: CGFloat) {
            NSColor.white.setFill()
            NSRect(x: 0, y: y, width: CGFloat(pxW), height: h).fill()
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.black,
            ]).draw(at: NSPoint(x: 12, y: y + 8))
        }
        if let header, !header.isEmpty { drawBar(header, y: outH - headerH, h: headerH) }
        if let footer, !footer.isEmpty { drawBar(footer, y: 0, h: footerH) }

        if let watermark, !watermark.isEmpty {
            let s = NSAttributedString(string: watermark, attributes: [
                .font: NSFont.boldSystemFont(ofSize: CGFloat(pxW) / 14),
                .foregroundColor: NSColor.red.withAlphaComponent(0.22)])
            s.draw(at: NSPoint(x: (CGFloat(pxW) - s.size().width) / 2,
                               y: outH / 2 - s.size().height / 2))
        }

        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: pxW, height: Int(outH)))
        result.addRepresentation(out)
        return result
    }

    /// Apply the pending crop, returning to an uncropped state.
    func applyCrop() {
        guard let crop = cropRect, let image, crop.width > 4, crop.height > 4 else { return }
        let r = imageRect
        guard let cropped = Screenshot.crop(image,
                                            to: NSRect(x: crop.minX - r.minX,
                                                       y: crop.minY - r.minY,
                                                       width: crop.width, height: crop.height),
                                            viewSize: r.size) else { return }
        self.image = cropped
        annotations.removeAll()
        cropRect = nil
        isCropping = false
        onChange?()
    }
}
