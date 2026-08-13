import AppKit
import WebKit

/// Firefox add-ons, running for real.
///
/// A Firefox add-on is a WebExtension: an `.xpi` is a ZIP containing `manifest.json`,
/// the same format Chrome and Safari use. There is no Gecko in here to run one — but
/// since macOS 15.4 WebKit ships its own WebExtensions runtime (`WKWebExtension`), the
/// same one Safari uses, and it is available to any `WKWebView` app. So Kestrel does not
/// reimplement the extension API: it unpacks the add-on and hands it to WebKit.
///
/// What that means in practice is worth being blunt about. Add-ons written against the
/// standard `browser.*` API work. Add-ons that reach for Gecko-only surfaces —
/// `sidebar_action`, `theme`, `contextualIdentities`, `chrome_settings_overrides` — do
/// not, and no amount of work here would change that. `ExtensionStore.gaps(in:)` reports
/// which of those a given add-on uses before it is enabled, rather than letting it half
/// work and leaving the user to guess.
enum ExtensionStore {

    struct Installed {
        let id: String            // directory name; stable across launches
        let dir: URL
        let manifest: [String: Any]

        var name: String {
            (manifest["name"] as? String).map(localised) ?? id
        }
        var version: String { manifest["version"] as? String ?? "?" }
        var manifestVersion: Int { (manifest["manifest_version"] as? Int) ?? 2 }
        var permissions: [String] {
            let p = (manifest["permissions"] as? [String]) ?? []
            let h = (manifest["host_permissions"] as? [String]) ?? []
            return p + h
        }
        var hostPatterns: [String] {
            permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        }
        var apiPermissions: [String] {
            permissions.filter { !$0.contains("://") && $0 != "<all_urls>" }
        }

        /// `__MSG_extensionName__` placeholders resolve against `_locales`, which we only
        /// need well enough to show a name in a list.
        private func localised(_ s: String) -> String {
            guard s.hasPrefix("__MSG_"), s.hasSuffix("__") else { return s }
            let key = String(s.dropFirst(6).dropLast(2))
            let def = (manifest["default_locale"] as? String) ?? "en"
            for locale in [def, "en", "en_US"] {
                let f = dir.appendingPathComponent("_locales/\(locale)/messages.json")
                if let d = try? Data(contentsOf: f),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let entry = j[key] as? [String: Any],
                   let msg = entry["message"] as? String {
                    return msg
                }
            }
            return key
        }
    }

    static var dir: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kestrel/extensions")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Every unpacked add-on on disk, whether or not it is enabled.
    static func installed() -> [Installed] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir,
                                                   includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url -> Installed? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  let d = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return Installed(id: url.lastPathComponent, dir: url, manifest: m)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Unpacks an `.xpi` (or any WebExtension ZIP, or a folder) into the extensions
    /// directory. Returns the installed add-on, or the reason it could not be installed.
    @discardableResult
    static func install(from source: URL) throws -> Installed {
        let fm = FileManager.default
        let stem = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let target = dir.appendingPathComponent(stem.isEmpty ? "extension" : stem)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)
        if isDir.boolValue {
            try fm.copyItem(at: source, to: target)
        } else {
            // `ditto -x -k` rather than a ZIP library: it ships with macOS, it is what
            // Archive Utility uses, and it does not care that the extension is .xpi.
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", source.path, target.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                try? fm.removeItem(at: target)
                throw Failure("not a readable archive")
            }
        }

        guard fm.fileExists(atPath:
                target.appendingPathComponent("manifest.json").path) else {
            try? fm.removeItem(at: target)
            throw Failure("no manifest.json inside — not a WebExtension")
        }
        guard let found = installed().first(where: { $0.id == target.lastPathComponent })
        else { throw Failure("manifest.json is not valid JSON") }
        return found
    }

    static func remove(_ ext: Installed) {
        Prefs.setExtensionEnabled(false, id: ext.id)
        try? FileManager.default.removeItem(at: ext.dir)
    }

    struct Failure: LocalizedError {
        let why: String
        init(_ why: String) { self.why = why }
        var errorDescription: String? { why }
    }

    // MARK: - what will not survive the move off Gecko

    /// Manifest keys WebKit's runtime does not implement. Reported before enabling, so
    /// "this add-on is installed but its sidebar never appears" is answered up front
    /// instead of being discovered later.
    private static let unsupportedKeys: [(String, String)] = [
        ("sidebar_action",             "sidebar panel"),
        ("theme",                      "browser theme"),
        ("chrome_settings_overrides",  "search/homepage override"),
        ("omnibox",                    "address bar keyword"),
        ("protocol_handlers",          "protocol handler"),
        ("user_scripts",               "userScripts API"),
        ("devtools_page",              "devtools panel"),
    ]
    private static let unsupportedPermissions: [(String, String)] = [
        ("contextualIdentities", "container tabs"),
        ("browsingData",         "browsingData API"),
        ("downloads",            "downloads API"),
        ("history",              "history API"),
        ("sessions",             "sessions API"),
        ("management",           "management API"),
        ("proxy",                "proxy API"),
        ("browserSettings",      "browserSettings API"),
        ("privacy",              "privacy API"),
        ("find",                 "find API"),
    ]

    /// Human descriptions of what this add-on asks for that WebKit will not give it.
    static func gaps(in ext: Installed) -> [String] {
        var out = unsupportedKeys.filter { ext.manifest[$0.0] != nil }.map(\.1)
        let perms = Set(ext.permissions)
        out += unsupportedPermissions.filter { perms.contains($0.0) }.map(\.1)
        return out
    }

    static var isSupportedOS: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }
}

// MARK: - the runtime

/// Owns WebKit's extension controller and one context per enabled add-on.
///
/// Every tab's `WKWebViewConfiguration` gets the same controller, which is what lets a
/// content script see the page and `browser.tabs` see the window.
@available(macOS 15.4, *)
@MainActor
final class ExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {

    static let shared = ExtensionRuntime()

    private(set) var controller = WKWebExtensionController(
        configuration: .default())
    private(set) var contexts: [String: WKWebExtensionContext] = [:]   // keyed by ext id
    private(set) var loadErrors: [String: String] = [:]
    weak var browser: BrowserWindowController?

    private var popover: NSPopover?

    override init() {
        super.init()
        controller.delegate = self
    }

    /// Attach the runtime to a tab's configuration. Called for every web view Kestrel
    /// creates, including ones restored from COLD.
    static func apply(to cfg: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        guard !ExtensionRuntime.shared.contexts.isEmpty else { return }
        cfg.webExtensionController = ExtensionRuntime.shared.controller
    }

    /// Loads every add-on the user has enabled. Errors are recorded per add-on rather
    /// than thrown: one broken extension must not stop the others.
    func loadEnabled(completion: (() -> Void)? = nil) {
        let wanted = ExtensionStore.installed().filter { Prefs.isExtensionEnabled($0.id) }
        let group = DispatchGroup()
        for ext in wanted where contexts[ext.id] == nil {
            group.enter()
            load(ext) { _ in group.leave() }
        }
        group.notify(queue: .main) { completion?() }
    }

    func load(_ ext: ExtensionStore.Installed, completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            do {
                let webExt = try await WKWebExtension(resourceBaseURL: ext.dir)
                let ctx = WKWebExtensionContext(for: webExt)
                // A stable identifier keeps the add-on's storage across launches; a
                // fresh UUID each time would silently wipe its settings.
                ctx.uniqueIdentifier = Prefs.extensionUUID(for: ext.id)
                ctx.isInspectable = true
                self.grantDeclaredPermissions(to: ctx, from: ext)
                try self.controller.load(ctx)
                self.contexts[ext.id] = ctx
                self.loadErrors[ext.id] = nil
                self.announceOpenState(to: ctx)
                completion(nil)
            } catch {
                self.loadErrors[ext.id] = error.localizedDescription
                completion(error.localizedDescription)
            }
        }
    }

    func unload(_ id: String) {
        guard let ctx = contexts[id] else { return }
        try? controller.unload(ctx)
        contexts[id] = nil
    }

    /// Grants what the manifest declared — and only that. The user has already seen this
    /// list and agreed to it in `AddonsPopoverController`; nothing is granted implicitly,
    /// and anything an add-on asks for later comes back through `promptForPermissions`.
    private func grantDeclaredPermissions(to ctx: WKWebExtensionContext,
                                          from ext: ExtensionStore.Installed) {
        for p in ext.apiPermissions {
            ctx.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(p))
        }
        for pattern in ext.hostPatterns {
            let p = pattern == "<all_urls>" ? "*://*/*" : pattern
            if let mp = try? WKWebExtension.MatchPattern(string: p) {
                ctx.setPermissionStatus(.grantedExplicitly, for: mp)
            }
        }
    }

    /// WebKit needs to be told about windows and tabs that already existed when the
    /// extension loaded, or `browser.tabs.query` comes back empty.
    private func announceOpenState(to ctx: WKWebExtensionContext) {
        guard let browser else { return }
        ctx.didOpenWindow(browser)
        ctx.didFocusWindow(browser)
        for tab in browser.tabs { ctx.didOpenTab(tab) }
        if let current = browser.currentTab { ctx.didActivateTab(current, previousActiveTab: nil) }
    }

    /// Toolbar actions, one per add-on with a browser action, for the nav bar.
    func actions(for tab: Tab?) -> [(id: String, action: WKWebExtension.Action)] {
        contexts.compactMap { id, ctx in
            guard let a = ctx.action(for: tab) else { return nil }
            return (id, a)
        }.sorted { $0.id < $1.id }
    }

    func performAction(id: String, tab: Tab?, from view: NSView) {
        guard let ctx = contexts[id], let action = ctx.action(for: tab) else { return }
        if action.presentsPopup {
            present(action, from: view)
        } else {
            ctx.performAction(for: tab)
        }
    }

    private func present(_ action: WKWebExtension.Action, from view: NSView) {
        popover?.close()
        guard let pop = action.popupPopover else { return }
        popover = pop
        pop.behavior = .transient
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ c: WKWebExtensionController,
                                openWindowsFor ctx: WKWebExtensionContext)
        -> [any WKWebExtensionWindow] {
        browser.map { [$0] } ?? []
    }

    func webExtensionController(_ c: WKWebExtensionController,
                                focusedWindowFor ctx: WKWebExtensionContext)
        -> (any WKWebExtensionWindow)? { browser }

    func webExtensionController(_ c: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for ctx: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let browser else { return completionHandler(nil, nil) }
        let url = configuration.url ?? NewTabPage.url()
        browser.openTab(url: url)
        completionHandler(browser.currentTab, nil)
    }

    func webExtensionController(_ c: WKWebExtensionController,
                                openOptionsPageFor ctx: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let browser, let url = ctx.optionsPageURL else {
            return completionHandler(ExtensionStore.Failure("this add-on has no options page"))
        }
        browser.openTab(url: url)
        completionHandler(nil)
    }

    /// Anything not already granted comes here. It is a real permission dialog, not an
    /// auto-yes: an add-on asking for a host it did not declare is exactly the case worth
    /// stopping on.
    func webExtensionController(_ c: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for ctx: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = ctx.webExtension.displayName ?? "This add-on"
        let list = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        if ask("\(name) wants additional permissions", detail: list) {
            completionHandler(permissions, nil)
        } else {
            completionHandler([], nil)
        }
    }

    func webExtensionController(_ c: WKWebExtensionController,
                                promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for ctx: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = ctx.webExtension.displayName ?? "This add-on"
        let list = patterns.map(\.string).sorted().joined(separator: "\n")
        if ask("\(name) wants access to more sites", detail: list) {
            completionHandler(patterns, nil)
        } else {
            completionHandler([], nil)
        }
    }

    func webExtensionController(_ c: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for ctx: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        guard let anchor = browser?.extensionAnchor(for: ctx) else {
            return completionHandler(nil)
        }
        present(action, from: anchor)
        completionHandler(nil)
    }

    func webExtensionController(_ c: WKWebExtensionController,
                                didUpdate action: WKWebExtension.Action,
                                forExtensionContext ctx: WKWebExtensionContext) {
        browser?.refreshExtensionButtons()
    }

    private func ask(_ title: String, detail: String) -> Bool {
        // No window means no user to ask, and defaulting to "yes" in that case would make
        // the prompt decorative. Headless runs deny.
        guard browser?.window != nil, NSApp.activationPolicy() == .regular else { return false }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don't Allow")
        return a.runModal() == .alertFirstButtonReturn
    }
}
