import SwiftUI

/// Links inside article text use this scheme so taps stay in the app.
enum WikiLink {
    static let scheme = "encyclopedia"

    static func url(title: String, fragment: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "wiki"
        components.path = "/" + title
        components.fragment = fragment
        return components.url
    }

    /// The article title and section anchor an in-app link points at.
    static func destination(of url: URL) -> (title: String, fragment: String?)? {
        guard url.scheme == scheme, url.host() == "wiki" else { return nil }
        let title = String(url.path(percentEncoded: false).dropFirst()).replacingOccurrences(of: "_", with: " ")
        guard !title.isEmpty else { return nil }
        return (title, url.fragment(percentEncoded: false))
    }

    private static let externalNamespaces: Set<String> = [
        "category", "help", "wikipedia", "wp", "template", "template talk", "special", "portal", "talk", "user",
        "user talk", "draft", "module", "mediawiki", "book", "timedtext", "wikipedia talk", "file talk",
    ]
    private static let mediaNamespaces: Set<String> = ["file", "image", "media"]

    /// Resolves an `href` from Wikipedia's HTML; nil means render as plain text.
    static func resolve(href: String, isRedLink: Bool) -> URL? {
        if isRedLink || href.hasPrefix("#") { return nil }
        if href.hasPrefix("/wiki/") {
            let target = String(href.dropFirst("/wiki/".count))
            let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let rawTitle = parts.first.map(String.init) ?? ""
            let title = (rawTitle.removingPercentEncoding ?? rawTitle).replacingOccurrences(of: "_", with: " ")
            let fragment = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : nil
            if let colon = title.firstIndex(of: ":") {
                let namespace = title[..<colon].lowercased()
                if mediaNamespaces.contains(namespace) { return nil }
                if externalNamespaces.contains(namespace) { return URL(string: "https://en.wikipedia.org" + href) }
            }
            return url(title: title, fragment: fragment)
        }
        if href.hasPrefix("//") { return URL(string: "https:" + href) }
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return URL(string: href) }
        if href.hasPrefix("/w/") { return URL(string: "https://en.wikipedia.org" + href) }
        return nil
    }
}

struct InlineStyle {
    var bold = false
    var italic = false
    var code = false
    var isSuperscript = false
    var isSubscript = false
    var strike = false
    var link: URL?
}

/// Accumulates inline HTML into one AttributedString, collapsing whitespace
/// the way a browser would.
struct InlineBuilder {
    private(set) var output = AttributedString()
    private var lastWasSpace = true
    private var isEmpty = true

    var hasContent: Bool { !isEmpty }

    mutating func appendText(_ raw: String, style: InlineStyle) {
        var text = ""
        text.reserveCapacity(raw.count)
        for ch in raw {
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                if !lastWasSpace { text.append(" "); lastWasSpace = true }
            } else {
                text.append(ch)
                lastWasSpace = false
            }
        }
        guard !text.isEmpty else { return }
        appendStyled(text, style: style)
    }

    /// Appends text verbatim (already formatted), e.g. math.
    mutating func appendLiteral(_ text: String, style: InlineStyle) {
        guard !text.isEmpty else { return }
        appendStyled(text, style: style)
        lastWasSpace = text.last == " "
    }

    private mutating func appendStyled(_ text: String, style: InlineStyle) {
        var content = text
        var container = AttributeContainer()
        var intent: InlinePresentationIntent = []
        if style.bold { intent.insert(.stronglyEmphasized); container.foregroundColor = WikiTheme.bold }
        if style.italic { intent.insert(.emphasized); if !style.bold { container.foregroundColor = WikiTheme.italic } }
        if style.code { intent.insert(.code); container.foregroundColor = WikiTheme.inlineCode }
        if style.strike { intent.insert(.strikethrough) }
        if !intent.isEmpty { container.inlinePresentationIntent = intent }
        if style.isSuperscript || style.isSubscript {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if let mapped = style.isSuperscript ? MathText.superscripted(trimmed) : MathText.subscripted(trimmed) {
                content = mapped
            } else {
                container.baselineOffset = style.isSuperscript ? 5 : -3
            }
        }
        if let link = style.link {
            container.link = link
            container.underlineStyle = Text.LineStyle(pattern: .solid, color: WikiTheme.link.opacity(0.25))
        }
        output.append(AttributedString(content, attributes: container))
        isEmpty = false
    }

    mutating func lineBreak() {
        trimTrailingSpaces()
        output.append(AttributedString("\n"))
        lastWasSpace = true
    }

    /// Starts a new line unless already at the start of one.
    mutating func blockBreak() {
        guard !isEmpty else { return }
        trimTrailingSpaces()
        if output.characters.last != "\n" { output.append(AttributedString("\n")) }
        lastWasSpace = true
    }

    private mutating func trimTrailingSpaces() {
        while let last = output.characters.last, last == " " { output.characters.removeLast() }
    }

    func result() -> AttributedString {
        var out = output
        while let first = out.characters.first, first.isWhitespace { out.characters.removeFirst() }
        while let last = out.characters.last, last.isWhitespace { out.characters.removeLast() }
        return out
    }

    // MARK: HTML

    mutating func inlineChildren(of node: HTMLNode, style: InlineStyle = InlineStyle()) {
        for child in node.children { inline(child, style: style) }
    }

    mutating func inline(_ node: HTMLNode, style: InlineStyle) {
        if node.isText { appendText(node.text, style: style); return }
        if ArticleBuilder.shouldSkip(node) { return }
        var style = style
        switch node.tag {
        case "b", "strong":
            style.bold = true
        case "i", "em", "cite", "var", "dfn":
            style.italic = true
        case "code", "kbd", "samp", "tt":
            style.code = true
        case "sup":
            style.isSuperscript = true
        case "sub":
            style.isSubscript = true
        case "s", "del", "strike":
            style.strike = true
        case "br":
            lineBreak()
            return
        case "a":
            if let href = node["href"] {
                style.link = WikiLink.resolve(href: href, isRedLink: node.hasClass("new")) ?? style.link
            }
        case "img":
            if node.classContains("mwe-math-fallback") {
                appendLiteral(MathText.readable(MathText.latex(from: node)), style: mathStyle(style))
            }
            return
        case "span" where node.hasClass("mwe-math-element"):
            appendLiteral(MathText.readable(MathText.latex(from: node)), style: mathStyle(style))
            return
        case "figure", "audio", "video":
            return
        case "table" where node.classContains("infobox"):
            return
        case "p", "div", "li", "dd", "dt", "tr", "blockquote", "ul", "ol", "dl", "table", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "caption":
            blockBreak()
            inlineChildren(of: node, style: style)
            blockBreak()
            return
        case "td", "th":
            inlineChildren(of: node, style: style)
            appendText(" ", style: style)
            return
        default:
            break
        }
        inlineChildren(of: node, style: style)
    }

    private func mathStyle(_ style: InlineStyle) -> InlineStyle {
        var math = style
        math.italic = false
        math.bold = false
        return math
    }
}

/// Converts MediaWiki parser output into native blocks.
final class ArticleBuilder {
    private(set) var blocks: [Block] = []
    private(set) var infobox: [InfoRow] = []
    private(set) var infoboxImage: WikiImage?
    /// The infobox's own title, usually the subject's name.
    private(set) var infoboxTitle: String?
    private var nextID = 0
    private var skippingBelowLevel: Int?
    private var pending = InlineBuilder()

    private static let droppedSections: Set<String> = [
        "references", "notes", "citations", "footnotes", "sources", "notes and references", "references and notes",
        "explanatory notes", "works cited", "further reading", "cited sources", "general and cited sources",
        "general sources", "specific sources", "bibliography and references", "notes and citations",
        "citations and notes", "endnotes", "source notes", "content notes",
    ]

    private static let skipClasses: Set<Substring> = [
        "mw-editsection", "navbox", "navbox-styles", "vertical-navbox", "sidebar", "metadata", "ambox",
        "mbox-small", "mbox-small-left", "noprint", "portal", "portalbox", "portal-bar", "sistersitebox",
        "side-box", "mw-empty-elt", "shortdescription", "reflist", "refbegin", "mw-references-wrap",
        "references", "mw-cite-backlink", "reference", "catlinks", "printfooter", "authority-control",
        "toc", "mw-jump-link", "navigation-only", "geo-inline-hidden", "mwe-math-mathml-a11y",
        "mw-ext-cite-error", "box-More_citations_needed", "cs1-maint", "plainlist-hidden", "sisterproject",
        "wikitable-hidden", "hidden-begin", "hidden-end", "infobox-navbar", "navbar", "tmbox", "ombox", "cmbox",
        "fmbox", "imbox", "dmbox", "stub", "asbox", "mw-indicators", "coordinates", "hlist-separated-hidden", "searchaux",
    ]

    private static let skipTags: Set<String> = ["style", "script", "link", "meta", "math", "noscript", "audio", "video", "input", "button"]

    static func shouldSkip(_ node: HTMLNode) -> Bool {
        if skipTags.contains(node.tag) { return true }
        if node.hasAnyClass(skipClasses) { return true }
        if node.isHidden || node.isAbsolutelyPositioned { return true }
        if node["role"] == "navigation" { return true }
        return false
    }

    // MARK: Entry point

    func build(_ root: HTMLNode) {
        let content = root.first(where: { $0.hasClass("mw-parser-output") }) ?? root
        walk(content)
        flushPending()
    }

    private func append(_ kind: BlockKind) {
        blocks.append(Block(id: nextID, kind: kind))
        nextID += 1
    }

    private func flushPending() {
        let text = pending.result()
        pending = InlineBuilder()
        if !text.characters.isEmpty { append(.paragraph(text)) }
    }

    private func headingLevel(_ node: HTMLNode) -> (Int, HTMLNode)? {
        if node.tag.count == 2, node.tag.first == "h", let level = Int(node.tag.dropFirst()) { return (level, node) }
        if node.tag == "div", node.hasClass("mw-heading"),
           let heading = node.children.first(where: { $0.tag.count == 2 && $0.tag.first == "h" && Int($0.tag.dropFirst()) != nil }),
           let level = Int(heading.tag.dropFirst()) {
            return (level, heading)
        }
        return nil
    }

    private func walk(_ node: HTMLNode) {
        for child in node.children {
            if child.isText {
                if skippingBelowLevel == nil { pending.appendText(child.text, style: InlineStyle()) }
                continue
            }
            // Marked as search-only and hidden on mobile, but it's a real figure.
            if Self.isGraphicalTimeline(child) {
                if skippingBelowLevel == nil, let timeline = Self.graphicalTimeline(child) {
                    flushPending()
                    append(.timeline(timeline))
                }
                continue
            }
            if Self.shouldSkip(child) { continue }
            if let (level, heading) = headingLevel(child) {
                flushPending()
                handleHeading(heading, level: level)
                continue
            }
            if skippingBelowLevel != nil {
                // Headings can sit inside sections; keep looking for the next one.
                if child.tag == "section" { walk(child) }
                continue
            }
            switch child.tag {
            case "p":
                flushPending()
                paragraph(child)
            case "ul", "ol":
                flushPending()
                if child.hasClass("gallery") { gallery(child) } else { list(child) }
            case "dl":
                flushPending()
                definitionList(child)
            case "blockquote":
                flushPending()
                quote(child)
            case "figure":
                flushPending()
                figure(child)
            case "table":
                flushPending()
                table(child)
            case "pre":
                flushPending()
                let text = child.textContent.trimmingCharacters(in: .newlines)
                if !text.isEmpty { append(.preformatted(text)) }
            case "hr":
                flushPending()
            case "div", "section", "center", "main", "article", "aside":
                flushPending()
                container(child)
            case "span" where isBlockSpan(child):
                flushPending()
                container(child)
            default:
                pending.inline(child, style: InlineStyle())
            }
        }
    }

    private func isBlockSpan(_ node: HTMLNode) -> Bool {
        if node.hasClass("mwe-math-element-block") { return true }
        if let type = node["typeof"], type.hasPrefix("mw:File") { return true }
        return false
    }

    private func container(_ node: HTMLNode) {
        if node.hasClass("clade") {
            if let tree = Self.cladogram(node) { append(.cladogram(tree)) }
        } else if node.hasClass("locmap") {
            if let (map, caption) = Self.locationMap(node) { append(.map(map, caption: caption)) }
        } else if node.hasClass("timeline-wrapper") {
            // EasyTimeline: a rendered image.
            figure(node)
        } else if node.hasClass("mwe-math-element") {
            append(.math(MathText.readable(MathText.latex(from: node))))
        } else if node.tag == "span" {
            figure(node)
        } else if node.hasClass("hatnote") || node["role"] == "note" {
            var builder = InlineBuilder()
            builder.inlineChildren(of: node)
            let text = builder.result()
            if !text.characters.isEmpty { append(.note(text)) }
        } else if node.hasClass("thumb") || node.hasClass("tmulti") {
            figure(node)
        } else if node.hasClass("gallery") || node.hasClass("mod-gallery") {
            gallery(node)
        } else if node.hasClass("quotebox") || node.hasClass("templatequote") || node.classContains("quote") && node.hasClass("pullquote") {
            quote(node)
        } else {
            walk(node)
        }
    }

    private func handleHeading(_ heading: HTMLNode, level: Int) {
        let title = heading.textContent
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let skipLevel = skippingBelowLevel {
            if level > skipLevel { return }
            skippingBelowLevel = nil
        }
        if Self.droppedSections.contains(title.lowercased()) {
            skippingBelowLevel = level
            return
        }
        guard !title.isEmpty else { return }
        let anchor = heading["id"] ?? title.replacingOccurrences(of: " ", with: "_")
        append(.heading(level: level, text: title, anchor: anchor))
    }

    private func paragraph(_ node: HTMLNode) {
        // A paragraph that only wraps display math becomes a math block.
        if let math = soleDisplayMath(node) { append(.math(math)); return }
        var builder = InlineBuilder()
        builder.inlineChildren(of: node)
        let text = builder.result()
        if !text.characters.isEmpty { append(.paragraph(text)) }
    }

    private func soleDisplayMath(_ node: HTMLNode) -> String? {
        var math: [String] = []
        var trailing = ""
        for child in node.children {
            if child.isText {
                let text = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                guard text.allSatisfy({ $0.isPunctuation }) else { return nil }
                trailing += text
            } else if child.hasClass("mwe-math-element") {
                math.append(MathText.readable(MathText.latex(from: child)))
            } else if !Self.shouldSkip(child) {
                return nil
            }
        }
        guard !math.isEmpty, node.first(where: { $0.hasClass("mwe-math-element-block") || $0.classContains("fallback-image-display") }) != nil || node.tag == "dd" else { return nil }
        return math.joined(separator: "  ") + trailing
    }

    // MARK: Lists

    private func list(_ node: HTMLNode) {
        var items: [ListItem] = []
        collectItems(node, level: 0, into: &items)
        if !items.isEmpty { append(.list(items)) }
    }

    private func collectItems(_ node: HTMLNode, level: Int, into items: inout [ListItem]) {
        let ordered = node.tag == "ol"
        var number = Int(node["start"] ?? "") ?? 1
        for li in node.children where li.tag == "li" {
            if Self.shouldSkip(li) { continue }
            var builder = InlineBuilder()
            var nested: [HTMLNode] = []
            for child in li.children {
                if child.tag == "ul" || child.tag == "ol" || child.tag == "dl" {
                    nested.append(child)
                } else {
                    builder.inline(child, style: InlineStyle())
                }
            }
            let text = builder.result()
            if !text.characters.isEmpty {
                let marker = ordered ? "\(number)." : ["•", "◦", "▪︎"][min(level, 2)]
                items.append(ListItem(id: items.count, level: level, marker: marker, text: text))
            }
            number += 1
            for sub in nested where !Self.shouldSkip(sub) {
                if sub.tag == "dl" {
                    for entry in sub.children where entry.tag == "dt" || entry.tag == "dd" {
                        var b = InlineBuilder()
                        b.inlineChildren(of: entry, style: InlineStyle(bold: entry.tag == "dt"))
                        let t = b.result()
                        if !t.characters.isEmpty { items.append(ListItem(id: items.count, level: level + 1, marker: "", text: t)) }
                    }
                } else {
                    collectItems(sub, level: level + 1, into: &items)
                }
            }
        }
    }

    private func definitionList(_ node: HTMLNode) {
        var items: [ListItem] = []
        func flushItems() {
            if !items.isEmpty { append(.list(items)); items = [] }
        }
        for entry in node.children where !entry.isText && !Self.shouldSkip(entry) {
            if entry.tag == "dd", let math = soleDisplayMath(entry) {
                flushItems()
                append(.math(math))
                continue
            }
            if entry.tag == "dd", entry.children.contains(where: { $0.tag == "dl" || $0.tag == "ul" || $0.tag == "ol" || $0.tag == "table" || $0.tag == "figure" }) {
                flushItems()
                walk(entry)
                continue
            }
            guard entry.tag == "dt" || entry.tag == "dd" else { continue }
            var builder = InlineBuilder()
            builder.inlineChildren(of: entry, style: InlineStyle(bold: entry.tag == "dt"))
            let text = builder.result()
            if !text.characters.isEmpty {
                items.append(ListItem(id: items.count, level: entry.tag == "dt" ? 0 : 1, marker: "", text: text))
            }
        }
        flushItems()
    }

    private func quote(_ node: HTMLNode) {
        var builder = InlineBuilder()
        builder.inlineChildren(of: node)
        let text = builder.result()
        if !text.characters.isEmpty { append(.quote(text)) }
    }

    // MARK: Media

    static func image(from img: HTMLNode) -> WikiImage? {
        guard var source = img["src"], !source.isEmpty else { return nil }
        if let srcset = img["srcset"] {
            // "url 1.5x, url 2x" — prefer the sharpest candidate.
            let candidates = srcset.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let best = candidates.last?.split(separator: " ").first { source = String(best) }
        }
        if source.hasPrefix("//") { source = "https:" + source }
        guard let url = URL(string: source) else { return nil }
        let width = Double(img["width"] ?? "") ?? 0
        let height = Double(img["height"] ?? "") ?? 0
        var file: String?
        var node: HTMLNode? = img
        while let current = node, file == nil {
            if current.tag == "a", let href = current["href"], href.hasPrefix("/wiki/") {
                file = (String(href.dropFirst(6)).removingPercentEncoding ?? String(href.dropFirst(6)))
                    .replacingOccurrences(of: "_", with: " ")
            }
            node = current.parent
            if current.tag == "figure" || current.hasClass("thumb") { break }
        }
        return WikiImage(url: url, width: width, height: height, file: file, originalWidth: Double(img["data-file-width"] ?? ""))
    }

    private func images(in node: HTMLNode) -> [WikiImage] {
        node.all { candidate in
            guard candidate.tag == "img", !candidate.classContains("mwe-math") else { return false }
            let width = Double(candidate["width"] ?? "") ?? 100
            guard width >= 60 else { return false }
            return !candidate.isInside { $0.tag == "figcaption" || $0.hasClass("thumbcaption") || $0.hasClass("gallerytext") }
        }
        .compactMap(Self.image(from:))
    }

    private func figure(_ node: HTMLNode) {
        let found = images(in: node)
        guard !found.isEmpty else { return }
        var caption: AttributedString?
        let captionNode = node.first(where: { $0.tag == "figcaption" })
            ?? node.all(where: { $0.hasClass("thumbcaption") }).last
        if let captionNode {
            var builder = InlineBuilder()
            builder.inlineChildren(of: captionNode)
            let text = builder.result()
            if !text.characters.isEmpty { caption = text }
        }
        append(.figure(found, caption: caption))
    }

    private func gallery(_ node: HTMLNode) {
        let found = images(in: node)
        guard !found.isEmpty else { return }
        append(.figure(found, caption: nil))
    }

    // MARK: Tables

    static func rows(of table: HTMLNode) -> [HTMLNode] {
        var rows: [HTMLNode] = []
        for child in table.children {
            if child.tag == "tr" { rows.append(child) }
            else if child.tag == "thead" || child.tag == "tbody" || child.tag == "tfoot" {
                rows.append(contentsOf: child.children.filter { $0.tag == "tr" })
            }
        }
        return rows
    }

    private func table(_ node: HTMLNode) {
        if node.classContains("infobox") {
            if infobox.isEmpty { parseInfobox(node) }
            return
        }
        if node.hasClass("clade") {
            if let tree = Self.cladogram(node) { append(.cladogram(tree)) }
            return
        }
        // Graphical timelines and charts are drawn with positioned boxes.
        if node.first(where: { $0.isAbsolutelyPositioned }) != nil { return }
        let rows = Self.rows(of: node)
        let hasHeaders = rows.contains { $0.children.contains { $0.tag == "th" } }
        if node.hasClass("wikitable") || hasHeaders {
            if let data = tableData(node, rows: rows) { append(.table(data)) }
            return
        }
        // Layout tables: render what's inside each cell.
        for row in rows {
            for cell in row.children where cell.tag == "td" { walk(cell) }
        }
    }

    private func tableData(_ node: HTMLNode, rows: [HTMLNode]) -> TableData? {
        var output: [[TableCell]] = []
        var spans: [Int: Int] = [:]
        let empty = TableCell(text: AttributedString(), isHeader: false)
        for row in rows.prefix(300) where !Self.shouldSkip(row) {
            var cells: [TableCell] = []
            var column = 0
            func fillSpans() {
                while let remaining = spans[column], remaining > 0 {
                    cells.append(empty)
                    spans[column] = remaining - 1
                    column += 1
                }
            }
            for cell in row.children where cell.tag == "td" || cell.tag == "th" {
                if Self.shouldSkip(cell) { continue }
                fillSpans()
                var builder = InlineBuilder()
                builder.inlineChildren(of: cell, style: InlineStyle(bold: cell.tag == "th"))
                cells.append(TableCell(text: builder.result(), isHeader: cell.tag == "th"))
                let colspan = min(max(Int(cell["colspan"] ?? "") ?? 1, 1), 20)
                let rowspan = min(max(Int(cell["rowspan"] ?? "") ?? 1, 1), 300)
                for offset in 0..<colspan {
                    if offset > 0 { cells.append(empty) }
                    if rowspan > 1 { spans[column] = rowspan - 1 }
                    column += 1
                }
            }
            fillSpans()
            if cells.contains(where: { !$0.text.characters.isEmpty }) { output.append(cells) }
        }
        guard !output.isEmpty else { return nil }
        var caption: AttributedString?
        if let captionNode = node.children.first(where: { $0.tag == "caption" }) {
            var builder = InlineBuilder()
            builder.inlineChildren(of: captionNode)
            let text = builder.result()
            if !text.characters.isEmpty { caption = text }
        }
        return TableData(caption: caption, rows: output)
    }

    // MARK: Infobox

    private func parseInfobox(_ table: HTMLNode) {
        for row in Self.rows(of: table) where !Self.shouldSkip(row) {
            let cells = row.children.filter { ($0.tag == "th" || $0.tag == "td") && !Self.shouldSkip($0) }
            guard !cells.isEmpty else { continue }
            if let above = cells.first(where: { $0.hasClass("infobox-above") || $0.hasClass("infobox-title") }) {
                if infoboxTitle == nil { infoboxTitle = collapsed(above.textContent) }
                continue
            }
            if cells.contains(where: { $0.hasClass("infobox-below") }) { continue }
            if let imageCell = cells.first(where: { $0.hasClass("infobox-image") }) {
                infoboxImageRow(imageCell)
                continue
            }
            if let nested = cells.first(where: { $0.first(where: { $0.tag == "table" }) != nil && $0.hasClass("infobox-full-data") }),
               nested.first(where: { $0.tag == "table" && $0.classContains("infobox") }) != nil {
                for table in nested.all(where: { $0.tag == "table" }) where table.classContains("infobox") {
                    parseInfobox(table)
                }
                continue
            }
            if cells.count == 1 {
                infoboxCell(cells[0])
                continue
            }
            let labelCell = cells.first(where: { $0.tag == "th" }) ?? cells[0]
            guard let valueCell = cells.first(where: { $0 !== labelCell && $0.tag == "td" }) else { continue }
            let label = collapsed(labelCell.textContent)
            if !label.isEmpty, let value = Self.inlineText(of: valueCell) {
                infobox.append(.pair(label: label, value: value))
            }
        }
        // Drop headers with nothing beneath them.
        var cleaned: [InfoRow] = []
        for row in infobox.reversed() {
            if case .header = row {
                guard let next = cleaned.last else { continue }
                if case .header = next { continue }
            }
            cleaned.append(row)
        }
        infobox = cleaned.reversed()
    }

    /// A row spanning the whole infobox.
    private func infoboxCell(_ cell: HTMLNode) {
        if let container = cell.first(where: Self.isGraphicalTimeline) {
            if let timeline = Self.graphicalTimeline(container) { infobox.append(.timeline(timeline)) }
            return
        }
        if cell.tag == "th" {
            // Taxoboxes put the name, temporal range and its bar in one header.
            guard var text = Self.inlineText(of: cell) else { return }
            var rest: AttributedString?
            if let newline = text.characters.firstIndex(of: "\n") {
                var remainder = AttributedString(text[text.characters.index(after: newline)...])
                text = AttributedString(text[..<newline])
                while let range = remainder.range(of: "\n") { remainder.replaceSubrange(range, with: AttributedString(" ")) }
                while let last = remainder.characters.last, last == "," || last == " " || last == ";" { remainder.characters.removeLast() }
                if !remainder.characters.isEmpty { rest = remainder }
            }
            let title = collapsed(String(text.characters))
            if !title.isEmpty { infobox.append(.header(title)) }
            if let rest { infobox.append(.subheader(rest)) }
            if let range = Self.geologicRange(in: cell) { infobox.append(.range(range)) }
            return
        }
        if let range = Self.geologicRange(in: cell) {
            if let text = Self.inlineText(of: cell) { infobox.append(.subheader(text)) }
            infobox.append(.range(range))
        } else if let succession = succession(in: cell) {
            infobox.append(succession)
        } else if let locmap = cell.first(where: { $0.hasClass("locmap") }), let (map, caption) = Self.locationMap(locmap) {
            infobox.append(.map(map, caption: caption))
        } else if cell.first(where: { $0.tag == "img" && (Double($0["width"] ?? "") ?? 0) >= 40 }) != nil {
            infoboxImageRow(cell)
        } else if let text = Self.inlineText(of: cell) {
            // Taxoboxes caption an image in the row below it.
            let style = CSSStyle(cell["style"])
            if case .image(let images, nil)? = infobox.last, style["text-align"] == "center" || style["font-size"] != nil {
                infobox[infobox.count - 1] = .image(images, caption: text)
            } else {
                infobox.append(cell.hasClass("infobox-subheader") ? .subheader(text) : .text(text))
            }
        }
    }

    private func infoboxImageRow(_ cell: HTMLNode) {
        let found = cell.all { $0.tag == "img" && (Double($0["width"] ?? "") ?? 0) >= 40 && !$0.classContains("mwe-math") }
            .compactMap(Self.image(from:))
        guard !found.isEmpty else { return }
        if infoboxImage == nil { infoboxImage = found[0] }
        infobox.append(.image(found, caption: Self.inlineText(of: cell)))
    }

    /// Period and office infoboxes show their neighbors in a two- or
    /// three-cell table with arrows: "← Pliocene | Bronze Age →".
    private func succession(in cell: HTMLNode) -> InfoRow? {
        guard let table = cell.first(where: { $0.tag == "table" }),
              let row = Self.rows(of: table).first else { return nil }
        let parts = row.children.filter { $0.tag == "td" || $0.tag == "th" }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let hasArrows = table.first(where: { node in
            guard node.tag == "img" else { return false }
            let source = (node["src"] ?? "").lowercased()
            return source.contains("arrleft") || source.contains("arrright") || source.contains("arrow")
        }) != nil || ["←", "→", "◄", "►"].contains { arrow in parts.contains { $0.textContent.contains(arrow) } }
        guard hasArrows else { return nil }
        func text(_ node: HTMLNode) -> AttributedString? {
            guard var text = Self.inlineText(of: node) else { return nil }
            for arrow in ["←", "→", "◄", "►"] {
                while let range = text.range(of: arrow) { text.removeSubrange(range) }
            }
            let trimmed = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        let current = parts.count == 3 ? text(parts[1]).map { collapsed(String($0.characters)) } : infoboxTitle
        return .succession(previous: text(parts[0]), current: current, next: text(parts[parts.count - 1]))
    }

    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Finishing

    /// Removes the lead image from body figures (keeping its caption) and
    /// drops empty sections.
    func finish(leadImageFile: String?) -> (blocks: [Block], sections: [ArticleSection], leadCaption: AttributedString?) {
        var result: [Block] = []
        var leadCaption: AttributedString?
        for block in blocks {
            if case .figure(let images, let caption) = block.kind, let leadImageFile {
                let remaining = images.filter { $0.file != leadImageFile }
                if remaining.isEmpty {
                    if leadCaption == nil, images.count == 1 { leadCaption = caption }
                    continue
                }
                result.append(Block(id: block.id, kind: .figure(remaining, caption: caption)))
            } else {
                result.append(block)
            }
        }
        var kept: [Block] = []
        for block in result.reversed() {
            if case .heading(let level, _, _) = block.kind {
                guard let next = kept.last else { continue }
                if case .heading(let nextLevel, _, _) = next.kind, nextLevel <= level { continue }
            }
            kept.append(block)
        }
        let blocks = Array(kept.reversed())
        let sections = blocks.compactMap { block -> ArticleSection? in
            guard case .heading(let level, let text, let anchor) = block.kind, level <= 3 else { return nil }
            return ArticleSection(id: anchor, title: text, level: level)
        }
        return (blocks, sections, leadCaption)
    }

    private static func outline(_ node: CladeNode, depth: Int) -> String {
        var out = ""
        for child in node.children {
            let name = [child.label, child.text].compactMap { $0.map { String($0.characters) } }.joined(separator: ": ")
            out += String(repeating: "  ", count: depth) + "- " + (name.isEmpty ? "(clade)" : name.replacingOccurrences(of: "\n", with: " ")) + "\n"
            out += outline(child, depth: depth + 1)
        }
        return out
    }

    static func plainText(title: String, summary: String?, infobox: [InfoRow], blocks: [Block]) -> String {
        var out = "# \(title)\n"
        if let summary { out += "\(summary)\n" }
        if !infobox.isEmpty {
            out += "\n## Infobox\n"
            for row in infobox {
                switch row {
                case .header(let text): out += "\n\(text)\n"
                case .pair(let label, let value): out += "- \(label): \(String(value.characters).replacingOccurrences(of: "\n", with: "; "))\n"
                case .text(let value), .subheader(let value): out += "\(String(value.characters))\n"
                case .succession(let previous, let current, let next):
                    let parts = [previous.map { "Preceded by " + String($0.characters) }, current, next.map { "followed by " + String($0.characters) }]
                    out += parts.compactMap { $0?.replacingOccurrences(of: "\n", with: ", ") }.joined(separator: "; ") + "\n"
                case .image(_, let caption), .map(_, let caption):
                    if let caption { out += "[Image: \(String(caption.characters))]\n" }
                case .range(let range):
                    if let text = range.text { out += "Temporal range: \(String(text.characters))\n" }
                case .timeline(let timeline):
                    out += "Timeline: " + timeline.bars.map { String($0.label.characters) }.filter { !$0.isEmpty }.joined(separator: ", ") + "\n"
                }
            }
        }
        out += "\n"
        for block in blocks {
            switch block.kind {
            case .heading(let level, let text, _):
                out += "\n" + String(repeating: "#", count: min(level, 6)) + " \(text)\n\n"
            case .paragraph(let text):
                out += String(text.characters) + "\n\n"
            case .note(let text):
                out += "(\(String(text.characters)))\n\n"
            case .list(let items):
                for item in items {
                    out += String(repeating: "  ", count: item.level) + (item.marker.isEmpty ? "" : item.marker + " ") + String(item.text.characters) + "\n"
                }
                out += "\n"
            case .quote(let text):
                out += "> " + String(text.characters).replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
            case .figure(_, let caption):
                if let caption { out += "[Image: \(String(caption.characters))]\n\n" }
            case .table(let table):
                if let caption = table.caption { out += "Table: \(String(caption.characters))\n" }
                for row in table.rows {
                    out += "| " + row.map { String($0.text.characters).replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n"
                }
                out += "\n"
            case .math(let text), .preformatted(let text):
                out += text + "\n\n"
            case .timeline(let timeline):
                out += "Timeline: \(timeline.title.map { String($0.characters) } ?? "")\n"
                for bar in timeline.bars.sorted(by: { $0.top > $1.top }) where !bar.label.characters.isEmpty {
                    out += "- \(String(bar.label.characters).replacingOccurrences(of: "\n", with: " "))\n"
                }
                out += "\n"
            case .cladogram(let root):
                out += "Cladogram:\n" + Self.outline(root, depth: 0) + "\n"
            case .map(_, let caption):
                if let caption { out += "[Map: \(String(caption.characters))]\n\n" }
            }
        }
        return out
    }
}
