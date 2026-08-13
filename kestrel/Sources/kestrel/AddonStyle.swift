import AppKit

/// Shared building blocks so every add-on pane looks like it came from the same app —
/// branded header, uppercase section labels, toggle rows, stat panels.
enum AddonStyle {

    static func header(_ title: String, symbol: String, tint: NSColor,
                       in v: NSView, y: CGFloat, gearTarget: AnyObject? = nil,
                       gearAction: Selector? = nil) -> CGFloat {
        let icon = NSImageView(frame: NSRect(x: 16, y: y - 4, width: 26, height: 26))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            img.isTemplate = true
            icon.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            icon.contentTintColor = tint
        }
        v.addSubview(icon)

        let name = NSTextField(labelWithString: title)
        name.frame = NSRect(x: 50, y: y, width: 220, height: 22)
        name.font = .systemFont(ofSize: 16, weight: .bold)
        v.addSubview(name)

        if let gearAction {
            let gear = Toolbar.iconButton(symbol: "gearshape", fallback: "⚙", tip: "Settings",
                                          size: 14, target: gearTarget, action: gearAction)
            gear.frame = NSRect(x: v.bounds.width - 44, y: y - 2, width: 28, height: 26)
            v.addSubview(gear)
        }
        return y - 34
    }

    static func section(_ text: String, in v: NSView, y: CGFloat) -> CGFloat {
        let l = NSTextField(labelWithString: text.uppercased())
        l.frame = NSRect(x: 16, y: y, width: v.bounds.width - 32, height: 15)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        v.addSubview(l)
        return y - 22
    }

    /// A title/subtitle row with a switch on the right.
    @discardableResult
    static func toggleRow(_ title: String, subtitle: String, on: Bool,
                          in v: NSView, y: CGFloat,
                          target: AnyObject, action: Selector, tag: Int = 0) -> CGFloat {
        let t = NSTextField(labelWithString: title)
        t.frame = NSRect(x: 16, y: y, width: v.bounds.width - 90, height: 18)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        v.addSubview(t)

        let s = NSTextField(labelWithString: subtitle)
        s.frame = NSRect(x: 16, y: y - 17, width: v.bounds.width - 90, height: 16)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byTruncatingMiddle
        v.addSubview(s)

        let sw = NSSwitch(frame: NSRect(x: v.bounds.width - 62, y: y - 8, width: 40, height: 22))
        sw.state = on ? .on : .off
        sw.target = target
        sw.action = action
        sw.tag = tag
        v.addSubview(sw)
        return y - 46
    }

    /// The bordered "number of items blocked" style panel.
    static func statPanel(_ pairs: [(String, String)], in v: NSView, y: CGFloat) -> CGFloat {
        let h: CGFloat = 62
        let box = NSBox(frame: NSRect(x: 16, y: y - h, width: v.bounds.width - 32, height: h))
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .clear
        box.titlePosition = .noTitle
        v.addSubview(box)

        let w = box.frame.width / CGFloat(max(1, pairs.count))
        for (i, pair) in pairs.enumerated() {
            let x = CGFloat(i) * w
            let value = NSTextField(labelWithString: pair.1)
            value.frame = NSRect(x: x, y: 26, width: w, height: 24)
            value.alignment = .center
            value.font = .systemFont(ofSize: 19, weight: .semibold)
            box.contentView?.addSubview(value)

            let label = NSTextField(labelWithString: pair.0)
            label.frame = NSRect(x: x, y: 8, width: w, height: 16)
            label.alignment = .center
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            box.contentView?.addSubview(label)

            if i > 0 {
                let sep = NSBox(frame: NSRect(x: x, y: 10, width: 1, height: 40))
                sep.boxType = .separator
                box.contentView?.addSubview(sep)
            }
        }
        return y - h - 14
    }

    @discardableResult
    static func button(_ title: String, in v: NSView, x: CGFloat, y: CGFloat,
                       width: CGFloat, target: AnyObject, action: Selector,
                       prominent: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.frame = NSRect(x: x, y: y, width: width, height: 28)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 12)
        if prominent { b.keyEquivalent = "\r" }
        v.addSubview(b)
        return b
    }

    /// Label + slider + value, with the stepper arrows the Dark Reader panel uses.
    @discardableResult
    static func slider(_ title: String, key: String, value: Int, in v: NSView, y: CGFloat,
                       target: AnyObject, action: Selector,
                       stepAction: Selector) -> CGFloat {
        let margin: CGFloat = 16
        let labelW: CGFloat = 88
        let stepW: CGFloat = 22
        let valueW: CGFloat = 34
        let sliderW = v.bounds.width - margin * 2 - labelW - stepW * 2 - valueW - 16

        let l = NSTextField(labelWithString: title)
        l.frame = NSRect(x: margin, y: y, width: labelW, height: 18)
        l.font = .systemFont(ofSize: 12)
        v.addSubview(l)

        func step(_ symbol: String, _ fallback: String, _ id: String, _ x: CGFloat) {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: "",
                                       size: 11, target: target, action: stepAction)
            b.frame = NSRect(x: x, y: y - 3, width: stepW, height: 22)
            b.identifier = NSUserInterfaceItemIdentifier(id)
            v.addSubview(b)
        }
        var x = margin + labelW
        step("minus", "\u{2212}", key + "-down", x)
        x += stepW + 4

        let s = NSSlider(value: Double(value), minValue: 0, maxValue: 150,
                         target: target, action: action)
        s.frame = NSRect(x: x, y: y - 2, width: sliderW, height: 20)
        s.identifier = NSUserInterfaceItemIdentifier(key)
        s.controlSize = .small
        v.addSubview(s)
        x += sliderW + 4

        step("plus", "+", key + "-up", x)
        x += stepW + 6

        let num = NSTextField(labelWithString: "\(value)")
        num.frame = NSRect(x: x, y: y, width: valueW, height: 18)
        num.alignment = .right
        num.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        num.textColor = .secondaryLabelColor
        num.identifier = NSUserInterfaceItemIdentifier(key + "-label")
        v.addSubview(num)
        return y - 30
    }

    // MARK: - centred variants, matching the real add-on panels

    /// Big bold banner title, centred across the pane.
    static func banner(_ title: String, tint: NSColor, in v: NSView, y: CGFloat) -> CGFloat {
        let l = NSTextField(labelWithString: title.uppercased())
        l.frame = NSRect(x: 0, y: y, width: v.bounds.width, height: 30)
        l.alignment = .center
        l.font = .systemFont(ofSize: 21, weight: .heavy)
        l.textColor = tint
        v.addSubview(l)
        return y - 38
    }

    /// A caption centred under whatever precedes it.
    @discardableResult
    static func caption(_ text: String, in v: NSView, y: CGFloat,
                        x: CGFloat? = nil, width: CGFloat? = nil) -> CGFloat {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: x ?? 0, y: y, width: width ?? v.bounds.width, height: 14)
        l.alignment = .center
        l.font = .systemFont(ofSize: 9.5)
        l.textColor = .tertiaryLabelColor
        v.addSubview(l)
        return y - 18
    }

    /// Centred tab row: Filter | Site list | More.
    @discardableResult
    static func tabs(_ titles: [String], selected: Int, in v: NSView, y: CGFloat,
                     target: AnyObject, action: Selector) -> CGFloat {
        let seg = NSSegmentedControl(labels: titles, trackingMode: .selectOne,
                                     target: target, action: action)
        seg.segmentStyle = .automatic
        let w = min(v.bounds.width - 40, CGFloat(titles.count) * 92)
        seg.frame = NSRect(x: (v.bounds.width - w) / 2, y: y, width: w, height: 24)
        seg.selectedSegment = selected
        v.addSubview(seg)
        return y - 34
    }

    /// ‹ [bar with centred label] › plus a centred value caption beneath.
    @discardableResult
    static func barSlider(_ title: String, value: Int, tint: NSColor, in v: NSView,
                          y: CGFloat, target: AnyObject, stepAction: Selector,
                          key: String, onChange: @escaping (Int) -> Void) -> CGFloat {
        let margin: CGFloat = 16, stepW: CGFloat = 24, gap: CGFloat = 6
        let barW = v.bounds.width - margin * 2 - (stepW + gap) * 2

        func step(_ symbol: String, _ fallback: String, _ id: String, _ x: CGFloat) {
            let b = Toolbar.iconButton(symbol: symbol, fallback: fallback, tip: "",
                                       size: 11, target: target, action: stepAction)
            b.frame = NSRect(x: x, y: y, width: stepW, height: 24)
            b.identifier = NSUserInterfaceItemIdentifier(id)
            v.addSubview(b)
        }
        step("chevron.left", "\u{2039}", key + "-down", margin)

        let bar = BarSliderView(frame: NSRect(x: margin + stepW + gap, y: y,
                                              width: barW, height: 24))
        bar.label = title
        bar.value = value
        bar.tint = tint
        bar.identifier = NSUserInterfaceItemIdentifier(key)
        v.addSubview(bar)

        step("chevron.right", "\u{203A}", key + "-up", margin + stepW + gap + barW + gap)

        let cap = NSTextField(labelWithString: value == 0 ? "off" : "\(value)")
        cap.frame = NSRect(x: 0, y: y + 25, width: v.bounds.width, height: 13)
        cap.alignment = .center
        cap.font = .systemFont(ofSize: 9.5)
        cap.textColor = .tertiaryLabelColor
        cap.identifier = NSUserInterfaceItemIdentifier(key + "-label")
        v.addSubview(cap)

        bar.onChange = { value in
            cap.stringValue = value == 0 ? "off" : "\(value)"
            onChange(value)
        }
        return y - 46
    }

    /// A full-width centred button.
    @discardableResult
    static func wideButton(_ title: String, in v: NSView, y: CGFloat,
                           target: AnyObject, action: Selector,
                           prominent: Bool = false) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.frame = NSRect(x: 16, y: y, width: v.bounds.width - 32, height: 28)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 12)
        if prominent { b.keyEquivalent = "\r" }
        v.addSubview(b)
        return b
    }
}
