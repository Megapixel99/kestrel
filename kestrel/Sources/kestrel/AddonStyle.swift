import AppKit

/// The few shared pieces the add-ons popover still needs.
///
/// This used to be a component kit — banners, stat panels, bar sliders, toggle rows —
/// for six built-in feature panes. Those panes are gone, so the kit went with them.
enum AddonStyle {

    /// A full-width button.
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
