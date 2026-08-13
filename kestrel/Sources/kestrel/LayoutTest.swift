import AppKit
import WebKit

/// Automated layout checks for the views laid out by hand.
///
/// Every layout bug in this project so far was found by eye from a screenshot: the
/// add-ons footer drawn over the last row, toolbar buttons whose fixed widths summed past
/// their container and truncated, a detail pane with two headers, a nav bar positioned for
/// a tab strip that vertical mode hides. They are all the same two mistakes — a subview
/// outside its parent, or two siblings on top of each other — and both are checkable.
enum LayoutTest {

    struct Problem {
        let context: String
        let detail: String
    }

    /// Where to write PNGs of each layout, when asked. Reviewing the panes by eye
    /// otherwise means clicking through six of them in the running browser.
    static var dumpDir: URL?

    static func run() {
        var problems: [Problem] = []
        var checked = 0

        // --- add-ons popover: root list and every detail pane ---
        let browser = BrowserWindowController()
        defer { browser.window.close() }

        // The Firefox Add-ons pane is empty unless something is installed, and an empty
        // pane cannot overlap anything. A stub add-on makes the populated layout — the
        // one with rows, switches and checkboxes — the version actually audited.
        let stub = installStubExtension()
        defer { if let stub { try? FileManager.default.removeItem(at: stub) } }

        let vc = AddonsPopoverController(browser: browser)
        vc.showRoot()
        problems += audit(vc.view, context: "add-ons", recurse: true)
        dump(vc.view, as: "addons")
        checked += 1

        // --- the browser window itself, at its minimum size and larger ---
        for size in [NSSize(width: 900, height: 500), NSSize(width: 1500, height: 950)] {
            browser.window.setContentSize(size)
            browser.window.layoutIfNeeded()
            if let root = browser.window.contentView {
                problems += audit(root, context: "window \(Int(size.width))x\(Int(size.height))",
                                  recurse: true)
            }
            checked += 1
        }

        // --- both tab layouts, since one hides a bar the other positions against ---
        // Prefs is UserDefaults, and this binary shares a domain with the browser, so
        // leaving the flag flipped changed the user's actual tab layout — which is
        // exactly what happened: the test ended on `true` and the next launch came up
        // with vertical tabs. A test may not have side effects on the thing it tests.
        // Restored explicitly rather than with `defer`, because this function ends in
        // exit() and exit() does not run deferred blocks — the same trap exttest fell
        // into.
        let userLayout = Prefs.verticalTabs
        for vertical in [false, true] {
            Prefs.verticalTabs = vertical
            browser.applyTabLayout()
            if let root = browser.window.contentView {
                problems += audit(root,
                                  context: vertical ? "vertical tabs" : "horizontal tabs",
                                  recurse: false)
            }
            checked += 1
        }

        // The network panel, which is laid out by hand like the rest.
        let net = NetworkWindowController()
        defer { net.window.close() }
        for width in [CGFloat(1100), net.window.contentMinSize.width] {
            net.window.setContentSize(NSSize(width: width, height: 620))
            net.window.layoutIfNeeded()
            if let root = net.window.contentView {
                problems += audit(root, context: "network panel @\(Int(width))",
                                  recurse: true)
            }
            checked += 1
        }

        // The find bar spans the web container, which is narrowest at the minimum window
        // size with the vertical tab sidebar showing: 900 - 260. 520 is tighter still.
        for width in [CGFloat(640), 520] {
            let find = FindBar(frame: NSRect(x: 0, y: 0, width: width, height: 34))
            problems += audit(find, context: "find bar @\(Int(width))", recurse: false)
            checked += 1
        }

        Prefs.verticalTabs = userLayout
        if let stub { try? FileManager.default.removeItem(at: stub) }

        print("Layout check — \(checked) layouts\n")
        if problems.isEmpty {
            print("  no overflowing or overlapping controls found")
        } else {
            for p in problems.prefix(25) { print("  FAIL  \(p.context): \(p.detail)") }
        }
        print("\n\(problems.isEmpty ? "layout is clean" : "\(problems.count) layout problem(s)")")
        exit(problems.isEmpty ? 0 : 1)
    }

    /// A detached view draws almost nothing — text fields need a window to pick up an
    /// appearance and a field editor — so the pane is hosted in an offscreen window for
    /// the duration of the capture and handed straight back.
    private static var host: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        return w
    }()

    /// `layouttest <dir> dark` renders in dark mode. The panes are transparent — the
    /// popover supplies the background — so the capture has to paint one, or dark mode
    /// produces white text on white paper.
    static var dumpDark = false

    /// An unpacked add-on with a long name, so the row is audited at its widest.
    private static func installStubExtension() -> URL? {
        let dir = ExtensionStore.dir.appendingPathComponent("layouttest-stub")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
        {"manifest_version": 2, "name": "Layout Test Add-on With A Long Name",
         "version": "1.0.0", "permissions": ["storage", "<all_urls>"],
         "sidebar_action": {"default_panel": "p.html"}}
        """
        guard (try? manifest.data(using: .utf8)?
                .write(to: dir.appendingPathComponent("manifest.json"))) != nil
        else { return nil }
        return dir
    }

    private static func dump(_ view: NSView, as name: String) {
        guard let dir = dumpDir else { return }
        let parent = view.superview
        let frame = view.frame
        let backing = BackgroundView(frame: NSRect(origin: .zero, size: view.bounds.size))
        host.appearance = NSAppearance(named: dumpDark ? .darkAqua : .aqua)
        host.setContentSize(view.bounds.size)
        host.contentView = backing
        backing.addSubview(view)
        host.layoutIfNeeded()
        host.displayIfNeeded()

        defer {
            view.removeFromSuperview()
            host.contentView = NSView()
            view.frame = frame
            parent?.addSubview(view)
        }
        let view = backing
        // Via PDF rather than cacheDisplay: the panes are layer-backed, and cacheDisplay
        // captured the image views and dropped every label.
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let img = NSImage(data: pdf),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// A control must sit inside its parent, and must not sit on top of a sibling that
    /// also draws something. Labels that merely share a row are fine if they do not
    /// intersect.
    private static func audit(_ view: NSView, context: String,
                              recurse: Bool = false) -> [Problem] {
        var out: [Problem] = []
        let subs = view.subviews.filter { !$0.isHidden && $0.frame.width > 0
                                          && $0.frame.height > 0 }

        for s in subs {
            // Allow a 1pt rounding tolerance.
            if s.frame.minX < -1 || s.frame.minY < -1
                || s.frame.maxX > view.bounds.width + 1
                || s.frame.maxY > view.bounds.height + 1 {
                out.append(Problem(context: context,
                                   detail: "\(describe(s)) escapes its parent "
                                         + "\(rect(s.frame)) vs \(rect(view.bounds))"))
            }
        }

        // A scroll view whose document view has no size shows nothing at all — not even
        // its own placeholder text. The network panel's header pane looked like it was
        // failing to populate when it was simply zero by zero, and none of the other
        // checks here could see it: a zero-sized view is filtered out as "not laid out
        // yet" everywhere else.
        for case let sv as NSScrollView in view.subviews {
            let d = sv.documentView
            if d == nil || d!.bounds.width < 1 || d!.bounds.height < 1 {
                out.append(Problem(context: context,
                                   detail: "NSScrollView has a "
                                         + (d == nil ? "missing" : "zero-sized")
                                         + " document view \(rect(sv.frame))"))
            }
        }

        // A button narrower than its own title truncates to "Highl…", which is the third
        // way a hand-laid-out toolbar goes wrong and is just as checkable as the other two.
        for case let b as NSButton in subs where !b.title.isEmpty {
            let need = b.fittingSize.width
            if need > b.frame.width + 1 {
                out.append(Problem(context: context,
                                   detail: "\(describe(b)) is \(Int(b.frame.width)) pt wide "
                                         + "but needs \(Int(need.rounded())) pt"))
            }
        }

        for i in 0..<subs.count {
            for j in (i + 1)..<subs.count {
                let a = subs[i], b = subs[j]
                guard drawsContent(a), drawsContent(b) else { continue }
                let o = a.frame.intersection(b.frame)
                // Ignore hairline touching; require a real overlap in both axes.
                if o.width > 2 && o.height > 2 {
                    out.append(Problem(context: context,
                                       detail: "\(describe(a)) overlaps \(describe(b)) "
                                             + "by \(Int(o.width))x\(Int(o.height))"))
                }
            }
        }

        if recurse {
            // Descend all the way, not one level. Detail panes nest their content in a
            // body view inside the pane view, so a single level stopped exactly above
            // every control that matters — and the pane reported clean while the install
            // button was drawn across an add-on row.
            //
            // Only plain container views, though: AppKit controls own their internal
            // subviews and legitimately draw outside their own bounds — a slider's knob
            // overhangs its track by design — so descending into them tests Apple's
            // layout, not ours.
            for s in subs where isOurContainer(s) {
                out += audit(s, context: context + " › " + describe(s), recurse: true)
            }
        }
        return out
    }

    /// A plain view we laid out ourselves, rather than an AppKit control.
    private static func isOurContainer(_ v: NSView) -> Bool {
        guard type(of: v) == NSView.self || v is URLBarView || v is TabStripView
                || v is MemoryBar || v is ExtensionRow else { return false }
        return !(v is WKWebView)
    }

    /// Container views and image wells that are deliberately stacked (the snapshot
    /// placeholder sits over the web view by design) are not overlap candidates.
    private static func drawsContent(_ v: NSView) -> Bool {
        if v is NSTextField || v is NSButton || v is NSSlider || v is NSPopUpButton
            || v is NSSegmentedControl || v is NSStepper || v is NSSwitch { return true }
        // Custom views that paint their own content count too. Omitting these is what
        // let the first version of this test pass while the add-ons footer was drawing
        // straight over the last row — the exact bug it was written to catch.
        if v is ExtensionRow || v is MemoryBar || v is NSBox {
            return true
        }
        return false
    }

    private static func describe(_ v: NSView) -> String {
        if let t = v as? NSTextField {
            let s = t.stringValue.isEmpty ? (t.placeholderString ?? "") : t.stringValue
            return "label(\"\(s.prefix(18))\")"
        }
        if let b = v as? NSButton {
            return "button(\"\(b.title.isEmpty ? "icon" : String(b.title.prefix(18)))\")"
        }
        return String(describing: type(of: v))
    }

    private static func rect(_ r: NSRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private final class BackgroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}
