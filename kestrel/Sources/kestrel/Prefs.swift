import Foundation

/// Persisted preferences. Deliberately tiny — anything that needs a settings window
/// probably needs a reason first.
enum Prefs {
    private static let d = UserDefaults.standard

    /// Global memory budget in MB, so the slider position survives a restart.
    static var budgetMB: Double {
        get { let v = d.double(forKey: "budgetMB"); return v > 0 ? v : 1200 }
        set { d.set(newValue, forKey: "budgetMB") }
    }

    static var perTabCapMB: Int {
        get { d.integer(forKey: "perTabCapMB") }
        set { d.set(newValue, forKey: "perTabCapMB") }
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

    /// Vertical tab strip. The horizontal strip has no room for per-tab state and
    /// memory; the sidebar does, which is the readout this browser exists to show.
    static var verticalTabs: Bool {
        get { d.bool(forKey: "verticalTabs") }
        set { d.set(newValue, forKey: "verticalTabs") }
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

    /// Whether an enabled add-on shows a button in the toolbar. Off means it is still
    /// running — it only stops taking up nav bar width, and is opened from the add-ons
    /// menu instead. Stored as an opt-out so a newly installed add-on appears.
    static var toolbarHiddenExtensions: Set<String> {
        get { Set(d.stringArray(forKey: "toolbarHiddenExtensions") ?? []) }
        set { d.set(Array(newValue), forKey: "toolbarHiddenExtensions") }
    }
    static func isExtensionInToolbar(_ id: String) -> Bool {
        !toolbarHiddenExtensions.contains(id)
    }
    static func setExtensionInToolbar(_ show: Bool, id: String) {
        var s = toolbarHiddenExtensions
        if show { s.remove(id) } else { s.insert(id) }
        toolbarHiddenExtensions = s
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
