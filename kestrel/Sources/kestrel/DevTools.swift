import AppKit
import WebKit

/// Developer tools, in the shape Firefox puts behind the wrench.
///
/// The Task Manager is the one that matters most here: it is the per-tab state and
/// memory readout the sidebar used to carry, and it belongs in a window rather than
/// squeezed into a tab strip.
enum DevTools {

    // MARK: - Task Manager

    final class TaskManagerController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let window: NSWindow
        private let table = NSTableView()
        private weak var browser: BrowserWindowController?
        private var timer: Timer?

        init(browser: BrowserWindowController) {
            self.browser = browser
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            super.init()
            window.title = "Task Manager"

            let scroll = NSScrollView(frame: window.contentLayoutRect)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            for (id, title, w) in [("tab", "Tab", 300), ("state", "State", 70),
                                   ("mem", "Memory", 90), ("pid", "Process", 80),
                                   ("restore", "Last restore", 100),
                                   ("uses", "Visits", 60)] {
                let c = NSTableColumn(identifier: .init(id))
                c.title = title
                c.width = CGFloat(w)
                table.addTableColumn(c)
            }
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            scroll.documentView = table
            window.contentView = scroll

            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.table.reloadData()
            }
        }

        func show() {
            window.center()
            window.makeKeyAndOrderFront(nil)
            table.reloadData()
        }

        private var rows: [Tab] { browser?.tabs ?? [] }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ t: NSTableView, viewFor column: NSTableColumn?,
                       row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            let tab = rows[row]
            let text: String
            switch column?.identifier.rawValue {
            case "tab":     text = tab.title
            case "state":   text = tab.state.description
            case "mem":     text = String(format: "%.0f MB",
                                          Double(tab.currentBytes) / 1_048_576)
            case "pid":     text = tab.pid.map(String.init) ?? "—"
            case "restore": text = tab.lastRestoreMs > 0
                                   ? String(format: "%.0f ms", tab.lastRestoreMs) : "—"
            case "uses":    text = "\(tab.uses)"
            default:        text = ""
            }
            let label = NSTextField(labelWithString: text)
            label.font = column?.identifier.rawValue == "tab"
                ? .systemFont(ofSize: 12)
                : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            if column?.identifier.rawValue == "state" {
                label.textColor = MemoryBar.color(for: tab.state)
            }
            return label
        }
    }

    // MARK: - Browser Console

    /// Forwards the page's console into a window. WebKit gives no public console API,
    /// so console.* is wrapped in the page and posted to a message handler.
    static let consoleScript = """
    (function () {
      if (window.__kestrelConsole) return;
      window.__kestrelConsole = true;
      const send = (level, args) => {
        try {
          webkit.messageHandlers.kestrelConsole.postMessage({
            level, text: Array.from(args).map(a => {
              try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
              catch (e) { return String(a); }
            }).join(' ')
          });
        } catch (e) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const orig = console[level].bind(console);
        console[level] = function () { send(level, arguments); orig.apply(console, arguments); };
      }
      window.addEventListener('error', e =>
        send('error', [e.message + ' @ ' + e.filename + ':' + e.lineno]));
      window.addEventListener('unhandledrejection', e =>
        send('error', ['Unhandled rejection: ' + e.reason]));
    })();
    """

    final class ConsoleController: NSObject, WKScriptMessageHandler {
        let window: NSWindow
        private let textView = NSTextView()

        override init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            super.init()
            window.title = "Browser Console"
            let scroll = NSScrollView(frame: window.contentLayoutRect)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.autoresizingMask = [.width]
            scroll.documentView = textView
            window.contentView = scroll
        }

        func show() { window.center(); window.makeKeyAndOrderFront(nil) }

        func userContentController(_ c: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let level = body["level"] as? String,
                  let text = body["text"] as? String else { return }
            let color: NSColor = level == "error" ? .systemRed
                               : level == "warn" ? .systemOrange : .labelColor
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none,
                                                      timeStyle: .medium)
            let line = NSAttributedString(
                string: "[\(stamp)] \(level): \(text)\n",
                attributes: [.foregroundColor: color,
                             .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            textView.textStorage?.append(line)
            textView.scrollToEndOfDocument(nil)
        }
    }

    // MARK: - Page source

    static func showSource(of webView: WKWebView, title: String) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            let html = (result as? String) ?? "<could not read the document>"
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "Source — \(title)"
            let scroll = NSScrollView(frame: win.contentLayoutRect)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.string = html
            scroll.documentView = tv
            win.contentView = scroll
            win.center()
            win.makeKeyAndOrderFront(nil)
            sourceWindows.append(win)
        }
    }
    private static var sourceWindows: [NSWindow] = []

    // MARK: - Responsive design mode

    static let devicePresets: [(String, CGFloat, CGFloat)] = [
        ("Responsive (full)", 0, 0),
        ("iPhone SE — 375×667", 375, 667),
        ("iPhone 15 Pro — 393×852", 393, 852),
        ("iPad mini — 744×1133", 744, 1133),
        ("iPad Pro — 1024×1366", 1024, 1366),
        ("Laptop — 1280×800", 1280, 800),
    ]
}
