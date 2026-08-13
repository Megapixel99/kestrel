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
case "bisect":
    Bisect.run(path: args.count > 2 ? args[2] : nil)
case "overlap":
    OverlapTest.run(url: args.count > 2 ? args[2] : "https://duckduckgo.com/?q=google+meet")
case "darkab":
    DarkAB.run(url: args.count > 2 ? args[2] : "https://cas.apu.edu/cas/login")
case "darkpath":
    DarkPath.run()
case "diag":
    PageDiag.run(urlString: args.count > 2 ? args[2] : "https://example.com")
case "shottest":
    ShotTest.run()
case "adblocktest":
    AdBlockTest.run()
case "filters":
    FilterTest.run(path: args.count > 2 ? args[2] : nil)
case "darktest":
    DarkTest.run()
case "selftest":
    SelfTest.run()
case "gui":
    BrowserApp.run()
default:
    FileHandle.standardError.write("unknown mode \(mode)\n".data(using: .utf8)!)
    exit(2)
}
