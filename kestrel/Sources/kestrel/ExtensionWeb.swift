import AppKit
import WebKit

/// Installing add-ons the way people actually get them: from addons.mozilla.org.
///
/// Two things stand between AMO and a non-Firefox browser, and both are Gecko-shaped
/// rather than technical.
///
/// 1. **AMO gates the install button on the user agent.** With Kestrel's Safari-derived UA
///    it offers to download Firefox instead. So on that one host — and only that host —
///    the browser presents a Firefox UA. Everywhere else the honest UA stands.
///
/// 2. **The button calls `InstallTrigger.install()`**, a Firefox API that exists nowhere
///    else. A small shim defines it, hands the `.xpi` URL to the browser, and the normal
///    install path takes over: download, show what it asks for, install only if accepted.
///
/// Direct links to `.xpi` files work too, from any site, through the navigation policy in
/// `BrowserApp`. Nothing installs without the permission dialog.
enum ExtensionWeb {

    static let amoHosts = ["addons.mozilla.org", "addons.allizom.org"]

    /// A current Firefox release UA. Only sent to AMO.
    static let firefoxUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0"

    static func isAddonSite(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return amoHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isExtensionArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "xpi"
    }

    static func isExtensionMIME(_ response: URLResponse) -> Bool {
        let mime = (response.mimeType ?? "").lowercased()
        return mime == "application/x-xpinstall" || mime == "application/x-xpinstall;"
    }

    static let messageName = "kestrelInstallAddon"

    /// Defines just enough of `InstallTrigger` for AMO's button to work, and catches
    /// plain links to `.xpi` files that the page handles in JavaScript.
    static func installTriggerScript() -> WKUserScript {
        let js = """
        (function () {
          if (window.InstallTrigger) return;
          function send(url) {
            try {
              window.webkit.messageHandlers.\(messageName).postMessage(String(url));
            } catch (e) {}
          }
          window.InstallTrigger = {
            SKIN: 1, LOCALE: 2, CONTENT: 4, PACKAGE: 7,
            enabled: function () { return true; },
            updateEnabled: function () { return true; },
            install: function (args) {
              for (var key in args) {
                var v = args[key];
                var url = (v && typeof v === 'object') ? v.URL : v;
                if (url) send(new URL(url, location.href).href);
              }
              return true;
            },
            installChrome: function () { return true; },
            startSoftwareUpdate: function (url) { send(url); return true; },
          };
        })();
        """
        return WKUserScript(source: js, injectionTime: .atDocumentStart,
                            forMainFrameOnly: false)
    }

    /// Attaches the shim to a tab's configuration. Scoped to the add-on sites by the
    /// script itself doing nothing anywhere else — `InstallTrigger` is only ever called
    /// by pages that already expect Firefox.
    @MainActor
    static func attach(to cfg: WKWebViewConfiguration) {
        cfg.userContentController.addUserScript(installTriggerScript())
        cfg.userContentController.add(InstallMessageHandler.shared, name: messageName)
    }

    /// Routes the shim's message to whichever window is running.
    @MainActor
    final class InstallMessageHandler: NSObject, WKScriptMessageHandler {
        static let shared = InstallMessageHandler()

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let raw = message.body as? String, let url = URL(string: raw),
                  #available(macOS 15.4, *),
                  let browser = ExtensionRuntime.shared.browser else { return }
            browser.downloadAndInstallExtension(from: url)
        }
    }
}

extension BrowserWindowController {

    /// Fetches an `.xpi` and runs it through the same install path as the file picker.
    ///
    /// The download is the easy part; the ordering is the point. The file is fetched to a
    /// temporary directory, its manifest read, and the permission dialog shown **before**
    /// anything is installed or enabled — so declining leaves nothing behind.
    func downloadAndInstallExtension(from url: URL) {
        guard #available(macOS 15.4, *) else {
            flash("add-ons need macOS 15.4")
            return
        }
        flash("downloading \(url.lastPathComponent)…")
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil else {
                    self.flash("download failed — \(error?.localizedDescription ?? "no data")")
                    return
                }
                // A 404 page is still "data". Anything that is not a ZIP will fail the
                // manifest check below, but saying so here is clearer.
                guard data.count > 4, data.prefix(2) == Data([0x50, 0x4B]) else {
                    self.flash("that URL did not return an add-on archive")
                    return
                }
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("kestrel-download-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: tmp,
                                                         withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let file = tmp.appendingPathComponent(
                    url.lastPathComponent.isEmpty ? "addon.xpi" : url.lastPathComponent)
                do {
                    try data.write(to: file)
                    let installed = try ExtensionStore.install(from: file)
                    guard self.confirmPermissions(for: installed) else {
                        ExtensionStore.remove(installed)
                        self.flash("cancelled — nothing installed")
                        return
                    }
                    Prefs.setExtensionEnabled(true, id: installed.id)
                    self.enableExtension(installed)
                } catch {
                    self.flash("could not install — \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }
}
