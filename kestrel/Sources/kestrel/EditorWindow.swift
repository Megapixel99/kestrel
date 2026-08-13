import AppKit

/// The editor window: tool bar, colours, width, and export — Longshot's layout.
final class EditorWindowController: NSObject {
    let window: NSWindow
    private let canvas = AnnotatorView()
    private var toolButtons: [Annotation.Kind: NSButton] = [:]
    private let headerField = NSTextField()
    private let footerField = NSTextField()
    private let watermarkField = NSTextField()
    private let headerCheck = NSButton(checkboxWithTitle: "Header", target: nil, action: nil)
    private let footerCheck = NSButton(checkboxWithTitle: "Footer", target: nil, action: nil)
    private let markCheck = NSButton(checkboxWithTitle: "Watermark", target: nil, action: nil)
    private var pageURL: URL?
    private var pageTitle: String = ""
    weak var browser: BrowserWindowController?

    private static let tools: [(String, String, Annotation.Kind)] = [
        ("Box", "r", .box), ("Ellipse", "o", .ellipse), ("Arrow", "a", .arrow),
        ("Line", "l", .line), ("Pen", "n", .pen), ("Text", "t", .text),
        ("Step", "s", .step), ("Highlight", "h", .highlight), ("Blur", "b", .blur),
        ("Pixelate", "p", .pixelate), ("Redact", "k", .redact),
    ]
    private static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .black, .white,
    ]

    init(image: NSImage, url: URL?, title: String, browser: BrowserWindowController?) {
        self.pageURL = url
        self.pageTitle = title
        self.browser = browser
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Edit screenshot — \(title)"
        // The tool row is a fixed-width cascade — eleven buttons, eight swatches and a
        // slider laid out left to right — so it has a real minimum. Declaring it stops the
        // window being dragged narrower than its own contents.
        window.contentMinSize = NSSize(width: 1100, height: 520)

        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]
        let H = root.bounds.height, W = root.bounds.width

        // --- tool row ---
        var x: CGFloat = 10
        for (name, key, kind) in Self.tools {
            let b = NSButton(title: "\(name)  \(key.uppercased())", target: self,
                             action: #selector(pickTool(_:)))
            b.frame = NSRect(x: x, y: H - 36, width: CGFloat(name.count) * 7 + 26, height: 26)
            b.autoresizingMask = [.minYMargin]
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 11)
            b.tag = Self.tools.firstIndex { $0.2 == kind } ?? 0
            root.addSubview(b)
            toolButtons[kind] = b
            x += b.frame.width + 4
        }
        highlightTool(.box)

        // --- colours + width ---
        var cx = x + 12
        for (i, c) in Self.palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
            b.frame = NSRect(x: cx, y: H - 34, width: 22, height: 22)
            b.autoresizingMask = [.minYMargin]
            b.bezelStyle = .circular
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 11
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.tag = i
            root.addSubview(b)
            cx += 26
        }
        let widthSlider = NSSlider(value: 3, minValue: 1, maxValue: 16,
                                   target: self, action: #selector(widthChanged(_:)))
        widthSlider.frame = NSRect(x: cx + 10, y: H - 34, width: 110, height: 22)
        widthSlider.autoresizingMask = [.minYMargin]
        root.addSubview(widthSlider)

        // --- actions row ---
        var ax: CGFloat = 10
        for (title, sel) in [("Crop", #selector(toggleCrop)), ("Apply Crop", #selector(applyCrop)),
                             ("Undo", #selector(undo)), ("Redo", #selector(redo)),
                             ("Delete", #selector(deleteLast)), ("Clear", #selector(clearAll))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: ax, y: H - 68, width: 82, height: 24)
            b.autoresizingMask = [.minYMargin]
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 11)
            root.addSubview(b)
            ax += 86
        }
        var rx = W - 10 - 76
        for (title, sel) in [("Save", #selector(save)), ("Copy", #selector(copyImage)),
                             ("Print", #selector(printImage))] {
            let b = NSButton(title: title, target: self, action: sel)
            b.frame = NSRect(x: rx, y: H - 68, width: 72, height: 24)
            b.autoresizingMask = [.minXMargin, .minYMargin]
            b.bezelStyle = .rounded
            root.addSubview(b)
            rx -= 76
        }

        // --- decorate row ---
        var dx: CGFloat = 10
        for (check, field, placeholder, w) in
            [(headerCheck, headerField, "%title%", CGFloat(200)),
             (footerCheck, footerField, "%url% · %date%", CGFloat(240)),
             (markCheck, watermarkField, "CONFIDENTIAL", CGFloat(170))] {
            check.frame = NSRect(x: dx, y: H - 96, width: 92, height: 20)
            check.autoresizingMask = [.minYMargin]
            check.target = self
            check.action = #selector(refresh)
            root.addSubview(check)
            dx += 96
            field.frame = NSRect(x: dx, y: H - 97, width: w, height: 22)
            field.autoresizingMask = [.minYMargin]
            field.placeholderString = placeholder
            field.stringValue = placeholder
            field.font = .systemFont(ofSize: 11)
            root.addSubview(field)
            dx += w + 14
        }

        // --- canvas ---
        canvas.frame = NSRect(x: 0, y: 0, width: W, height: H - 106)
        canvas.autoresizingMask = [.width, .height]
        canvas.image = image
        root.addSubview(canvas)

        window.contentView = root
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    // MARK: - actions

    @objc private func pickTool(_ b: NSButton) {
        let kind = Self.tools[b.tag].2
        canvas.tool = kind
        canvas.isCropping = false
        highlightTool(kind)
    }
    private func highlightTool(_ kind: Annotation.Kind) {
        for (k, b) in toolButtons { b.contentTintColor = k == kind ? .controlAccentColor : nil }
    }
    @objc private func pickColor(_ b: NSButton) { canvas.color = Self.palette[b.tag] }
    @objc private func widthChanged(_ s: NSSlider) { canvas.lineWidth = CGFloat(s.doubleValue) }
    @objc private func toggleCrop() { canvas.isCropping.toggle() }
    @objc private func applyCrop() { canvas.applyCrop() }
    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }
    @objc private func deleteLast() { canvas.deleteLast() }
    @objc private func clearAll() { canvas.clearAll() }
    @objc private func refresh() { canvas.needsDisplay = true }

    /// %title%, %url% and %date% are substituted, matching Longshot's templates.
    private func expand(_ s: String) -> String {
        s.replacingOccurrences(of: "%title%", with: pageTitle)
         .replacingOccurrences(of: "%url%", with: pageURL?.absoluteString ?? "")
         .replacingOccurrences(of: "%date%", with:
            DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))
    }

    private func rendered() -> NSImage? {
        canvas.flattened(
            header: headerCheck.state == .on ? expand(headerField.stringValue) : nil,
            footer: footerCheck.state == .on ? expand(footerField.stringValue) : nil,
            watermark: markCheck.state == .on ? watermarkField.stringValue : nil)
    }

    @objc private func save() {
        guard let img = rendered(), let png = Screenshot.png(img) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Screenshot.suggestedFilename(
            for: pageURL ?? URL(string: "https://page")!, ext: "png")
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            try? png.write(to: url)
            self?.browser?.flash("saved \(png.count / 1024) KB")
        }
    }

    @objc private func copyImage() {
        guard let img = rendered() else { return }
        Screenshot.copyToClipboard(img)
        browser?.flash("copied annotated screenshot")
    }

    @objc private func printImage() {
        guard let img = rendered() else { return }
        let iv = NSImageView(frame: NSRect(origin: .zero, size: img.size))
        iv.image = img
        iv.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: iv)
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
