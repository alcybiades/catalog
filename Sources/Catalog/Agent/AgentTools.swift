import Foundation
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted on the main thread just before the assistant writes `url`, so
    /// windows can flush unsaved edits to that file first.
    static let agentWillModifyFile = Notification.Name("CatalogAgentWillModifyFile")
    /// Posted on the main thread after the assistant changed files. userInfo:
    /// "urls" ([URL]) and, for a move, "from" (URL) → "to" (URL).
    static let agentDidModifyFiles = Notification.Name("CatalogAgentDidModifyFiles")
}

/// What the assistant can see of the window when a message is sent.
struct AgentContext {
    enum Kind { case article, note, image, folder, home, other }

    var kind: Kind
    var title: String
    /// The note, image, or folder on disk.
    var fileURL: URL?
    var articleURL: URL?
    /// The article's or note's text.
    var text: String?
    var workingDirectory: URL

    var label: String {
        switch kind {
        case .article: return title
        case .note, .image, .folder: return fileURL?.lastPathComponent ?? title
        case .home, .other: return title
        }
    }
}

/// One tool call's outcome, as returned to Claude and shown in the panel.
struct ToolOutcome {
    var content: [[String: Any]]
    var isError = false
    /// Short line for the transcript ("Edited notes/Kyoto.md").
    var summary: String
    /// A file worth opening from the transcript.
    var url: URL?

    static func text(_ text: String, summary: String, url: URL? = nil) -> ToolOutcome {
        ToolOutcome(content: [["type": "text", "text": text]], summary: summary, url: url)
    }

    static func failure(_ message: String, summary: String) -> ToolOutcome {
        ToolOutcome(content: [["type": "text", "text": message]], isError: true, summary: summary)
    }
}

/// The assistant's file tools. Every path resolves inside the working
/// directory (or is the open file itself); nothing is ever deleted.
struct AgentTools {
    let root: URL
    /// The open note or image, reachable even outside the working directory.
    let openFile: URL?
    /// Opens a file in a tab, on the main thread.
    let openInTab: @MainActor (URL) -> Void

    static let definitions: [[String: Any]] = [
        tool("list_directory",
             "List files and folders. Folders end with \"/\". Hidden files are skipped.",
             ["path": ("string", "Folder path, relative to the working directory. Defaults to \".\"."),
              "recursive": ("boolean", "Include subfolders (up to 400 entries).")],
             required: []),
        tool("read_file",
             "Read a text file (Markdown, plain text, code). Images are returned as images.",
             ["path": ("string", "File path, relative to the working directory.")],
             required: ["path"]),
        tool("search_files",
             "Case-insensitive text search across text files. Returns path:line: matching line.",
             ["query": ("string", "Text to find."),
              "path": ("string", "Folder to search, relative to the working directory. Defaults to \".\".")],
             required: ["query"]),
        tool("write_file",
             "Create a file, or replace a file's entire contents. Creates missing parent folders. Prefer edit_file for changes to an existing file.",
             ["path": ("string", "File path, relative to the working directory. New notes should end in .md."),
              "content": ("string", "The complete file contents.")],
             required: ["path", "content"]),
        tool("edit_file",
             "Replace exact text in an existing file. old_text must match exactly once unless replace_all is true.",
             ["path": ("string", "File path, relative to the working directory."),
              "old_text": ("string", "The exact text to replace, including whitespace."),
              "new_text": ("string", "The replacement text."),
              "replace_all": ("boolean", "Replace every occurrence.")],
             required: ["path", "old_text", "new_text"]),
        tool("create_folder",
             "Create a folder (and any missing parents).",
             ["path": ("string", "Folder path, relative to the working directory.")],
             required: ["path"]),
        tool("move_file",
             "Move or rename a file or folder. Fails if the destination exists.",
             ["from": ("string", "Current path, relative to the working directory."),
              "to": ("string", "New path, relative to the working directory.")],
             required: ["from", "to"]),
        tool("open_file",
             "Open a file in a new tab of the user's window, so they can see it.",
             ["path": ("string", "File path, relative to the working directory.")],
             required: ["path"]),
        tool("read_wikipedia_article",
             "Fetch the full text of an English Wikipedia article by title (best match if inexact).",
             ["title": ("string", "The article title, e.g. \"Kyoto\".")],
             required: ["title"]),
    ]

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: (type: String, description: String)],
                             required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "eager_input_streaming": true,
            "input_schema": [
                "type": "object",
                "properties": properties.mapValues { ["type": $0.type, "description": $0.description] },
                "required": required,
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    /// One-line description of a call while it runs.
    static func describe(_ name: String, _ input: [String: Any]) -> String {
        let path = input["path"] as? String ?? "."
        switch name {
        case "list_directory": return "Listing \(path)"
        case "read_file": return "Reading \(path)"
        case "search_files": return "Searching for “\(input["query"] as? String ?? "")”"
        case "write_file": return "Writing \(path)"
        case "edit_file": return "Editing \(path)"
        case "create_folder": return "Creating \(path)/"
        case "move_file": return "Moving \(input["from"] as? String ?? "") → \(input["to"] as? String ?? "")"
        case "open_file": return "Opening \(path)"
        case "read_wikipedia_article": return "Reading “\(input["title"] as? String ?? "")” on Wikipedia"
        default: return name
        }
    }

    // MARK: Running

    func run(_ name: String, input: [String: Any]) async -> ToolOutcome {
        do {
            switch name {
            case "list_directory": return try list(input)
            case "read_file": return try read(input)
            case "search_files": return try search(input)
            case "write_file": return try await write(input)
            case "edit_file": return try await edit(input)
            case "create_folder": return try await createFolder(input)
            case "move_file": return try await move(input)
            case "open_file": return try await open(input)
            case "read_wikipedia_article": return try await wikipedia(input)
            default: return .failure("Unknown tool \(name).", summary: "Unknown tool \(name)")
            }
        } catch let error as ToolError {
            return .failure(error.message, summary: error.message)
        } catch {
            return .failure(error.localizedDescription, summary: error.localizedDescription)
        }
    }

    struct ToolError: Error { let message: String }

    private func string(_ input: [String: Any], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = input[key] as? String, allowEmpty || !value.isEmpty else {
            throw ToolError(message: "Missing required string \"\(key)\".")
        }
        return value
    }

    /// Resolves a model-supplied path and refuses anything outside the
    /// working directory, except the file the user has open.
    func resolve(_ raw: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded))
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let resolved = url.resolvingSymlinksInPath().pathComponents
        if resolved.starts(with: rootPath) { return url }
        if let openFile, openFile.standardizedFileURL.path == url.path { return url }
        throw ToolError(message: "\(raw) is outside the working directory (\(root.path)).")
    }

    func display(_ url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") { return String(path.dropFirst(rootPath.count + 1)) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func list(_ input: [String: Any]) throws -> ToolOutcome {
        let folder = try resolve(input["path"] as? String ?? ".")
        let recursive = input["recursive"] as? Bool ?? false
        let manager = FileManager.default
        var lines: [String] = []
        if recursive {
            let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL, lines.count < 400 {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                lines.append(display(url) + (isDirectory ? "/" : ""))
            }
        } else {
            let urls = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
            for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                lines.append(display(url) + (isDirectory ? "/" : ""))
            }
        }
        let body = lines.isEmpty ? "(empty)" : lines.joined(separator: "\n") + (lines.count >= 400 ? "\n… (truncated)" : "")
        return .text(body, summary: "Listed \(display(folder))")
    }

    private func read(_ input: [String: Any]) throws -> ToolOutcome {
        let url = try resolve(try string(input, "path"))
        if FileKind.classify(url) == .image {
            guard let image = NSImage(contentsOf: url), let data = AgentImage.jpeg(image) else {
                throw ToolError(message: "Couldn’t read the image \(display(url)).")
            }
            return ToolOutcome(content: [AgentImage.block(data)], summary: "Viewed \(display(url))", url: url)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "\(display(url)) isn’t a UTF-8 text file (\(data.count) bytes).")
        }
        let limit = 400_000
        let body = text.count > limit ? String(text.prefix(limit)) + "\n… (truncated at \(limit) characters)" : text
        return .text(body.isEmpty ? "(empty file)" : body, summary: "Read \(display(url))", url: url)
    }

    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "text", "csv", "json", "yaml", "yml",
                                                      "html", "css", "js", "ts", "swift", "py", "rb", "go", "rs", "toml"]

    private func search(_ input: [String: Any]) throws -> ToolOutcome {
        let query = try string(input, "query")
        let folder = try resolve(input["path"] as? String ?? ".")
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var results: [String] = []
        var scanned = 0
        while let url = enumerator?.nextObject() as? URL, results.count < 120, scanned < 4000 {
            guard Self.textExtensions.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if url.lastPathComponent.localizedCaseInsensitiveContains(query) { results.append(display(url) + ": (file name)") }
            for (index, line) in text.components(separatedBy: .newlines).enumerated()
            where line.localizedCaseInsensitiveContains(query) {
                results.append("\(display(url)):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
                if results.count >= 120 { break }
            }
        }
        let body = results.isEmpty ? "No matches." : results.joined(separator: "\n")
        return .text(body, summary: "Searched for “\(query)” · \(results.count) match\(results.count == 1 ? "" : "es")")
    }

    private func write(_ input: [String: Any]) async throws -> ToolOutcome {
        let url = try resolve(try string(input, "path"))
        let content = try string(input, "content", allowEmpty: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        await Self.willModify(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        await Self.didModify([url])
        let verb = existed ? "Rewrote" : "Created"
        return .text("\(verb) \(display(url)) (\(content.count) characters).", summary: "\(verb) \(display(url))", url: url)
    }

    private func edit(_ input: [String: Any]) async throws -> ToolOutcome {
        let url = try resolve(try string(input, "path"))
        let old = try string(input, "old_text")
        let new = try string(input, "new_text", allowEmpty: true)
        let replaceAll = input["replace_all"] as? Bool ?? false
        await Self.willModify(url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError(message: "Couldn’t read \(display(url)) as text.")
        }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else { throw ToolError(message: "old_text was not found in \(display(url)). Read the file and copy the text exactly.") }
        guard count == 1 || replaceAll else {
            throw ToolError(message: "old_text appears \(count) times in \(display(url)). Include more surrounding text, or set replace_all.")
        }
        let updated: String
        if replaceAll {
            updated = text.replacingOccurrences(of: old, with: new)
        } else {
            let range = text.range(of: old)!
            updated = text.replacingCharacters(in: range, with: new)
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        await Self.didModify([url])
        let times = replaceAll && count > 1 ? " (\(count) places)" : ""
        return .text("Edited \(display(url))\(times).", summary: "Edited \(display(url))\(times)", url: url)
    }

    private func createFolder(_ input: [String: Any]) async throws -> ToolOutcome {
        let url = try resolve(try string(input, "path"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await Self.didModify([url])
        return .text("Created \(display(url))/.", summary: "Created \(display(url))/")
    }

    private func move(_ input: [String: Any]) async throws -> ToolOutcome {
        let from = try resolve(try string(input, "from"))
        let to = try resolve(try string(input, "to"))
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw ToolError(message: "\(display(to)) already exists.")
        }
        await Self.willModify(from)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
        await MainActor.run {
            NotificationCenter.default.post(name: .agentDidModifyFiles, object: nil,
                                            userInfo: ["urls": [from, to], "from": from, "to": to])
        }
        return .text("Moved \(display(from)) to \(display(to)).", summary: "Moved \(display(from)) → \(display(to))", url: to)
    }

    private func open(_ input: [String: Any]) async throws -> ToolOutcome {
        let url = try resolve(try string(input, "path"))
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "\(display(url)) doesn’t exist.") }
        await openInTab(url)
        return .text("Opened \(display(url)) in a tab.", summary: "Opened \(display(url))", url: url)
    }

    private func wikipedia(_ input: [String: Any]) async throws -> ToolOutcome {
        let title = try string(input, "title")
        let article = try await WikipediaClient.article(for: title)
        return .text("<article title=\"\(article.title)\" url=\"\(article.url.absoluteString)\">\n\(article.plainText)\n</article>",
                     summary: "Read “\(article.title)” on Wikipedia")
    }

    @MainActor private static func willModify(_ url: URL) {
        NotificationCenter.default.post(name: .agentWillModifyFile, object: nil, userInfo: ["url": url])
    }

    @MainActor private static func didModify(_ urls: [URL]) {
        NotificationCenter.default.post(name: .agentDidModifyFiles, object: nil, userInfo: ["urls": urls])
    }
}

/// Images sent to Claude: downscaled JPEG, base64 in an image block.
enum AgentImage {
    static func jpeg(_ image: NSImage, maxSide: CGFloat = 1568) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    static func block(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
}
