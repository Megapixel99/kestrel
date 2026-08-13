import AppKit
import WebKit

// Kestrel -- a browser built around a memory budget.
//
// Modes:
//   probe [n]        spawn n web views, report real WebContent process memory
//   bench <urlfile>  headless: replay an access trace under each policy, log memory
//   gui              tabbed browser window with the 4-state ladder and a budget slider

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "gui"

let app = NSApplication.shared
app.setActivationPolicy(mode == "gui" ? .regular : .accessory)

switch mode {
case "probe":
    let n = args.count > 2 ? Int(args[2]) ?? 4 : 4
    Probe.run(count: n)
case "bench":
    guard args.count > 2 else {
        FileHandle.standardError.write("usage: kestrel bench <urlfile> [budgetMB]\n".data(using: .utf8)!)
        exit(2)
    }
    Benchmark.run(urlFile: args[2], budgetMB: args.count > 3 ? Int(args[3]) ?? 1500 : 1500)
case "exttest":
    ExtensionTest.run()
case "extscan":
    ExtensionScan.run(paths: Array(args.dropFirst(2)))
case "dnrtest":
    DynamicRuleTest.run()
case "blocktest":
    BlockTest.run(args: Array(args.dropFirst(2)))
case "extdiag":
    ExtensionDiag.run(args: Array(args.dropFirst(2)))
case "extmem":
    ExtensionMemory.run(paths: Array(args.dropFirst(2)))
case "layouttest":
    // `layouttest <dir>` also writes a PNG of each add-ons pane there.
    if args.count > 2 {
        let d = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        LayoutTest.dumpDir = d
        LayoutTest.dumpDark = args.contains("dark")
    }
    LayoutTest.run()
case "sessiontest":
    SessionTest.run()
case "selftest":
    SelfTest.run()
case "gui":
    // `gui <url>` opens straight to a page, which is how the add-on site
    // gets tested without retyping it on every relaunch.
    BrowserApp.run(startURL: args.count > 2 ? NewTabPage.resolve(args[2]) : nil)
default:
    FileHandle.standardError.write("unknown mode \(mode)\n".data(using: .utf8)!)
    exit(2)
}
