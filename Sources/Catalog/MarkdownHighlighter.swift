import AppKit
import CoreText

extension NSAttributedString.Key {
    /// A Markdown link destination (`](here)`), verbatim from the source.
    static let fileReference = NSAttributedString.Key("WriteFileReference")
    /// The target of an Obsidian-style `[[wiki link]]` — a note name or a
    /// workspace path, never a URL. Resolved against the workspace index.
    static let wikiReference = NSAttributedString.Key("WriteWikiReference")
}

/// Pads code background rects: block bands stretch back to the margin (the
/// text indent becomes interior padding) and inline chips get a little air
/// around the glyphs.
final class CodeBackgroundLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count rectCount: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        var rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
        if color === Theme.codeBlockBackground {
            for i in rects.indices {
                rects[i].origin.x -= Theme.codeBlockPadding
                rects[i].size.width += Theme.codeBlockPadding
                // Overlap adjacent fill groups a hair so no seam shows
                // between the fence row and the content rows.
                rects[i] = rects[i].insetBy(dx: 0, dy: -0.5)
            }
        } else if color === Theme.codeBackground {
            for i in rects.indices {
                rects[i] = rects[i].insetBy(dx: -3, dy: 0)
            }
        }
        rects.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: rectCount,
                                          forCharacterRange: charRange, color: color)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(.mdImage, in: charRange) { value, range, _ in
            guard let embed = value as? ImageEmbed else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }
            let fragment = self.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            var size = embed.size
            let maxWidth = fragment.width - 8
            if size.width > maxWidth, maxWidth > 20 {
                let scale = maxWidth / size.width
                size = NSSize(width: maxWidth, height: size.height * scale)
            }
            let drawRect = NSRect(
                x: fragment.minX + origin.x,
                y: fragment.minY + origin.y + (fragment.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: drawRect,
                         xRadius: Theme.imageCornerRadius,
                         yRadius: Theme.imageCornerRadius).addClip()
            embed.image.draw(in: drawRect, from: .zero, operation: .sourceOver,
                             fraction: 1.0, respectFlipped: true,
                             hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}

extension NSAttributedString.Key {
    /// Marks markdown syntax characters (##, **, backticks, link urls…).
    /// The editor hides these glyphs unless the caret is on their paragraph.
    static let mdMarker = NSAttributedString.Key("mdMarker")
    /// Carries an ImageEmbed for image syntax; drawn by the layout manager.
    static let mdImage = NSAttributedString.Key("mdImage")
    /// Set on lines that leave a fenced code block open, carrying its
    /// `CodeState` (language, open comment or string), so an incremental
    /// pass can resume mid-document and knows when a fence change settles.
    static let mdCodeBlock = NSAttributedString.Key("mdCodeBlock")
}

/// A resolved image embed carried as an attribute on the (concealed)
/// image syntax; the layout manager draws it inside the line fragment.
final class ImageEmbed: NSObject {
    let image: NSImage
    let size: NSSize
    init(image: NSImage, size: NSSize) {
        self.image = image
        self.size = size
    }
}

/// Live, in-place styling of markdown source. Content is styled; syntax
/// markers are tagged with `.mdMarker` so the view can render Obsidian-style
/// live preview (markers only visible on the active paragraph).
final class MarkdownHighlighter {

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private let heading = MarkdownHighlighter.regex(#"^(#{1,6})[ \t](.*)$"#)
    static let fence = MarkdownHighlighter.regex(#"^\s*(```|~~~)"#)
    private let task = MarkdownHighlighter.regex(#"^\s*[-*+][ \t]\[[ xX]\][ \t]"#)
    private let bullet = MarkdownHighlighter.regex(#"^(\s*)([-*+])[ \t]"#)
    private let ordered = MarkdownHighlighter.regex(#"^\s*\d+[.)][ \t]"#)
    private let quote = MarkdownHighlighter.regex(#"^\s*(>[ \t]?)+"#)
    private let rule = MarkdownHighlighter.regex(#"^\s*([-*_])(\s*\1){2,}\s*$"#)
    // Shared with EditorTextView, which uses them to continue a span's style
    // when typing at its (visually concealed) closing delimiter and to layer
    // bold/italic instead of blindly nesting delimiters.
    static let boldItalicText = MarkdownHighlighter.regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    static let boldText = MarkdownHighlighter.regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    // The opener may sit right after another delimiter (`***two** words*`);
    // the closer's guards are what keep this from matching inside `**bold**`.
    static let italicText = MarkdownHighlighter.regex(#"(?<!\w)(\*|_)(?![*_\s])(.+?)(?<![*_\s])\1(?![*\w])"#)
    static let inlineCode = MarkdownHighlighter.regex(#"`[^`\n]+`"#)
    static let linkText = MarkdownHighlighter.regex(#"\[((?:\\.|[^\]\\\n])*)\]\(([^)\n]*)\)"#)
    static let colorSpan = MarkdownHighlighter.regex(#"<span style="color:#([0-9A-Fa-f]{6})">(.+?)</span>"#)
    static let halfOpacitySpan = MarkdownHighlighter.regex(#"<span style="opacity:0\.5">(.+?)</span>"#)
    private static let labelEscape = MarkdownHighlighter.regex(#"\\(?=[\[\]\\])"#)

    /// Regex enumeration normally skips to the end of a rejected match. An
    /// apparent italic opener can be a star owned by a preceding bold
    /// delimiter, so resume one character later when that happens and find
    /// the real italic span that may follow.
    static func validItalicMatches(in string: String, range: NSRange,
                                   blockedByBoldMarkers blocked: [NSRange]) -> [NSTextCheckingResult] {
        var matches: [NSTextCheckingResult] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end,
              let match = italicText.firstMatch(in: string,
                                                range: NSRange(location: location, length: end - location)) {
            let delimiterLength = match.range(at: 1).length
            let open = NSRange(location: match.range.location, length: delimiterLength)
            let close = NSRange(location: NSMaxRange(match.range) - delimiterLength, length: delimiterLength)
            if blocked.contains(where: {
                NSIntersectionRange($0, open).length > 0 || NSIntersectionRange($0, close).length > 0
            }) {
                location = match.range.location + 1
            } else {
                matches.append(match)
                location = NSMaxRange(match.range)
            }
        }
        return matches
    }

    static let imageEmbed = MarkdownHighlighter.regex(#"^\s*!\[([^\]\n]*)\]\(([^)\n]+)\)\s*$"#)
    static let wikiImageEmbed = MarkdownHighlighter.regex(#"^\s*!\[\[([^\]\n]+)\]\]\s*$"#)
    /// Obsidian wiki link: `[[Note]]`, `[[Note#Heading]]`, `[[Note|Alias]]`.
    /// The leading `!` of an embed is excluded so images keep their own rule.
    static let wikiLink = MarkdownHighlighter.regex(#"(?<!\!)\[\[([^\[\]\n|]+)(?:\|([^\[\]\n]*))?\]\]"#)
    /// Bare and angle-bracketed URLs, which GitHub turns into links too.
    static let autoLink = MarkdownHighlighter.regex(#"<((?:https?|mailto):[^>\s]+)>|(?<![\w@./:-])((?:https?://|mailto:)[^\s<>()\[\]"'`]+[^\s<>()\[\]"'`.,;:!?])"#)

    /// Headings, for resolving `#anchor` link fragments.
    static let anchorHeading = MarkdownHighlighter.regex(#"^(#{1,6})[ \t]+(.*)$"#)

    /// The document's headings in order, for the Contents menu: the visible
    /// title (inline markers stripped), level, and the line's location.
    static func outline(of text: NSString) -> [(title: String, level: Int, location: Int)] {
        var result: [(String, Int, Int)] = []
        var lineStart = 0
        var inCodeBlock = false
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)
            if fence.firstMatch(in: line, range: local) != nil {
                inCodeBlock.toggle()
            } else if !inCodeBlock, let m = anchorHeading.firstMatch(in: line, range: local) {
                let raw = (line as NSString).substring(with: m.range(at: 2))
                let title = raw
                    .replacingOccurrences(of: #"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"<[^>]+>|[*_`~]+|\s#+\s*$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { result.append((title, m.range(at: 1).length, lineRange.location)) }
            }
            lineStart = NSMaxRange(lineRange)
        }
        return result
    }

    /// The local images a note embeds (`![alt](path)` and `![[name]]`),
    /// resolved with `resolveWiki` for wiki embeds; existing files only.
    static func embeddedImages(in text: String, from source: URL, resolveWiki: (String) -> URL?) -> [URL] {
        var urls: [URL] = []
        for line in text.components(separatedBy: .newlines) {
            let local = NSRange(location: 0, length: (line as NSString).length)
            if let m = imageEmbed.firstMatch(in: line, range: local) {
                let destination = (line as NSString).substring(with: m.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if let url = FileReference.resolve(destination.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), from: source) {
                    urls.append(url)
                }
            } else if let m = wikiImageEmbed.firstMatch(in: line, range: local),
                      let url = resolveWiki((line as NSString).substring(with: m.range(at: 1))) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { url in
            FileManager.default.fileExists(atPath: url.path) && FileKind.classify(url) == .image
                && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// The line range of the heading an `#anchor` names. Both sides are
    /// slugged, so a GitHub fragment (`#my-heading`) and an Obsidian one
    /// (`#My Heading`) find the same line.
    static func headingRange(forAnchor anchor: String, in text: NSString) -> NSRange? {
        let wanted = FileReference.slug(anchor)
        guard !wanted.isEmpty else { return nil }
        var lineStart = 0
        var inCodeBlock = false
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)
            if fence.firstMatch(in: line, range: local) != nil {
                inCodeBlock.toggle()
            } else if !inCodeBlock, let m = anchorHeading.firstMatch(in: line, range: local),
                      FileReference.slug((line as NSString).substring(with: m.range(at: 2))) == wanted {
                return lineRange
            }
            lineStart = NSMaxRange(lineRange)
        }
        return nil
    }

    /// Directory of the current document; relative image paths resolve here.
    var baseDirectory: URL?
    /// Resolves a wiki-link target against the workspace so unresolved
    /// links can be drawn as broken. Nil (no folder open) means "assume
    /// resolvable" — the click handler falls back to sibling lookup.
    var resolveWikiLink: ((String) -> URL?)?
    /// Called (on main, outside a highlight pass) when an async image load
    /// finishes and the document should re-render.
    var onImageLoaded: (() -> Void)?

    private var loadedEmbeds: [String: ImageEmbed] = [:]
    private var failedImagePaths: Set<String> = []
    private var imagesInFlight: Set<String> = []

    private enum EmbedState {
        case loaded(ImageEmbed)
        case pending
        case failed
    }

    /// Resolves and (asynchronously, via the shared ImageLoader thumbnail
    /// pipeline) loads an embedded image; never decodes on the main thread.
    private func embedState(path rawPath: String) -> EmbedState {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
            .removingPercentEncoding ?? rawPath
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let baseDirectory {
            url = baseDirectory.appendingPathComponent(expanded)
        } else {
            return .failed
        }
        let key = url.path
        if let embed = loadedEmbeds[key] { return .loaded(embed) }
        if failedImagePaths.contains(key) { return .failed }
        if imagesInFlight.contains(key) { return .pending }
        guard FileManager.default.fileExists(atPath: key) else { return .failed }
        imagesInFlight.insert(key)
        ImageLoader.shared.thumbnail(url, pixels: 768) { [weak self] cgImage in
            guard let self else { return }
            imagesInFlight.remove(key)
            if let cgImage {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                var size = NSSize(width: CGFloat(cgImage.width) / scale,
                                  height: CGFloat(cgImage.height) / scale)
                if size.width > Theme.maxImageWidth {
                    let factor = Theme.maxImageWidth / size.width
                    size = NSSize(width: Theme.maxImageWidth, height: size.height * factor)
                }
                let image = NSImage(cgImage: cgImage, size: size)
                loadedEmbeds[key] = ImageEmbed(image: image, size: size)
            } else {
                failedImagePaths.insert(key)
            }
            onImageLoaded?()
        }
        return .pending
    }

    private var isHighlighting = false

    /// Fonts, semantic colors and paragraph styles for a pass. Theme's
    /// getters hit UserDefaults or NSFontManager on every call, so lines
    /// share these; full passes rebuild them.
    private final class Style {
        let family: String
        let fontSize: CGFloat
        let baseAttributes = Theme.baseAttributes
        let baseFont: NSFont
        let monoFont: NSFont
        let concealedFont: NSFont
        /// Levels 1, 2, 3, and 4–6.
        let headingFonts: [NSFont]
        let headingParagraph: NSParagraphStyle
        let codeParagraph: NSParagraphStyle
        let bold: (font: NSFont, synthetic: Bool)
        let italic: (font: NSFont, synthetic: Bool)
        let boldItalic: (font: NSFont, syntheticBold: Bool, syntheticItalic: Bool)
        let bulletGlyph: CGGlyph
        /// Extra width added (via kerning) to the space after a list/quote
        /// marker so the gap is a consistent half-em. Proportional fonts have
        /// narrow spaces (~0.25em in Hoefler), which makes the gap after a
        /// bullet look cramped; monospace fonts need no correction.
        let markerKern: CGFloat
        let boldColor = Theme.bold, headingColor = Theme.heading, italicColor = Theme.italic
        let codeAmber = Theme.codeAmber, listMarker = Theme.listMarker
        let quote = Theme.quote, link = Theme.link
        let syntax = Theme.palette.syntax
        private var hangingIndents: [String: NSParagraphStyle] = [:]

        init(family: String, fontSize: CGFloat) {
            self.family = family
            self.fontSize = fontSize
            baseFont = Theme.font(size: fontSize)
            monoFont = Theme.codeFont(size: (fontSize * 0.9).rounded())
            concealedFont = Theme.font(size: 0.1)
            headingFonts = [1.5, 1.3, 1.15, 1.0].map { Theme.font(size: (fontSize * $0).rounded()) }
            headingParagraph = Theme.paragraphStyle(spacingBefore: fontSize * 0.42,
                                                    spacingAfter: fontSize * 0.20)
            // Code lines are indented; the layout manager stretches the
            // block's background band back to the margin, so the indent
            // reads as the band's interior padding.
            let code = NSMutableParagraphStyle()
            code.lineHeightMultiple = Theme.lineHeightMultiple
            code.firstLineHeadIndent = Theme.codeBlockPadding
            code.headIndent = Theme.codeBlockPadding
            codeParagraph = code
            bold = Theme.boldFont(size: fontSize)
            italic = Theme.italicFont(size: fontSize)
            boldItalic = Theme.boldItalicFont(size: fontSize)
            var character: UniChar = 0x2022
            var glyph: CGGlyph = 0
            bulletGlyph = CTFontGetGlyphsForCharacters(baseFont, &character, &glyph, 1) ? glyph : 0
            let spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
            markerKern = max(0, fontSize * 0.5 - spaceWidth)
        }

        /// List/quote lines get a base indent, and their wrapped lines align
        /// with the text after the marker (a hanging indent, including the
        /// widened marker gap).
        func hangingIndent(prefix: String, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
            let key = "\(spacingBefore)|\(prefix)"
            if let cached = hangingIndents[key] { return cached }
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = Theme.lineHeightMultiple
            style.paragraphSpacingBefore = spacingBefore
            let baseIndent = fontSize
            style.firstLineHeadIndent = baseIndent
            var displayedPrefix = prefix
            if let marker = displayedPrefix.firstIndex(where: { !$0.isWhitespace }),
               "-*+".contains(displayedPrefix[marker]) {
                displayedPrefix.replaceSubrange(marker...marker, with: "•")
            }
            style.headIndent = baseIndent + markerKern
                + (displayedPrefix as NSString).size(withAttributes: [.font: baseFont]).width
            hangingIndents[key] = style
            return style
        }
    }

    private var style: Style?

    /// Draws an unordered Markdown marker as a typographic bullet without
    /// changing the backing source character.
    private func substituteBulletGlyph(_ ts: NSTextStorage, markerRange: NSRange, style: Style) {
        guard style.bulletGlyph != 0,
              let info = NSGlyphInfo(cgGlyph: style.bulletGlyph, for: style.baseFont,
                                     baseString: (ts.string as NSString).substring(with: markerRange)) else { return }
        ts.addAttribute(.glyphInfo, value: info, range: markerRange)
    }

    /// Widens the marker's trailing space via kerning.
    private func widenMarkerGap(_ ts: NSTextStorage, markerRange: NSRange, style: Style) {
        guard style.markerKern > 0.1 else { return }
        ts.addAttribute(.kern, value: style.markerKern, range: NSRange(location: NSMaxRange(markerRange) - 1, length: 1))
    }

    /// Restyles the whole document, then conceals every syntax marker by
    /// shrinking it to a ~0pt font — WYSIWYG: the markdown stays in the file
    /// but is never shown. Attribute-only concealment keeps TextKit layout
    /// fully consistent.
    func highlight(_ textStorage: NSTextStorage) {
        style = nil
        restyle(textStorage, from: 0, to: nil)
    }

    /// Restyles just the lines `edited` (in current coordinates) touches,
    /// matching a full pass: the lines either side too (list spacing reads
    /// the previous line), then onward until a line's fenced-code state is
    /// what it was before the edit.
    func highlight(_ textStorage: NSTextStorage, edited: NSRange) {
        let text = textStorage.string as NSString
        let location = min(edited.location, text.length)
        // Through the character after the edit: an inserted newline leaves
        // the rest of its line as a new line.
        let lines = text.lineRange(for: NSRange(location: location,
                                                length: min(edited.length + 1, text.length - location)))
        var start = lines.location, end = NSMaxRange(lines)
        if start > 0 { start = text.lineRange(for: NSRange(location: start - 1, length: 0)).location }
        if end < text.length { end = NSMaxRange(text.lineRange(for: NSRange(location: end, length: 0))) }
        restyle(textStorage, from: start, to: end)
    }

    /// Styles whole lines from `start` (a line start) through `end`, or to
    /// the end of the document when `end` is nil.
    private func restyle(_ textStorage: NSTextStorage, from start: Int, to end: Int?) {
        guard !isHighlighting else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        let family = Theme.fontFamily, fontSize = Theme.fontSize
        if style?.family != family || style?.fontSize != fontSize {
            style = Style(family: family, fontSize: fontSize)
        }
        guard let style else { return }
        let text = textStorage.string as NSString

        textStorage.beginEditing()
        var code = start > 0
            ? CodeState(attributeValue: textStorage.attribute(.mdCodeBlock, at: start - 1, effectiveRange: nil))
            : nil
        var lineStart = start
        while lineStart < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let previous = end == nil ? nil
                : CodeState(attributeValue: textStorage.attribute(.mdCodeBlock, at: NSMaxRange(lineRange) - 1,
                                                                  effectiveRange: nil))
            textStorage.setAttributes(style.baseAttributes, range: lineRange)
            highlightLine(textStorage, text: text, lineRange: lineRange, code: &code, style: style)
            if let code { textStorage.addAttribute(.mdCodeBlock, value: code.attributeValue, range: lineRange) }
            lineStart = NSMaxRange(lineRange)
            if let end, lineStart >= end, code == previous { break }
        }

        let styled = NSRange(location: start, length: lineStart - start)
        textStorage.enumerateAttribute(.mdMarker, in: styled) { value, range, _ in
            guard value != nil else { return }
            textStorage.addAttribute(.font, value: style.concealedFont, range: range)
        }
        textStorage.endEditing()
    }

    private func highlightLine(_ ts: NSTextStorage, text: NSString, lineRange: NSRange,
                               code: inout CodeState?, style: Style) {
        let line = text.substring(with: lineRange)
        let localRange = NSRange(location: 0, length: (line as NSString).length)
        func global(_ r: NSRange) -> NSRange { NSRange(location: lineRange.location + r.location, length: r.length) }
        func mark(_ r: NSRange) { ts.addAttribute(.mdMarker, value: true, range: r) }

        let monoFont = style.monoFont
        let codeStyle = style.codeParagraph
        if let fence = Self.fence.firstMatch(in: line, range: localRange) {
            if code == nil {
                // An unlabeled block is guessed from its first line, which an
                // incremental pass reaches only by restyling this one too.
                let info = (line as NSString).substring(from: NSMaxRange(fence.range))
                code = CodeState(language: CodeLanguage(info: info) ?? {
                    guard NSMaxRange(lineRange) < text.length else { return .plain }
                    let next = text.substring(with: text.lineRange(for: NSRange(location: NSMaxRange(lineRange), length: 0)))
                    return Self.fence.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) == nil
                        ? CodeLanguage.guess(firstLine: next) : .plain
                }())
            } else {
                code = nil
            }
            ts.addAttributes([.font: monoFont, .foregroundColor: Theme.dim,
                              .backgroundColor: Theme.codeBlockBackground,
                              .paragraphStyle: codeStyle], range: lineRange)
            return
        }
        if var state = code {
            ts.addAttributes([.font: monoFont, .foregroundColor: Theme.code,
                              .backgroundColor: Theme.codeBlockBackground,
                              .paragraphStyle: codeStyle], range: lineRange)
            CodeSyntax.tokenize(line, state: &state) { token, range in
                ts.addAttribute(.foregroundColor, value: style.syntax[token], range: global(range))
            }
            code = state
            return
        }

        // Image embeds: the syntax line conceals entirely and the layout
        // manager draws the image in the (heightened) line fragment.
        for (regex, pathGroup) in [(Self.imageEmbed, 2), (Self.wikiImageEmbed, 1)] {
            guard let m = regex.firstMatch(in: line, range: localRange) else { continue }
            let path = (line as NSString).substring(with: m.range(at: pathGroup))
            switch embedState(path: path) {
            case .loaded(let embed):
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = embed.size.height + 12
                ts.addAttributes([
                    .paragraphStyle: style,
                    .foregroundColor: Theme.dim,
                    .mdImage: embed,
                ], range: lineRange)
                mark(global(m.range))
            case .pending, .failed:
                // Loading, or missing file: keep the syntax visible but
                // dimmed (a broken path can then be seen and fixed).
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: lineRange)
            }
            return
        }

        // Block-level rules.
        let previousLineIsList: Bool = {
            guard lineRange.location > 0 else { return false }
            let previousRange = text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
            let previous = text.substring(with: previousRange)
            let range = NSRange(location: 0, length: (previous as NSString).length)
            return task.firstMatch(in: previous, range: range) != nil
                || bullet.firstMatch(in: previous, range: range) != nil
                || ordered.firstMatch(in: previous, range: range) != nil
        }()
        let listSpacing = previousLineIsList ? style.fontSize * 0.18 : 0
        if let m = heading.firstMatch(in: line, range: localRange) {
            let level = m.range(at: 1).length
            var attributes: [NSAttributedString.Key: Any] = [
                .font: style.headingFonts[min(level, 4) - 1],
                .strokeWidth: -3.0,
                .paragraphStyle: style.headingParagraph,
            ]
            if let color = style.headingColor { attributes[.foregroundColor] = color }
            ts.addAttributes(attributes, range: lineRange)
            let prefix = NSRange(location: lineRange.location, length: level + 1)
            ts.addAttributes([.foregroundColor: Theme.dim, .strokeWidth: 0.0], range: prefix)
            mark(prefix)
        }
        if rule.firstMatch(in: line, range: localRange) != nil, line.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 {
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: lineRange)
            return
        }
        if let m = quote.firstMatch(in: line, range: localRange) {
            if let color = style.quote { ts.addAttribute(.foregroundColor, value: color, range: lineRange) }
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: global(m.range))
            ts.addAttribute(.paragraphStyle, value: style.hangingIndent(prefix: (line as NSString).substring(with: m.range)), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range), style: style)
        } else if let m = task.firstMatch(in: line, range: localRange) {
            if let color = style.listMarker { ts.addAttribute(.foregroundColor, value: color, range: global(m.range)) }
            ts.addAttribute(.paragraphStyle, value: style.hangingIndent(prefix: (line as NSString).substring(with: m.range), spacingBefore: listSpacing), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range), style: style)
        } else if let m = bullet.firstMatch(in: line, range: localRange) {
            if let color = style.listMarker { ts.addAttribute(.foregroundColor, value: color, range: global(m.range)) }
            ts.addAttribute(.paragraphStyle, value: style.hangingIndent(prefix: (line as NSString).substring(with: m.range), spacingBefore: listSpacing), range: lineRange)
            substituteBulletGlyph(ts, markerRange: global(m.range(at: 2)), style: style)
            widenMarkerGap(ts, markerRange: global(m.range), style: style)
        } else if let m = ordered.firstMatch(in: line, range: localRange) {
            if let color = style.listMarker { ts.addAttribute(.foregroundColor, value: color, range: global(m.range)) }
            ts.addAttribute(.paragraphStyle, value: style.hangingIndent(prefix: (line as NSString).substring(with: m.range), spacingBefore: listSpacing), range: lineRange)
            widenMarkerGap(ts, markerRange: global(m.range), style: style)
        }

        // Inline rules.
        Self.inlineCode.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            ts.addAttributes([.font: monoFont, .backgroundColor: Theme.codeBackground], range: r)
            if let color = style.codeAmber { ts.addAttribute(.foregroundColor, value: color, range: r) }
            let open = NSRange(location: r.location, length: 1)
            let close = NSRange(location: NSMaxRange(r) - 1, length: 1)
            for tick in [open, close] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: tick)
                mark(tick)
            }
        }
        // Triple delimiters are bold+italic in one span; handled first, and
        // excluded below so the two-star rule can't half-match inside them.
        var tripleRanges: [NSRange] = []
        Self.boldItalicText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            tripleRanges.append(m.range)
            let r = global(m.range)
            let (biFont, syntheticBold, syntheticItalic) = style.boldItalic
            ts.addAttribute(.font, value: biFont, range: r)
            if let color = style.boldColor { ts.addAttribute(.foregroundColor, value: color, range: r) }
            if syntheticBold { ts.addAttribute(.strokeWidth, value: -3.0, range: r) }
            if syntheticItalic { ts.addAttribute(.obliqueness, value: 0.18, range: r) }
            let dLen = m.range(at: 1).length
            let open = NSRange(location: r.location, length: dLen)
            let close = NSRange(location: NSMaxRange(r) - dLen, length: dLen)
            for delim in [open, close] {
                ts.addAttributes([.foregroundColor: Theme.dim, .obliqueness: 0.0, .strokeWidth: 0.0], range: delim)
                mark(delim)
            }
        }
        func insideTriple(_ range: NSRange) -> Bool {
            tripleRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        var boldMarkerRanges: [NSRange] = []
        Self.boldText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideTriple(m.range) else { return }
            let r = global(m.range)
            // White and genuinely bold (synthetic stroke when the family
            // has no bold face, e.g. Classic Console Neue).
            let (boldFont, synthetic) = style.bold
            ts.addAttribute(.font, value: boldFont, range: r)
            if let color = style.boldColor { ts.addAttribute(.foregroundColor, value: color, range: r) }
            if synthetic { ts.addAttribute(.strokeWidth, value: -3.0, range: r) }
            let dLen = m.range(at: 1).length
            let open = NSRange(location: r.location, length: dLen)
            let close = NSRange(location: NSMaxRange(r) - dLen, length: dLen)
            boldMarkerRanges.append(NSRange(location: m.range.location, length: dLen))
            boldMarkerRanges.append(NSRange(location: NSMaxRange(m.range) - dLen, length: dLen))
            for delim in [open, close] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: delim)
                mark(delim)
            }
        }
        for m in Self.validItalicMatches(in: line, range: localRange,
                                         blockedByBoldMarkers: boldMarkerRanges) {
            guard !insideTriple(m.range) else { continue }
            let r = global(m.range)
            let delimiterLength = m.range(at: 1).length
            let open = NSRange(location: r.location, length: delimiterLength)
            let close = NSRange(location: NSMaxRange(r) - delimiterLength, length: delimiterLength)
            // Real italic face when the family has one; slant otherwise.
            if let color = style.italicColor { ts.addAttribute(.foregroundColor, value: color, range: r) }
            let (italicFont, synthetic) = style.italic
            if synthetic {
                ts.addAttribute(.obliqueness, value: 0.18, range: r)
            } else {
                ts.addAttribute(.font, value: italicFont, range: r)
            }
            for delim in [open, close] {
                ts.addAttributes([.foregroundColor: Theme.dim, .obliqueness: 0.0], range: delim)
                mark(delim)
            }
        }
        let codeRanges = Self.inlineCode.matches(in: line, range: localRange).map(\.range)
        func insideCode(_ r: NSRange) -> Bool {
            codeRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        let linkRanges = Self.linkText.matches(in: line, range: localRange).map(\.range)
        Self.linkText.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideCode(m.range) else { return }
            let r = global(m.range)
            let textRange = global(m.range(at: 1))
            let destination = (line as NSString).substring(with: m.range(at: 2))
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: r)
            ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
            if let color = style.link { ts.addAttribute(.foregroundColor, value: color, range: textRange) }
            // Every link is clickable; the window decides whether the
            // destination is a file, an in-document anchor, or a URL.
            if !destination.isEmpty, textRange.length > 0 {
                ts.addAttribute(.fileReference, value: destination, range: textRange)
            }
            let label = (line as NSString).substring(with: m.range(at: 1))
            if label.hasPrefix("@") {
                let (font, synthetic) = style.bold
                ts.addAttributes([
                    .font: font, .foregroundColor: NSColor(hex: 0x4169E1),
                    .underlineStyle: 0,
                ], range: textRange)
                if synthetic { ts.addAttribute(.strokeWidth, value: -3.0, range: textRange) }
                // Markdown escapes in filenames remain in the source only.
                Self.labelEscape.enumerateMatches(in: label, range: NSRange(location: 0, length: (label as NSString).length)) { match, _, _ in
                    if let match { mark(NSRange(location: textRange.location + match.range.location, length: 1)) }
                }
            }
            // Hide "[", then "](url)".
            mark(NSRange(location: r.location, length: 1))
            mark(NSRange(location: NSMaxRange(textRange), length: NSMaxRange(r) - NSMaxRange(textRange)))
        }
        // Obsidian wiki links. The visible run is the alias when one is
        // given, the target otherwise; the brackets conceal like any other
        // syntax. Targets that name nothing in the workspace read as broken
        // instead of pretending to be navigable.
        Self.wikiLink.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideCode(m.range) else { return }
            let r = global(m.range)
            let target = (line as NSString).substring(with: m.range(at: 1))
            let alias = m.range(at: 2)
            let visible = alias.location == NSNotFound ? global(m.range(at: 1)) : global(alias)
            let resolved = self.resolveWikiLink.map { $0(target) != nil } ?? true
            ts.addAttribute(.foregroundColor, value: Theme.dim, range: r)
            if resolved {
                if let color = style.link { ts.addAttribute(.foregroundColor, value: color, range: visible) }
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: visible)
                ts.addAttribute(.wikiReference, value: target, range: visible)
            } else {
                ts.addAttributes([
                    .foregroundColor: (style.link ?? Theme.foreground).withAlphaComponent(0.45),
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                ], range: visible)
            }
            // Hide "[[" (plus "target|" when aliased), then "]]".
            mark(NSRange(location: r.location, length: visible.location - r.location))
            mark(NSRange(location: NSMaxRange(visible), length: NSMaxRange(r) - NSMaxRange(visible)))
        }
        // Bare URLs, the way GitHub auto-links them.
        Self.autoLink.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m, !insideCode(m.range) else { return }
            let bracketed = m.range(at: 1)
            let inner = bracketed.location == NSNotFound ? m.range(at: 2) : bracketed
            guard inner.location != NSNotFound,
                  !linkRanges.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
            let r = global(inner)
            if let color = style.link { ts.addAttribute(.foregroundColor, value: color, range: r) }
            ts.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .fileReference: (line as NSString).substring(with: inner),
            ], range: r)
            if bracketed.location != NSNotFound {
                mark(NSRange(location: global(m.range).location, length: 1))
                mark(NSRange(location: NSMaxRange(r), length: 1))
            }
        }
        // Applied last so an explicit color wins inside bold/italic runs.
        Self.colorSpan.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            let contentRange = global(m.range(at: 2))
            if let color = NSColor(hexString: (line as NSString).substring(with: m.range(at: 1))) {
                ts.addAttribute(.foregroundColor, value: color, range: contentRange)
            }
            let openTag = NSRange(location: r.location, length: contentRange.location - r.location)
            let closeTag = NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(r) - NSMaxRange(contentRange))
            for tag in [openTag, closeTag] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: tag)
                mark(tag)
            }
        }
        // The muted palette choice is the normal prose color at half alpha.
        // Keep it separate from a fixed hex color so it continues to follow
        // the theme's foreground color.
        Self.halfOpacitySpan.enumerateMatches(in: line, range: localRange) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            let contentRange = global(m.range(at: 1))
            ts.addAttribute(.foregroundColor, value: Theme.foreground.withAlphaComponent(0.5),
                            range: contentRange)
            let openTag = NSRange(location: r.location, length: contentRange.location - r.location)
            let closeTag = NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(r) - NSMaxRange(contentRange))
            for tag in [openTag, closeTag] {
                ts.addAttribute(.foregroundColor, value: Theme.dim, range: tag)
                mark(tag)
            }
        }
    }
}
