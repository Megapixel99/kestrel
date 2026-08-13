import Foundation

/// Persisted preferences. Deliberately tiny — anything that needs a settings window
/// probably needs a reason first.
enum Prefs {
    private static let d = UserDefaults.standard

    /// Apply dark mode to every page automatically.
    static var darkByDefault: Bool {
        get { d.bool(forKey: "darkByDefault") }
        set { d.set(newValue, forKey: "darkByDefault") }
    }

    /// Global memory budget in MB, so the slider position survives a restart.
    static var budgetMB: Double {
        get { let v = d.double(forKey: "budgetMB"); return v > 0 ? v : 1200 }
        set { d.set(newValue, forKey: "budgetMB") }
    }

    static var perTabCapMB: Int {
        get { d.integer(forKey: "perTabCapMB") }
        set { d.set(newValue, forKey: "perTabCapMB") }
    }

    // Dark Reader filter settings, mapped straight onto DarkReader.enable().
    private static func intPref(_ key: String, _ fallback: Int) -> Int {
        d.object(forKey: key) == nil ? fallback : d.integer(forKey: key)
    }
    static var drBrightness: Int {
        get { intPref("drBrightness", 100) } set { d.set(newValue, forKey: "drBrightness") }
    }
    static var drContrast: Int {
        get { intPref("drContrast", 90) } set { d.set(newValue, forKey: "drContrast") }
    }
    static var drSepia: Int {
        get { intPref("drSepia", 10) } set { d.set(newValue, forKey: "drSepia") }
    }
    static var drGrayscale: Int {
        get { intPref("drGrayscale", 0) } set { d.set(newValue, forKey: "drGrayscale") }
    }

    /// Remembered camera/microphone answers, keyed by "host|kind".
    static var mediaDecisions: [String: Bool] {
        get { (d.dictionary(forKey: "mediaDecisions") as? [String: Bool]) ?? [:] }
        set { d.set(newValue, forKey: "mediaDecisions") }
    }
    static func mediaDecision(for key: String) -> Bool? { mediaDecisions[key] }
    static func setMediaDecision(_ allow: Bool, for key: String) {
        var m = mediaDecisions; m[key] = allow; mediaDecisions = m
    }

    /// Sites where dark mode is never applied. Dark Reader mis-handles some pages —
    /// APU's CAS login loses its accent colours and form controls — and the honest fix
    /// is to let the user exclude a site permanently rather than fight the theming.
    static var darkExcludedHosts: Set<String> {
        get { Set(d.stringArray(forKey: "darkExcludedHosts") ?? []) }
        set { d.set(Array(newValue), forKey: "darkExcludedHosts") }
    }
    static func isDarkExcluded(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return darkExcludedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
    static func setDarkExcluded(_ excluded: Bool, host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        var s = darkExcludedHosts
        if excluded { s.insert(host) } else { s.remove(host) }
        darkExcludedHosts = s
    }

    /// Vertical tab strip. The horizontal strip has no room for per-tab state and
    /// memory; the sidebar does, which is the readout this browser exists to show.
    static var verticalTabs: Bool {
        get { d.bool(forKey: "verticalTabs") }
        set { d.set(newValue, forKey: "verticalTabs") }
    }

    /// Capture: what to do afterwards, and in what format.
    static var shotThen: String {
        get { d.string(forKey: "shotThen") ?? "Open in editor" }
        set { d.set(newValue, forKey: "shotThen") }
    }
    static var shotFormat: String {
        get { d.string(forKey: "shotFormat") ?? "PNG" }
        set { d.set(newValue, forKey: "shotFormat") }
    }

    /// Disabled userscripts, by @name. Absent means enabled.
    static var disabledScripts: Set<String> {
        get { Set(d.stringArray(forKey: "disabledScripts") ?? []) }
        set { d.set(Array(newValue), forKey: "disabledScripts") }
    }
    static func isScriptEnabled(_ name: String) -> Bool { !disabledScripts.contains(name) }
    static func setScript(_ name: String, enabled: Bool) {
        var s = disabledScripts
        if enabled { s.remove(name) } else { s.insert(name) }
        disabledScripts = s
    }

    /// Per-site ad blocking. Stored as an opt-out list so blocking is on by default.
    static var blockingDisabledHosts: Set<String> {
        get { Set(d.stringArray(forKey: "blockingDisabledHosts") ?? []) }
        set { d.set(Array(newValue), forKey: "blockingDisabledHosts") }
    }
    static func isBlockingEnabled(host: String) -> Bool {
        !blockingDisabledHosts.contains(host.lowercased())
    }
    static func setBlocking(enabled: Bool, host: String) {
        var set = blockingDisabledHosts
        if enabled { set.remove(host.lowercased()) } else { set.insert(host.lowercased()) }
        blockingDisabledHosts = set
    }

    /// Installed add-ons are opt-in: an extension on disk does nothing until enabled,
    /// because enabling it is the moment its permissions are granted.
    static var enabledExtensions: Set<String> {
        get { Set(d.stringArray(forKey: "enabledExtensions") ?? []) }
        set { d.set(Array(newValue), forKey: "enabledExtensions") }
    }
    static func isExtensionEnabled(_ id: String) -> Bool { enabledExtensions.contains(id) }
    static func setExtensionEnabled(_ on: Bool, id: String) {
        var s = enabledExtensions
        if on { s.insert(id) } else { s.remove(id) }
        enabledExtensions = s
    }

    /// WebKit keys an extension's storage by `uniqueIdentifier`. Handing it a fresh UUID
    /// each launch would wipe the add-on's settings every time Kestrel started, so the
    /// first one generated is kept.
    static func extensionUUID(for id: String) -> String {
        var map = (d.dictionary(forKey: "extensionUUIDs") as? [String: String]) ?? [:]
        if let existing = map[id] { return existing }
        let fresh = UUID().uuidString
        map[id] = fresh
        d.set(map, forKey: "extensionUUIDs")
        return fresh
    }
}
