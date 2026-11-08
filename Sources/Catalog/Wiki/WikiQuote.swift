import SwiftUI
import AppKit

/// Embedded quotes from the Wikipedia reader: a block, a selection, a
/// section, or a figure, attributed to the article and its section anchor.
extension Article {

    /// A section heading: its anchor (the scroll target and link fragment),
    /// title and level.
    struct SectionHeading: Equatable {
        var anchor: String
        var title: String
        var level: Int
    }

    /// The section a block falls under; nil for the lead.
    func section(containing blockID: Int) -> SectionHeading? {
        var current: SectionHeading?
        for block in blocks {
            if case .heading(let level, let text, let anchor) = block.kind {
                if block.id > blockID { break }
                current = SectionHeading(anchor: anchor, title: text, level: level)
            } else if block.id >= blockID {
                break
            }
        }
        return current
    }

    /// Finds a section by anchor or title, as a person or link spells it
    /// ("Early history", "Early_history", "early-history").
    func section(named name: String) -> SectionHeading? {
        let wanted = FileReference.slug(name.replacingOccurrences(of: "_", with: " "))
        for block in blocks {
            guard case .heading(let level, let text, let anchor) = block.kind else { continue }
            if FileReference.slug(anchor.replacingOccurrences(of: "_", with: " ")) == wanted || FileReference.slug(text) == wanted {
                return SectionHeading(anchor: anchor, title: text, level: level)
            }
        }
        return nil
    }

    /// The blocks a section holds, subsections included; the lead (before
    /// the first heading) when `anchor` is nil.
    func blocks(inSection anchor: String?) -> [Block] {
        var result: [Block] = []
        var level: Int?
        var inside = anchor == nil
        for block in blocks {
            if case .heading(let headingLevel, _, let headingAnchor) = block.kind {
                if inside {
                    if anchor == nil || headingLevel <= (level ?? 0) { break }
                } else if headingAnchor == anchor {
                    inside = true
                    level = headingLevel
                    continue
                }
            }
            if inside { result.append(block) }
        }
        return result
    }

    private func quote(body: String, section: SectionHeading?, image: URL? = nil) -> EmbeddedQuote.Quote {
        EmbeddedQuote.Quote(kind: .wikipedia, body: body,
                            label: section.map { "\(title) § \($0.title)" } ?? title,
                            target: title, anchor: section?.anchor, image: image?.absoluteString)
    }

    /// One block (a paragraph, list or quotation), quoted whole.
    func quote(block id: Int) -> EmbeddedQuote.Quote? {
        guard let block = blocks.first(where: { $0.id == id }),
              let body = WikiMarkdown.markdown(of: block), !body.isEmpty else { return nil }
        return quote(body: body, section: section(containing: id))
    }

    /// A whole section, subsections included; the lead when `anchor` is nil.
    func quote(section anchor: String?) -> EmbeddedQuote.Quote? {
        let heading = anchor.flatMap { anchor in
            blocks.lazy.compactMap { block -> SectionHeading? in
                guard case .heading(let level, let text, let a) = block.kind, a == anchor else { return nil }
                return SectionHeading(anchor: a, title: text, level: level)
            }.first
        }
        guard anchor == nil || heading != nil else { return nil }
        let body = blocks(inSection: anchor).compactMap(WikiMarkdown.markdown(of:)).joined(separator: "\n\n")
        guard !body.isEmpty else { return nil }
        return quote(body: body, section: heading)
    }

    /// Selected text. `context` is the text of the view it was selected in
    /// (a paragraph, list item, or caption), which places it in a section.
    func quote(selection: String, context: String?) -> EmbeddedQuote.Quote? {
        let passage = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passage.isEmpty else { return nil }
        let normalized = WikiMarkdown.normalize(context ?? passage)
        let block = blocks.first { WikiMarkdown.normalize(WikiMarkdown.plainText(of: $0)).contains(normalized) }
        let section = block.flatMap { self.section(containing: $0.id) }
        // Paragraph breaks inside a selection stay paragraph breaks.
        let body = passage.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return quote(body: body, section: section)
    }

    /// A figure: its image above its caption, linked to its section.
    func quote(image: WikiImage, caption: AttributedString?, block id: Int?) -> EmbeddedQuote.Quote {
        let text = caption.map { WikiMarkdown.inline($0) } ?? ""
        // Without its block (the full-window viewer), find the figure.
        let id = id ?? blocks.first { block in
            switch block.kind {
            case .figure(let images, _): return images.contains { $0.url == image.url }
            case .map(let map, _): return map.image.url == image.url
            default: return false
            }
        }?.id
        return quote(body: text.isEmpty ? (image.file ?? title) : text,
                     section: id.flatMap { section(containing: $0) }, image: image.largeURL)
    }
}

/// Article blocks as Markdown for a quote: prose keeps its emphasis; links
/// and figures don't come along (the attribution links back instead).
enum WikiMarkdown {
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func plainText(of block: Block) -> String {
        switch block.kind {
        case .paragraph(let text), .quote(let text), .note(let text): return String(text.characters)
        case .list(let items): return items.map { String($0.text.characters) }.joined(separator: "\n")
        case .figure(_, let caption), .map(_, let caption): return caption.map { String($0.characters) } ?? ""
        case .heading(_, let text, _): return text
        default: return ""
        }
    }

    /// Bold and italic runs as `**…**` and `*…*`, with spaces kept outside
    /// the delimiters (where Markdown requires them).
    static func inline(_ text: AttributedString) -> String {
        var out = ""
        for run in text.runs {
            let raw = String(text[run.range].characters).replacingOccurrences(of: "\n", with: " ")
            let intent = run.inlinePresentationIntent ?? []
            var delimiter = ""
            if intent.contains(.stronglyEmphasized) { delimiter += "**" }
            if intent.contains(.emphasized) { delimiter += "*" }
            let core = raw.trimmingCharacters(in: .whitespaces)
            guard !delimiter.isEmpty, !core.isEmpty else { out += raw; continue }
            let leading = String(raw.prefix { $0 == " " }), trailing = String(raw.reversed().prefix { $0 == " " })
            out += leading + delimiter + core + delimiter + trailing
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// One block as quote Markdown; nil for blocks a quote leaves out
    /// (hatnotes, tables, figures, diagrams).
    static func markdown(of block: Block) -> String? {
        switch block.kind {
        case .paragraph(let text):
            return inline(text)
        case .quote(let text):
            return "> " + inline(text)
        case .list(let items):
            return items.map { item in
                let marker = item.marker.isEmpty || item.marker == "•" ? "-" : item.marker
                return String(repeating: "  ", count: item.level) + marker + " " + inline(item.text)
            }.joined(separator: "\n")
        case .heading(_, let text, _):
            // Headings can't render inside a quote's card.
            return "**\(text)**"
        case .math(let text):
            return text
        default:
            return nil
        }
    }
}

extension WikiPage {
    /// Copies a quote of the selection, or else of the section being read.
    /// Returns false when there is no article to quote.
    func copyQuote(selection: (text: String, block: String)?) -> Bool {
        guard let article else { return false }
        let quote = selection.flatMap { article.quote(selection: $0.text, context: $0.block) }
            ?? article.quote(section: readingSection(in: article)?.anchor)
        return copy(quote)
    }

    func copyQuote(block id: Int) { _ = copy(article?.quote(block: id)) }

    func copyQuote(section anchor: String?) { _ = copy(article?.quote(section: anchor)) }

    func copyQuote(image: WikiImage, caption: AttributedString?, block id: Int?) {
        _ = copy(article?.quote(image: image, caption: caption, block: id))
    }

    /// The section of the topmost block on screen.
    func readingSection(in article: Article) -> Article.SectionHeading? {
        guard let route, let top = visibleBlocks[route.id]?.min() else { return nil }
        return article.section(containing: top)
    }

    /// Tracks which blocks are on screen, for ⇧⌘C without a selection.
    func blockVisibility(_ id: Int, visible: Bool, route: UUID) {
        if visible { visibleBlocks[route, default: []].insert(id) } else { visibleBlocks[route]?.remove(id) }
    }

    private func copy(_ quote: EmbeddedQuote.Quote?) -> Bool {
        guard let quote else { NSSound.beep(); return false }
        EmbeddedQuote.write(quote, to: .general)
        onQuoteCopied?()
        return true
    }
}

/// Right-click actions for an article image: the picture itself, its
/// address, a quote of the figure, or the browser.
struct WikiImageMenu: View {
    let image: WikiImage
    let caption: AttributedString?
    @Environment(WikiPage.self) private var page: WikiPage?
    @Environment(\.wikiBlockID) private var blockID

    var body: some View {
        Button("Copy Image") { ImageClipboard.copy(remote: image.largeURL, session: WikipediaClient.session) }
        Button("Copy Image Address") { ImageClipboard.copyAddress(image.largeURL) }
        if page?.article != nil {
            Button("Copy as Embedded Quote") { page?.copyQuote(image: image, caption: caption, block: blockID) }
        }
        Divider()
        Button("Open Image in Browser") { NSWorkspace.shared.open(image.largeURL) }
    }
}

extension EnvironmentValues {
    /// The article block a view belongs to, so an image inside it can be
    /// quoted with its section.
    @Entry var wikiBlockID: Int? = nil
}
