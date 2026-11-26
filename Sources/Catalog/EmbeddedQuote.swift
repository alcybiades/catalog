import AppKit
import UniformTypeIdentifiers

/// An embedded quote: a Markdown blockquote that holds a passage in full and
/// ends with an attribution line linking to where it came from.
///
///     > The quoted passage, in full…
///     > — [Kyoto § History](encyclopedia://wiki/Kyoto#History)
///
/// The quoted text lives in the file, so the note reads the same on GitHub or
/// in Obsidian. Catalog draws the block as a card whose source line opens the
/// note heading, Wikipedia section, or media file the link names. A media
/// quote's body is the image itself: `> ![Caption](photo.jpg)`.
enum EmbeddedQuote {

    /// What a quote's attribution link points at.
    enum Source: Equatable {
        case note(URL, anchor: String?)
        case wikipedia(title: String, section: String?)
        case media(URL)
        case web(URL)
        case unresolved
    }

    /// A quote apart from where it is pasted: file targets stay absolute
    /// until `markdown(_:relativeTo:)` spells them for a particular note.
    struct Quote: Codable, Equatable {
        enum Kind: String, Codable { case note, wikipedia, media }
        var kind: Kind
        /// The passage as Markdown, without `> ` prefixes. Unused for media.
        var body: String
        var label: String
        /// An absolute file path (note, media) or an article title.
        var target: String
        /// A heading slug (note) or Wikipedia section anchor.
        var anchor: String?
        /// An image shown above the body: an absolute path or a web URL (a
        /// Wikipedia figure). A media quote's image is its target.
        var image: String? = nil
    }

    /// The syntax, as the assistant's instructions teach it.
    static let agentGuide = """
    To quote a note section, a Wikipedia section, or an image into a note, write an embedded quote (Catalog shows it as \
    a card that opens its source): a blockquote holding the quoted text in full (a bare ">" line between paragraphs) \
    whose last line is "> — [Title § Section](link)". Links: encyclopedia://wiki/Kyoto#Early_history (section anchor = \
    heading with underscores); a note path relative to the note being written, percent-encoded, with a GitHub heading \
    slug, e.g. Field%20Guide.md#second-section; for an image, the body is "> ![Caption](photos/a.jpg)" and the last \
    line "> — [Caption](photos/a.jpg)". Leave a blank line before and after the quote.
    """

    // MARK: - Writing

    static let wikiScheme = "encyclopedia"

    /// Escapes a link label so brackets in titles can't end it early.
    static func escapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: #"\\([\[\]\\])"#, with: "$1", options: .regularExpression)
    }

    /// `encyclopedia://wiki/Title#Anchor`, with underscores for spaces and
    /// parentheses escaped so the link survives inside `](…)`.
    static func wikiDestination(title: String, section: String?) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()#?%")
        let path = title.replacingOccurrences(of: " ", with: "_")
        var destination = "\(wikiScheme)://wiki/" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
        if let section, !section.isEmpty {
            let anchor = section.replacingOccurrences(of: " ", with: "_")
            destination += "#" + (anchor.addingPercentEncoding(withAllowedCharacters: allowed) ?? anchor)
        }
        return destination
    }

    /// The link destination as written into `note`: relative to its folder
    /// for files, the way `FileReference` spells links. Without a note (plain
    /// text bound for another app) file targets stay absolute.
    static func destination(of quote: Quote, relativeTo note: URL?) -> String {
        switch quote.kind {
        case .wikipedia:
            return wikiDestination(title: quote.target, section: quote.anchor)
        case .note, .media:
            var destination = spell(quote.target, relativeTo: note)
            if let anchor = quote.anchor, !anchor.isEmpty { destination += "#" + FileReference.encode(anchor) }
            return destination
        }
    }

    /// An absolute path as a link destination from `note` (or absolute
    /// without one); a web URL as is.
    private static func spell(_ target: String, relativeTo note: URL?) -> String {
        guard target.hasPrefix("/") else {
            return target.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                .replacingOccurrences(of: " ", with: "%20")
        }
        let file = URL(fileURLWithPath: target)
        return FileReference.encode(note.map { FileReference.relativePath(to: file, from: $0.deletingLastPathComponent()) } ?? file.path)
    }

    /// Prefixes every line with `> `; blank lines become a bare `>` so the
    /// paragraphs stay inside one blockquote.
    static func blockquote(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? ">" : "> " + line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    /// The quote's Markdown, with no trailing newline.
    static func markdown(_ quote: Quote, relativeTo note: URL?) -> String {
        let destination = destination(of: quote, relativeTo: note)
        let label = escapeLabel(quote.label)
        var parts: [String] = []
        if quote.kind == .media {
            parts.append("![\(label)](\(destination))")
        } else if let image = quote.image {
            // The figure's caption is the body; its alt text repeats it.
            let alt = escapeLabel(quote.body.components(separatedBy: "\n").first ?? "")
            parts.append("![\(alt)](\(spell(image, relativeTo: note)))")
        }
        let body = quote.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if quote.kind != .media, !body.isEmpty { parts.append(body) }
        return blockquote(parts.joined(separator: "\n")) + "\n> — [\(label)](\(destination))"
    }

    /// Pads `markdown` with blank lines so it stands as its own block where
    /// it replaces `range`: a line straight after a blockquote would
    /// otherwise continue it.
    static func padded(_ markdown: String, in text: NSString, replacing range: NSRange) -> String {
        var out = markdown
        let before = text.substring(to: range.location)
        let after = text.substring(from: NSMaxRange(range))
        if !before.isEmpty {
            if !before.hasSuffix("\n") { out = "\n\n" + out } else if !before.hasSuffix("\n\n") { out = "\n" + out }
        }
        if after.isEmpty || after.hasPrefix("\n\n") {
            out += after.isEmpty ? "\n" : ""
        } else {
            out += after.hasPrefix("\n") ? "\n" : "\n\n"
        }
        return out
    }

    // MARK: - Making quotes

    private static let headingLine = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*?)[ \t#]*$"#)

    /// Quotes `selection` of a note: the passage in full, attributed to the
    /// file and the nearest heading at or above it.
    static func noteQuote(text: NSString, selection: NSRange, file: URL) -> Quote? {
        let passage = text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return nil }
        let heading = MarkdownHighlighter.outline(of: text).last { $0.location <= selection.location }
        let name = file.deletingPathExtension().lastPathComponent
        // Headings can't render inside a quote's card; keep their words as a bold line.
        let body = passage.components(separatedBy: "\n").map { line -> String in
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let m = headingLine.firstMatch(in: line, range: range) else { return line }
            let title = (line as NSString).substring(with: m.range(at: 2))
            return title.isEmpty ? "" : "**\(title)**"
        }.joined(separator: "\n")
        return Quote(kind: .note, body: body,
                     label: heading.map { "\(name) § \($0.title)" } ?? name,
                     target: file.standardizedFileURL.path,
                     anchor: heading.map { FileReference.slug($0.title) })
    }

    /// A media quote's caption: the file name, made readable. It's an
    /// ordinary link label, so it can be rewritten in place afterwards.
    static func caption(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? file.lastPathComponent : stem
    }

    static func mediaQuote(file: URL) -> Quote {
        Quote(kind: .media, body: "", label: caption(for: file), target: file.standardizedFileURL.path, anchor: nil)
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }

    static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
    }

    // MARK: - Pasteboard

    /// Rides beside the plain-text Markdown so a paste into a note can spell
    /// file links relative to that note rather than the one they came from.
    static let pasteboardType = NSPasteboard.PasteboardType("com.grant.catalog.embedded-quote")

    /// Writes the quote: Markdown with absolute file links as plain text, and
    /// the quote itself for Catalog's own paste.
    static func write(_ quote: Quote, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, pasteboardType], owner: nil)
        pasteboard.setString(markdown(quote, relativeTo: nil), forType: .string)
        if let data = try? JSONEncoder().encode(quote) { pasteboard.setData(data, forType: pasteboardType) }
    }

    static func read(from pasteboard: NSPasteboard) -> Quote? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(Quote.self, from: data)
    }

    // MARK: - Reading

    /// A quote block found in a note.
    struct Block: Equatable {
        /// Every line of the block, through the attribution's newline.
        var range: NSRange
        /// Body lines (attribution excluded).
        var lines: [NSRange]
        var attribution: Attribution
    }

    /// The `> — [label](destination)` line closing a block.
    struct Attribution: Equatable {
        var line: NSRange
        /// The label's source characters, escapes included.
        var labelRange: NSRange
        var label: String
        var destination: String
    }

    static let quoteLine = try! NSRegularExpression(pattern: #"^[ \t]*>"#)
    /// The em dash is canonical; `--` and an en dash are accepted for typing.
    static let attributionLine = try! NSRegularExpression(
        pattern: #"^[ \t]*>[ \t]*(?:—|–|--)[ \t]*\[((?:\\.|[^\]\\\n])*)\]\(([^)\n]*)\)[ \t]*$"#)

    private static func isQuoteLine(_ text: NSString, _ lineRange: NSRange) -> Bool {
        quoteLine.firstMatch(in: text as String, range: lineRange) != nil
    }

    /// The run of consecutive `>` lines around `location`, if its line is one.
    static func quoteRun(containing location: Int, in text: NSString) -> NSRange? {
        guard text.length > 0, location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        guard isQuoteLine(text, line) else { return nil }
        var start = line.location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isQuoteLine(text, previous) else { break }
            start = previous.location
        }
        var end = NSMaxRange(line)
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            guard isQuoteLine(text, next) else { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: start, length: end - start)
    }

    /// The embedded quote whose block covers `location`: a `>` run whose
    /// last line is an attribution and which quotes something above it.
    static func block(containing location: Int, in text: NSString) -> Block? {
        guard let run = quoteRun(containing: location, in: text) else { return nil }
        return block(in: run, text: text)
    }

    static func block(in run: NSRange, text: NSString) -> Block? {
        var lines: [NSRange] = []
        var position = run.location
        while position < NSMaxRange(run) {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            lines.append(line)
            position = NSMaxRange(line)
        }
        guard let last = lines.popLast() else { return nil }
        var content = last
        if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
        guard let m = attributionLine.firstMatch(in: text as String, range: content) else { return nil }
        let hasBody = lines.contains { line in
            text.substring(with: line).replacingOccurrences(of: #"^[\s>]*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard hasBody else { return nil }
        let label = text.substring(with: m.range(at: 1))
        return Block(range: run, lines: lines,
                     attribution: Attribution(line: last, labelRange: m.range(at: 1),
                                              label: unescapeLabel(label),
                                              destination: text.substring(with: m.range(at: 2))))
    }

    /// Every embedded quote in a note, top to bottom.
    static func blocks(in text: NSString) -> [Block] {
        var result: [Block] = []
        var position = 0
        while position < text.length {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            if let run = quoteRun(containing: position, in: text) {
                if let block = block(in: run, text: text) { result.append(block) }
                position = NSMaxRange(run)
            } else {
                position = NSMaxRange(line)
            }
        }
        return result
    }

    /// The first line of quoted text, prefixes stripped: what opening the
    /// source looks for to highlight the passage.
    static func excerpt(of block: Block, in text: NSString) -> String? {
        for line in block.lines {
            let content = text.substring(with: line)
                .replacingOccurrences(of: #"^[ \t]*(>[ \t]?)+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return content }
        }
        return nil
    }

    /// Classifies an attribution link. Relative paths resolve against the
    /// note holding the quote, as every other link does.
    static func source(of destination: String, from note: URL?) -> Source {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(wikiScheme + ":"), let url = URL(string: trimmed), url.host() == "wiki" {
            let title = String(url.path(percentEncoded: false).dropFirst()).replacingOccurrences(of: "_", with: " ")
            guard !title.isEmpty else { return .unresolved }
            return .wikipedia(title: title, section: url.fragment(percentEncoded: false))
        }
        switch FileReference.target(trimmed, from: note) {
        case .file(let url, let anchor):
            return isMedia(url) ? .media(url) : .note(url, anchor: anchor)
        case .anchor(let anchor):
            return note.map { .note($0, anchor: anchor) } ?? .unresolved
        case .external(let url):
            return .web(url)
        case .unresolved:
            return .unresolved
        }
    }

    /// The SF Symbol for a source line, judged from the link alone so the
    /// highlighter needs no filesystem access.
    static func symbolName(for destination: String) -> String {
        let lower = destination.lowercased()
        if lower.hasPrefix(wikiScheme + ":") { return "book.closed" }
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") { return "globe" }
        let path = lower.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lower
        let file = URL(fileURLWithPath: path.removingPercentEncoding ?? path)
        if isVideo(file) { return "film" }
        if isMedia(file) { return "photo" }
        return "doc.text"
    }
}
