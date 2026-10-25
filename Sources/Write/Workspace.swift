import AppKit
import UniformTypeIdentifiers

/// Filesystem paths are identities; links are standard source-relative Markdown.
/// This deliberately needs no database, workspace ID, or proprietary URL scheme.
enum FileReference {
    /// Where a link points. Markdown destinations (`](…)`) and Obsidian
    /// wiki links (`[[…]]`) both reduce to one of these.
    enum Target {
        case file(URL, anchor: String?)
        case external(URL)
        /// A bare `#heading` anchor inside the current document.
        case anchor(String)
        case unresolved
    }

    static func relativePath(to target: URL, from directory: URL) -> String {
        let targetParts = target.standardizedFileURL.pathComponents
        let baseParts = directory.standardizedFileURL.pathComponents
        var common = 0
        while common < min(targetParts.count, baseParts.count), targetParts[common] == baseParts[common] { common += 1 }
        return (Array(repeating: "..", count: baseParts.count - common) + targetParts.dropFirst(common)).joined(separator: "/")
    }

    /// Percent-encodes a relative path for a Markdown destination, leaving
    /// the separators and the unreserved set legible.
    static func encode(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        return path.addingPercentEncoding(withAllowedCharacters: safe) ?? path
    }

    static func markdown(to target: URL, from source: URL) -> String {
        let encoded = encode(relativePath(to: target, from: source.deletingLastPathComponent()))
        let name = target.lastPathComponent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[@\(name)](\(encoded))"
    }

    private static let schemePrefix = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#)
    /// CommonMark allows a title after the destination: `](path "Title")`.
    private static let trailingTitle = try! NSRegularExpression(pattern: #"\s+(?:"[^"]*"|'[^']*'|\([^)]*\))$"#)

    /// Classifies a Markdown link destination. Relative paths resolve
    /// against the directory of the file containing the link, exactly as
    /// GitHub renders them.
    static func target(_ raw: String, from source: URL?) -> Target {
        var destination = raw.trimmingCharacters(in: .whitespaces)
        if destination.hasPrefix("<"), destination.hasSuffix(">"), destination.count >= 2 {
            destination = String(destination.dropFirst().dropLast())
        }
        let full = NSRange(location: 0, length: (destination as NSString).length)
        if let title = trailingTitle.firstMatch(in: destination, range: full) {
            destination = (destination as NSString).substring(to: title.range.location)
        }
        destination = destination.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return .unresolved }

        if destination.hasPrefix("#") {
            return .anchor(anchorText(String(destination.dropFirst())))
        }
        if let match = schemePrefix.firstMatch(in: destination, range: NSRange(location: 0, length: (destination as NSString).length)) {
            let scheme = (destination as NSString).substring(to: match.range.length - 1).lowercased()
            guard scheme == "file" else {
                return URL(string: destination).map(Target.external) ?? .unresolved
            }
            guard let url = URL(string: destination), url.isFileURL else { return .unresolved }
            return .file(url.standardizedFileURL, anchor: nil)
        }

        var anchor: String?
        if let hash = destination.firstIndex(of: "#") {
            anchor = anchorText(String(destination[destination.index(after: hash)...]))
            destination = String(destination[..<hash])
        }
        guard !destination.isEmpty else {
            return anchor.map(Target.anchor) ?? .unresolved
        }
        let decoded = destination.removingPercentEncoding ?? destination
        let expanded = (decoded as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let source {
            url = source.deletingLastPathComponent().appendingPathComponent(expanded)
        } else {
            return .unresolved
        }
        return .file(url.standardizedFileURL, anchor: anchor)
    }

    private static func anchorText(_ raw: String) -> String {
        (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespaces)
    }

    static func resolve(_ destination: String, from source: URL) -> URL? {
        if case .file(let url, _) = target(destination, from: source) { return url }
        return nil
    }

    /// Splits `Note#Heading` (or `Note|Alias` handled by the caller) into
    /// its file part and heading anchor.
    static func splitAnchor(_ raw: String) -> (name: String, anchor: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let hash = trimmed.firstIndex(of: "#") else { return (trimmed, nil) }
        let anchor = anchorText(String(trimmed[trimmed.index(after: hash)...]))
        return (String(trimmed[..<hash]).trimmingCharacters(in: .whitespaces),
                anchor.isEmpty ? nil : anchor)
    }

    /// Markdown extensions a bare wiki-link name may be spelled without.
    static let markdownExtensions = ["md", "markdown", "txt"]

    /// Wiki-link resolution with no workspace index: siblings of the source
    /// file (and paths relative to it) only.
    static func resolveWikiSibling(_ raw: String, from source: URL) -> URL? {
        let name = splitAnchor(raw).name
        guard !name.isEmpty else { return nil }
        let base = source.deletingLastPathComponent()
        for candidate in [name] + markdownExtensions.map({ "\(name).\($0)" }) {
            let url = base.appendingPathComponent(candidate).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// GitHub/Obsidian heading anchors slugged symmetrically, so either
    /// spelling — `#My Heading` or `#my-heading` — finds the same heading.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else if scalar == "_" {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append("_")
            } else {
                pendingDash = true
            }
        }
        return out
    }
}

enum FileKind {
    /// `wiki` tabs hold a Wikipedia page rather than a file; classify never returns it.
    case markdown, image, unsupported, folder, wiki
    static func classify(_ url: URL) -> FileKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) { return .markdown }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return .image }
        return .unsupported
    }
}

enum WorkspaceItemKind {
    case file, markdown, folder

    func create(named name: String, in directory: URL) throws -> URL {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0"), !name.hasPrefix(".") else {
            throw NSError(domain: "Write", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Enter a visible file or folder name without slashes or colons."])
        }
        if self == .markdown && !["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            name += ".md"
        }
        let url = directory.appendingPathComponent(name, isDirectory: self == .folder)
        if self == .folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            // Exclusive creation also protects against a file appearing while the sheet is open.
            try Data().write(to: url, options: .withoutOverwriting)
        }
        return url
    }
}

final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var cachedChildren: [FileNode]?
    init(_ url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Never recurse through symlinks (cycles and trees outside the workspace).
        isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
    }
    var children: [FileNode] {
        if let cachedChildren { return cachedChildren }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.map(FileNode.init).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        cachedChildren = nodes
        return nodes
    }
}

final class Workspace {
    let root: URL
    private(set) var files: [URL] = []
    /// Lower-cased file name *and* extension-less stem → matching files.
    /// Wiki links name a note rather than a path, so they resolve through
    /// this instead of the filesystem.
    private var namesIndex: [String: [URL]] = [:]
    private var generation = UUID()
    var onIndexChanged: (() -> Void)?
    init(root: URL) { self.root = root.standardizedFileURL; refreshIndex() }
    func refreshIndex() {
        let token = UUID(); generation = token
        let root = root
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var result: [URL] = []
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
                if values?.isDirectory != true { result.append(url) }
            }
            let sorted = result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let names = Workspace.buildNamesIndex(sorted)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.files = sorted
                self.namesIndex = names
                self.onIndexChanged?()
            }
        }
    }
    func matches(_ query: String) -> [URL] {
        Array(files.filter { query.isEmpty || FileReference.relativePath(to: $0, from: root).localizedCaseInsensitiveContains(query) }.prefix(80))
    }

    private static func buildNamesIndex(_ files: [URL]) -> [String: [URL]] {
        var index: [String: [URL]] = [:]
        for url in files {
            let name = url.lastPathComponent.lowercased()
            index[name, default: []].append(url)
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if stem != name { index[stem, default: []].append(url) }
        }
        return index
    }

    /// Resolves an Obsidian-style wiki-link target. A target containing a
    /// slash is a path (source-relative first, then root-relative); a bare
    /// target is a note name looked up across the whole workspace, with
    /// the copy nearest the linking document winning a tie.
    func resolveWikiLink(_ raw: String, from source: URL?) -> URL? {
        let name = FileReference.splitAnchor(raw).name
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            var bases: [URL] = []
            if let source { bases.append(source.deletingLastPathComponent()) }
            bases.append(root)
            for base in bases {
                for candidate in [name] + FileReference.markdownExtensions.map({ "\(name).\($0)" }) {
                    let url = base.appendingPathComponent(candidate).standardizedFileURL
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
            return source.flatMap { FileReference.resolveWikiSibling(name, from: $0) }
        }
        let candidates = namesIndex[name.lowercased()] ?? []
        guard !candidates.isEmpty else {
            return source.flatMap { FileReference.resolveWikiSibling(name, from: $0) }
        }
        guard candidates.count > 1 else { return candidates[0] }
        let sourceParts = source.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents } ?? []
        func rank(_ url: URL) -> (Int, Int, String) {
            // Prefer a note over a same-named asset, then the copy sharing
            // the longest directory prefix with the linking document.
            let isMarkdown = FileKind.classify(url) == .markdown ? 0 : 1
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var shared = 0
            while shared < min(parts.count, sourceParts.count), parts[shared] == sourceParts[shared] { shared += 1 }
            return (isMarkdown, -shared, url.path)
        }
        return candidates.min {
            let (a, b) = (rank($0), rank($1))
            return a.0 != b.0 ? a.0 < b.0 : (a.1 != b.1 ? a.1 < b.1 : a.2 < b.2)
        }
    }

    /// The shortest spelling that still names `url` unambiguously — a bare
    /// stem when it is unique in the workspace, a root-relative path when
    /// it is not.
    func wikiName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let isMarkdown = FileKind.classify(url) == .markdown
        let bare = isMarkdown ? stem : url.lastPathComponent
        // Zero matches means the index is still building; the bare name is
        // the better guess, since the picker only offers workspace files.
        if (namesIndex[bare.lowercased()] ?? []).count <= 1 { return bare }
        let path = FileReference.relativePath(to: url, from: root)
        guard isMarkdown else { return path }
        return (path as NSString).deletingPathExtension
    }
}
