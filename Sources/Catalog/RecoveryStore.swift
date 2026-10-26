import Foundation

/// Crash-recovery drafts. Every edited buffer is mirrored into Application
/// Support until its content is safely in its file (or explicitly discarded),
/// so a crash, force-quit, or plain quit never loses more than a moment of
/// typing. Entries found at launch are restored into the session.
enum RecoveryStore {

    struct Entry: Codable {
        var id: UUID
        var path: String?      // backing file; nil for untitled buffers
        var title: String?     // customTitle for untitled buffers
        var content: String
        var modified: Date
    }

    static let directory: URL = {
        let dir = AppState.supportDirectory.appendingPathComponent("Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    @discardableResult
    static func write(_ doc: Document) -> Bool {
        let entry = Entry(id: doc.recoveryID, path: doc.url?.path, title: doc.customTitle,
                          content: doc.storage.string, modified: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        return (try? data.write(to: fileURL(for: doc.recoveryID), options: .atomic)) != nil
    }

    static func remove(_ doc: Document) { remove(id: doc.recoveryID) }

    static func remove(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// All drafts left behind by a previous run, oldest first.
    static func loadAll() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Entry.self, from: data)
            }
            .sorted { $0.modified < $1.modified }
    }

    /// The draft mirroring `path`, if one survived a previous run.
    static func draft(forPath path: String) -> Entry? {
        loadAll().first { $0.path == path }
    }
}
