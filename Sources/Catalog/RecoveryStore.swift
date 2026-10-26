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

    /// The fields of an `Entry` needed to index it, decoded without its content.
    private struct Header: Decodable {
        var id: UUID
        var path: String?
        var modified: Date
    }

    /// path → draft id, built from disk on first lookup and kept current by
    /// `write` and `remove`, so opening a file decodes at most its own draft.
    /// Main thread only, like every caller.
    private static var pathIndex: [String: UUID]?

    private static func id(forPath path: String) -> UUID? {
        if let pathIndex { return pathIndex[path] }
        var newest: [String: Header] = [:]
        for url in draftFiles() {
            guard let data = try? Data(contentsOf: url),
                  let header = try? JSONDecoder().decode(Header.self, from: data),
                  let path = header.path else { continue }
            if let other = newest[path], other.modified >= header.modified { continue }
            newest[path] = header
        }
        let index = newest.mapValues(\.id)
        pathIndex = index
        return index[path]
    }

    private static func unindex(_ id: UUID) {
        pathIndex = pathIndex?.filter { $0.value != id }
    }

    private static func draftFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
    }

    @discardableResult
    static func write(_ doc: Document) -> Bool {
        let entry = Entry(id: doc.recoveryID, path: doc.url?.path, title: doc.customTitle,
                          content: doc.storage.string, modified: Date())
        guard let data = try? JSONEncoder().encode(entry),
              (try? data.write(to: fileURL(for: entry.id), options: .atomic)) != nil
        else { return false }
        if pathIndex != nil {
            unindex(entry.id)  // the buffer may have been saved under a new path
            if let path = entry.path { pathIndex?[path] = entry.id }
        }
        return true
    }

    static func remove(_ doc: Document) { remove(id: doc.recoveryID) }

    static func remove(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        unindex(id)
    }

    /// All drafts left behind by a previous run, oldest first.
    static func loadAll() -> [Entry] {
        draftFiles()
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Entry.self, from: data)
            }
            .sorted { $0.modified < $1.modified }
    }

    /// The draft mirroring `path`, if one survived a previous run.
    static func draft(forPath path: String) -> Entry? {
        guard let id = id(forPath: path),
              let data = try? Data(contentsOf: fileURL(for: id)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.path == path
        else {
            pathIndex?[path] = nil  // removed or rewritten behind our back
            return nil
        }
        return entry
    }
}
