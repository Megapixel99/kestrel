import AppKit
import WebKit

final class DarkPathW: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done = true }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done = true }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done = true }
}
enum DarkPath {
  static func run() {
    let cfg = WKWebViewConfiguration()
cfg.applicationNameForUserAgent = UserAgent.applicationName
print("DarkReaderBridge.isAvailable = \(DarkReaderBridge.isAvailable)")
if let s = DarkReaderBridge.userScript() {
    print("userScript() returned a script, \(s.source.count / 1024) KB, injectionTime=documentStart")
    cfg.userContentController.addUserScript(s)
} else {
    print("userScript() returned nil -> FALLING BACK to CSS invert")
    cfg.userContentController.addUserScript(DarkMode.script())
}
let win = NSWindow(contentRect: NSRect(x:0,y:0,width:1280,height:900),
                   styleMask:[.titled], backing:.buffered, defer:false)
let wv = WKWebView(frame: win.contentLayoutRect, configuration: cfg)
win.contentView?.addSubview(wv)
let d = DarkPathW(); wv.navigationDelegate = d
wv.load(URLRequest(url: URL(string: "https://cas.apu.edu/cas/login")!))
var t = Date().addingTimeInterval(45)
while !d.done && Date() < t { RunLoop.current.run(mode:.default, before: Date().addingTimeInterval(0.05)) }
t = Date().addingTimeInterval(5)
while Date() < t { RunLoop.current.run(mode:.default, before: Date().addingTimeInterval(0.05)) }
var done = false
wv.evaluateJavaScript("""
({ drDefined: typeof DarkReader !== 'undefined',
   signInBG: (function(){ const b = document.querySelector('button[name=submit], .mdc-button, input[type=submit], button'); return b ? getComputedStyle(b).backgroundColor : 'none'; })(),
   checkboxMark: (function(){ const c = document.querySelector('.mdc-checkbox__background, .mdc-checkbox'); return c ? getComputedStyle(c).borderColor + ' size=' + Math.round(c.getBoundingClientRect().width) : 'none'; })(),
   drEnabled: !!window.__kestrelDarkReader,
   fallbackStyle: !!document.getElementById('__kestrel_dark'),
   htmlFilter: getComputedStyle(document.documentElement).filter,
   bodyBG: getComputedStyle(document.body).backgroundColor })
""") { r, e in
    print("\nafter load: \(r ?? e?.localizedDescription as Any)")
    done = true
}
t = Date().addingTimeInterval(15)
while !done && Date() < t { RunLoop.current.run(mode:.default, before: Date().addingTimeInterval(0.05)) }
  }
}
