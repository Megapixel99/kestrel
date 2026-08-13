import AppKit
import WebKit

/// Container tabs: separate cookie jars in the same window.
///
/// Firefox calls these contextual identities. A tab in a container gets its own cookies,
/// local storage and cache, so you can be signed into two accounts on one site, or keep a
/// site from recognising you across contexts, without a second profile or a private window.
///
/// It is also the one thing on the shortlist that WebKit's extension runtime explicitly
/// refuses add-ons: `contextualIdentities` is in `ExtensionStore.unsupportedPermissions`,
/// so an add-on cannot provide this and the browser has to. That made it worth building
/// rather than delegating.
///
/// The isolation is real rather than cosmetic: each container has its own
/// `WKWebsiteDataStore(forIdentifier:)`, which is WebKit's own partition boundary.
/// `sessiontest` proves it by setting a cookie in one container and failing to read it in
/// another.
struct Container: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Index into `Container.palette`, so the stored form stays a plain Codable.
    var colorIndex: Int

    static let palette: [(String, NSColor)] = [
        ("Blue", .systemBlue), ("Green", .systemGreen), ("Orange", .systemOrange),
        ("Purple", .systemPurple), ("Red", .systemRed), ("Teal", .systemTeal),
    ]

    var color: NSColor { Container.palette[colorIndex % Container.palette.count].1 }

    /// WebKit keys a data store by UUID, and that key must be stable across launches or
    /// the container silently forgets everything each time the browser starts.
    @available(macOS 14.0, *)
    @MainActor
    var dataStore: WKWebsiteDataStore { ContainerStore.store(for: self) }
}

enum ContainerStore {

    /// Data stores are expensive and must be created once per identifier per process:
    /// asking WebKit for the same identifier twice yields two objects that do not share
    /// state, which would defeat the point.
    @available(macOS 14.0, *)
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    @available(macOS 14.0, *)
    @MainActor
    static func store(for container: Container) -> WKWebsiteDataStore {
        if let existing = stores[container.id] { return existing }
        let s = WKWebsiteDataStore(forIdentifier: container.id)
        stores[container.id] = s
        return s
    }

    static var all: [Container] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "containers"),
                  let c = try? JSONDecoder().decode([Container].self, from: d)
            else { return defaults }
            return c
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: "containers")
            }
        }
    }

    /// Firefox ships four out of the box, and the names are good ones: the point of a
    /// container is the intent behind it, not the colour.
    private static let defaults: [Container] = [
        Container(id: UUID(uuidString: "1E57A5D0-0000-4000-8000-000000000001")!,
                  name: "Personal", colorIndex: 0),
        Container(id: UUID(uuidString: "1E57A5D0-0000-4000-8000-000000000002")!,
                  name: "Work", colorIndex: 1),
        Container(id: UUID(uuidString: "1E57A5D0-0000-4000-8000-000000000003")!,
                  name: "Shopping", colorIndex: 2),
        Container(id: UUID(uuidString: "1E57A5D0-0000-4000-8000-000000000004")!,
                  name: "Banking", colorIndex: 4),
    ]

    static func add(name: String) -> Container {
        let c = Container(id: UUID(), name: name, colorIndex: all.count % Container.palette.count)
        all.append(c)
        return c
    }

    static func remove(_ container: Container) {
        all.removeAll { $0.id == container.id }
        if #available(macOS 14.0, *) {
            // The data goes with it — a container removed but whose cookies survive is
            // worse than no container at all.
            let store = MainActor.assumeIsolated { self.store(for: container) }
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { rec in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                 for: rec) {}
            }
            stores[container.id] = nil
            try? WKWebsiteDataStore.remove(forIdentifier: container.id) { _ in }
        }
    }

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }
}
