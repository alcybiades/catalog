import Foundation

/// Automated runs never read or write the user's preferences or recovery drafts.
/// Each run gets a fresh profile, so even a crash cannot pollute a later session.
enum AppState {
    static let isTesting: Bool = {
        #if CATALOG_TESTING
        return true
        #else
        return CommandLine.arguments.contains("--test-mode")
            || ProcessInfo.processInfo.environment["CATALOG_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["WRITE_TEST_MODE"] == "1"
        #endif
    }()

    private static let testID = UUID().uuidString
    static let defaults: UserDefaults = {
        guard isTesting else { return .standard }
        guard let defaults = UserDefaults(suiteName: "com.grant.catalog.tests.\(testID)") else {
            fatalError("Cannot create isolated test preferences")
        }
        return defaults
    }()

    static let supportDirectory: URL = {
        if isTesting {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("CatalogTests-\(testID)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Catalog", isDirectory: true)
    }()

    /// The app was called Write until it became Catalog. On first launch as
    /// Catalog, bring over Write's preferences (session, recents, fonts,
    /// colors) and its recovery drafts. The originals are left in place.
    static func migrateFromWrite() {
        guard !isTesting else { return }
        let defaults = UserDefaults.standard
        let flag = "migratedFromWrite"
        guard !defaults.bool(forKey: flag) else { return }
        if let old = defaults.persistentDomain(forName: "com.grant.write") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        let manager = FileManager.default
        if let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let old = base.appendingPathComponent("Write", isDirectory: true)
            if manager.fileExists(atPath: old.path), !manager.fileExists(atPath: supportDirectory.path) {
                try? manager.copyItem(at: old, to: supportDirectory)
            }
        }
        defaults.set(true, forKey: flag)
    }
}
