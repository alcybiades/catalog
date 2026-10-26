import AppKit

/// Markdown text view: mouse-first editing with terminal aesthetics, live
/// Obsidian-style preview (syntax markers hidden except on the caret's
/// paragraph), slash commands, format shortcuts, and list continuation.
final class EditorTextView: NSTextView {

    /// How a chosen file is spelled into the document. `@` inserts a
    /// Markdown link; `[[` inserts an Obsidian wiki link.
    enum ReferenceStyle { case markdown, wiki }

    private let highlighter = MarkdownHighlighter()
    var referencesEnabled = false
    var referenceCandidates: ((String) -> [(URL, String)])?
    var onInsertReference: ((URL, NSRange, ReferenceStyle) -> Void)?
    var onOpenReference: ((String) -> Void)?
    var onOpenWikiLink: ((String) -> Void)?
    /// Lets the highlighter draw wiki links that name nothing as broken.
    var wikiLinkResolver: ((String) -> URL?)?
    private var referenceRange: NSRange?
    /// The literal that opened the picker: "@" or "[[".
    private var referenceTrigger = "@"
    private lazy var referencePicker: ReferencePicker = {
        let picker = ReferencePicker()
        picker.onChoose = { [weak self] url in
            guard let self, let range = self.referenceRange else { return }
            let style: ReferenceStyle = self.referenceTrigger == "[[" ? .wiki : .markdown
            self.referenceRange = nil
            self.onInsertReference?(url, range, style)
        }
        return picker
    }()

    func dismissReferences() { referenceRange = nil; referencePicker.dismiss() }

    private func updateReferences() {
        guard let range = referenceRange, selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        let ns = string as NSString
        let triggerLength = (referenceTrigger as NSString).length
        guard caret >= range.location + triggerLength, caret <= ns.length,
              ns.substring(with: NSRange(location: range.location, length: triggerLength)) == referenceTrigger,
              let window else { dismissReferences(); return }
        let query = ns.substring(with: NSRange(location: range.location + triggerLength,
                                               length: caret - range.location - triggerLength))
        guard !query.contains("\n"), query.count < 160 else { dismissReferences(); return }
        referenceRange = NSRange(location: range.location, length: caret - range.location)
        referencePicker.show(referenceCandidates?(query) ?? [], below: firstRect(forCharacterRange: NSRange(location: range.location, length: triggerLength), actualRange: nil), parent: window)
    }

    override func keyDown(with event: NSEvent) {
        if referencePicker.isVisible {
            switch event.keyCode {
            case 125: referencePicker.move(1); return
            case 126: referencePicker.move(-1); return
            case 36, 48: referencePicker.choose(); return
            case 53: dismissReferences(); return
            default: break
            }
        }
        // Arrow/Home/End/Page navigation leaves a typing-format mode just
        // as clicking elsewhere does. Option/Command variants share these
        // hardware key codes.
        if [123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode) {
            clearPendingInlineStyle()
        }
        super.keyDown(with: event)
        updateReferences()
    }

    /// The link under a point in view coordinates, if the point actually
    /// lands on its glyphs.
    private func link(at viewPoint: NSPoint) -> (destination: String, wiki: Bool)? {
        guard let layoutManager, let textContainer, let textStorage else { return nil }
        var point = viewPoint
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        // The inset rejects clicks in the blank run past a line's end. Scale
        // it to the glyph so narrow letters stay clickable.
        let hit = rect.insetBy(dx: min(3, rect.width / 3), dy: min(2, rect.height / 3))
        guard hit.contains(point), index < textStorage.length else { return nil }
        if let destination = textStorage.attribute(.fileReference, at: index, effectiveRange: nil) as? String {
            return (destination, false)
        }
        if let target = textStorage.attribute(.wikiReference, at: index, effectiveRange: nil) as? String {
            return (target, true)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        clearPendingInlineStyle()
        dismissReferences()
        // Option-click places the caret inside a link instead of following it.
        if !event.modifierFlags.contains(.option),
           let link = link(at: convert(event.locationInWindow, from: nil)) {
            if link.wiki { onOpenWikiLink?(link.destination) } else { onOpenReference?(link.destination) }
            return
        }
        super.mouseDown(with: event)
    }

    /// A pointing hand over anything clickable, so links advertise themselves.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return }
        var bounds = visibleRect
        bounds.origin.x -= textContainerOrigin.x
        bounds.origin.y -= textContainerOrigin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: textContainer)
        guard glyphRange.length > 0 else { return }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        for key in [NSAttributedString.Key.fileReference, .wikiReference] {
            textStorage.enumerateAttribute(key, in: charRange) { value, range, _ in
                guard value != nil else { return }
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { rect, _ in
                    var rect = rect
                    rect.origin.x += self.textContainerOrigin.x
                    rect.origin.y += self.textContainerOrigin.y
                    self.addCursorRect(rect, cursor: .pointingHand)
                }
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        dismissReferences()
        return super.resignFirstResponder()
    }

    /// Extra space above the text for the inline document title. The inset
    /// carries half of it, and the origin shift moves that half to the top,
    /// so the bottom keeps the plain padding.
    var extraTopInset: CGFloat = 0

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.y += extraTopInset / 2
        return origin
    }

    // MARK: - Setup

    func configure() {
        drawsBackground = false
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        smartInsertDeleteEnabled = false

        insertionPointColor = Theme.cursor
        selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: NSColor(hex: 0xF8FAFC),
        ]
        typingAttributes = Theme.baseAttributes

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: NSTextView.didChangeSelectionNotification, object: self)
    }

    /// Supplies the current document's directory so relative image paths
    /// resolve against it; queried fresh on every highlight pass.
    var baseDirectoryProvider: (() -> URL?)? {
        didSet {
            highlighter.onImageLoaded = { [weak self] in self?.rehighlight() }
        }
    }

    func rehighlight() {
        highlighter.baseDirectory = baseDirectoryProvider?() ?? nil
        highlighter.resolveWikiLink = wikiLinkResolver
        if let textStorage { highlighter.highlight(textStorage) }
        typingAttributes = Theme.baseAttributes
        window?.invalidateCursorRects(for: self)
    }

    override func didChangeText() {
        super.didChangeText()
        rehighlight()
    }

    // MARK: - WYSIWYG: the caret skips concealed markers

    /// The full run of concealed marker characters containing `index`.
    private func concealedRun(containing index: Int) -> NSRange? {
        guard let textStorage, index >= 0, index < textStorage.length else { return nil }
        var effective = NSRange()
        let full = NSRange(location: 0, length: textStorage.length)
        guard textStorage.attribute(.mdMarker, at: index,
                                    longestEffectiveRange: &effective, in: full) != nil else { return nil }
        return effective
    }

    private var navigating = false

    override func moveLeft(_ sender: Any?) {
        clearPendingInlineStyle()
        navigating = true
        defer { navigating = false }
        let initial = selectedRange()
        // The source positions on either side of a concealed run represent
        // one visual caret stop. Collapse that alias before moving so a
        // single arrow press always reaches the next visible character.
        if initial.length == 0, initial.location > 0,
           let run = concealedRun(containing: initial.location - 1),
           NSMaxRange(run) == initial.location {
            setSelectedRange(NSRange(location: run.location, length: 0))
        }
        super.moveLeft(sender)
        let caret = selectedRange().location
        if let run = concealedRun(containing: caret), caret > run.location {
            setSelectedRange(NSRange(location: run.location, length: 0))
        }
    }

    override func moveRight(_ sender: Any?) {
        clearPendingInlineStyle()
        navigating = true
        defer { navigating = false }
        let initial = selectedRange()
        if initial.length == 0,
           let run = concealedRun(containing: initial.location),
           run.location == initial.location {
            setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
        }
        super.moveRight(sender)
        let caret = selectedRange().location
        if caret > 0, let run = concealedRun(containing: caret - 1), caret < NSMaxRange(run) {
            setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
        }
    }

    // MARK: - Selection residue

    private var lastSelectionRect: NSRect = .zero

    /// Concealed 0.1pt markers give line fragments fractional heights, so
    /// the rect AppKit repaints when a selection moves away can be a hair
    /// smaller than the highlight it drew — leaving ~1px slivers of the old
    /// selection color at the line's edges. Repaint generously around both
    /// the old and new selection.
    private func repaintSelectionNeighborhood() {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        setNeedsDisplay(lastSelectionRect.insetBy(dx: -4, dy: -4))
        setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
        lastSelectionRect = rect
    }

    /// Clicks and vertical movement can land the caret inside a concealed
    /// run; snap it to the nearer edge.
    @objc private func selectionChanged() {
        repaintSelectionNeighborhood()
        guard !navigating else { return }
        let sel = selectedRange()
        if sel.length > 0 { clearPendingInlineStyle() }
        guard sel.length == 0, sel.location > 0 else { return }
        guard let run = concealedRun(containing: sel.location),
              sel.location > run.location,
              let leftRun = concealedRun(containing: sel.location - 1),
              leftRun == run else { return }
        let snapped = (sel.location - run.location <= NSMaxRange(run) - sel.location)
            ? run.location : NSMaxRange(run)
        setSelectedRange(NSRange(location: snapped, length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0 {
            replaceVisibleSelection(with: "", deleting: true)
            return
        }
        guard sel.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        guard let run = concealedRun(containing: sel.location - 1) else {
            deleteVisibleCharacter(ns.rangeOfComposedCharacterSequence(at: sel.location - 1))
            return
        }
        let paragraph = ns.paragraphRange(for: sel)
        if run.location == paragraph.location {
            // A concealed block marker (e.g. a heading's "# ") at the start
            // of the paragraph: backspace un-formats the block, Notion-style.
            insertText("", replacementRange: run)
            return
        }
        // Delete the nearest visible character to the left of the run.
        var index = run.location - 1
        while index >= 0, let outer = concealedRun(containing: index) {
            if outer.location == paragraph.location {
                insertText("", replacementRange: NSRange(location: outer.location, length: NSMaxRange(run) - outer.location))
                return
            }
            index = outer.location - 1
        }
        guard index >= 0 else {
            super.deleteBackward(sender)
            return
        }
        deleteVisibleCharacter(ns.rangeOfComposedCharacterSequence(at: index))
    }

    override func deleteForward(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        if sel.length > 0 {
            replaceVisibleSelection(with: "", deleting: true)
            return
        }
        guard sel.location < ns.length else {
            super.deleteForward(sender)
            return
        }
        guard let run = concealedRun(containing: sel.location) else {
            deleteVisibleCharacter(ns.rangeOfComposedCharacterSequence(at: sel.location), caretAfter: sel.location)
            return
        }
        // Delete the nearest visible character to the right of the run.
        var index = NSMaxRange(run)
        while index < ns.length, let outer = concealedRun(containing: index) {
            index = NSMaxRange(outer)
        }
        guard index < ns.length else {
            super.deleteForward(sender)
            return
        }
        deleteVisibleCharacter(ns.rangeOfComposedCharacterSequence(at: index), caretAfter: sel.location)
    }

    override func cut(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        copy(sender)
        replaceVisibleSelection(with: "", deleting: true)
    }

    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0 else { return }
        rehighlight()
        let ns = string as NSString
        var copied = ""
        for range in visibleSourceRanges(in: sel) {
            copied += ns.substring(with: range)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
    }

    // MARK: - Inline spans as atomic units

    /// Any inline span with concealed syntax (emphasis, code, color, link):
    /// full source range plus the visible content range.
    private struct InlineSpan {
        let range: NSRange
        let content: NSRange
    }

    /// All inline spans on the line containing `location`.
    private func inlineSpans(around location: Int) -> [InlineSpan] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        let lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        let local = NSRange(location: 0, length: (line as NSString).length)
        func g(_ r: NSRange) -> NSRange { NSRange(location: lineRange.location + r.location, length: r.length) }

        var spans: [InlineSpan] = []
        var tripleRanges: [NSRange] = []
        var boldMarkerRanges: [NSRange] = []
        MarkdownHighlighter.boldItalicText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            tripleRanges.append(m.range)
            spans.append(InlineSpan(range: g(m.range), content: g(m.range(at: 2))))
        }
        func overlapsTriple(_ r: NSRange) -> Bool {
            tripleRanges.contains { NSIntersectionRange($0, r).length > 0 }
        }
        MarkdownHighlighter.boldText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m, !overlapsTriple(m.range) else { return }
            let content = m.range(at: 2)
            boldMarkerRanges.append(NSRange(location: m.range.location,
                                             length: content.location - m.range.location))
            boldMarkerRanges.append(NSRange(location: NSMaxRange(content),
                                             length: NSMaxRange(m.range) - NSMaxRange(content)))
            spans.append(InlineSpan(range: g(m.range), content: g(content)))
        }
        for m in MarkdownHighlighter.validItalicMatches(in: line, range: local,
                                                         blockedByBoldMarkers: boldMarkerRanges) {
            guard !overlapsTriple(m.range) else { continue }
            spans.append(InlineSpan(range: g(m.range), content: g(m.range(at: 2))))
        }
        MarkdownHighlighter.inlineCode.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            let r = g(m.range)
            spans.append(InlineSpan(range: r, content: NSRange(location: r.location + 1, length: r.length - 2)))
        }
        MarkdownHighlighter.colorSpan.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            spans.append(InlineSpan(range: g(m.range), content: g(m.range(at: 2))))
        }
        MarkdownHighlighter.halfOpacitySpan.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            spans.append(InlineSpan(range: g(m.range), content: g(m.range(at: 1))))
        }
        MarkdownHighlighter.linkText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            spans.append(InlineSpan(range: g(m.range), content: g(m.range(at: 1))))
        }
        MarkdownHighlighter.wikiLink.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            let alias = m.range(at: 2)
            spans.append(InlineSpan(range: g(m.range),
                                    content: g(alias.location == NSNotFound ? m.range(at: 1) : alias)))
        }
        return spans
    }

    /// Source ranges for only the rendered characters in a visual selection.
    /// Markdown/HTML syntax is deliberately omitted even when TextKit's raw
    /// selection happens to include it.
    private func visibleSourceRanges(in selection: NSRange) -> [NSRange] {
        guard let textStorage, selection.length > 0 else { return [] }
        let inlineMarkers = inlineSpans(intersecting: selection).flatMap { span in
            [NSRange(location: span.range.location,
                     length: span.content.location - span.range.location),
             NSRange(location: NSMaxRange(span.content),
                     length: NSMaxRange(span.range) - NSMaxRange(span.content))]
        }
        var ranges: [NSRange] = []
        var start: Int?
        for index in selection.location..<NSMaxRange(selection) {
            // Derive inline markers structurally as well as consulting the
            // presentation attribute. This keeps editing correct even when
            // adjacent delimiter runs make highlighter precedence subtle.
            let concealed = inlineMarkers.contains { NSLocationInRange(index, $0) }
                || textStorage.attribute(.mdMarker, at: index, effectiveRange: nil) != nil
            if concealed {
                if let start { ranges.append(NSRange(location: start, length: index - start)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let start { ranges.append(NSRange(location: start, length: NSMaxRange(selection) - start)) }
        return ranges.filter { $0.length > 0 }
    }

    private func inlineSpans(intersecting range: NSRange) -> [InlineSpan] {
        let ns = string as NSString
        guard ns.length > 0 else { return [] }
        var spans: [InlineSpan] = []
        var location = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0)).location
        let end = min(max(NSMaxRange(range), location + 1), ns.length)
        while location < end {
            spans += inlineSpans(around: location)
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(line)
            if next <= location { break }
            location = next
        }
        return spans
    }

    private func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func selection(_ selection: NSRange, coversVisibleContentOf span: InlineSpan) -> Bool {
        let visible = visibleSourceRanges(in: span.content)
        return !visible.isEmpty && visible.allSatisfy {
            selection.location <= $0.location && NSMaxRange(selection) >= NSMaxRange($0)
        }
    }

    /// The common editing case is wholly inside one formatted run. Rewrite
    /// that run as a unit so its two delimiters remain balanced even when a
    /// raw TextKit endpoint lands on one of them.
    private func replaceInsideSingleSpan(_ visibleEdits: [NSRange], selection: NSRange,
                                         replacement: String, deleting: Bool) -> Bool {
        guard let first = visibleEdits.first, let last = visibleEdits.last else { return false }
        let candidates = inlineSpans(intersecting: selection).filter { span in
            first.location >= span.content.location && NSMaxRange(last) <= NSMaxRange(span.content)
        }.sorted { $0.range.length < $1.range.length }
        guard let span = candidates.first else { return false }
        let removesAllContent = self.selection(selection, coversVisibleContentOf: span)
        if deleting && removesAllContent { return false }

        let ns = string as NSString
        let opener = ns.substring(with: NSRange(location: span.range.location,
                                                 length: span.content.location - span.range.location))
        let closer = ns.substring(with: NSRange(location: NSMaxRange(span.content),
                                                 length: NSMaxRange(span.range) - NSMaxRange(span.content)))
        // Only Markdown emphasis/code delimiters have whitespace-sensitive
        // edges. HTML color/opacity spans accept whitespace as content.
        let markdownDelimiter = !opener.isEmpty
            && opener.allSatisfy { $0 == "*" || $0 == "_" || $0 == "`" }

        let content = NSMutableString(string: ns.substring(with: span.content))
        for range in visibleEdits.reversed() {
            let local = NSRange(location: range.location - span.content.location, length: range.length)
            content.replaceCharacters(in: local, with: range == first ? replacement : "")
        }

        var core = content as String
        var leading = ""
        var trailing = ""
        if markdownDelimiter {
            while let character = core.first, character.isWhitespace {
                leading.append(character)
                core.removeFirst()
            }
            while let character = core.last, character.isWhitespace {
                trailing.insert(character, at: trailing.startIndex)
                core.removeLast()
            }
        }

        let rewritten = core.isEmpty ? leading + trailing : leading + opener + core + closer + trailing
        super.insertText(rewritten, replacementRange: span.range)
        let insertionOffset = max(0, first.location - span.content.location)
        let caret = span.range.location + (leading as NSString).length
            + (core.isEmpty ? 0 : (opener as NSString).length)
            + min(insertionOffset + (replacement as NSString).length, (core as NSString).length)
        setSelectedRange(NSRange(location: min(caret, span.range.location + (rewritten as NSString).length), length: 0))
        return true
    }

    /// Applies an edit to rendered characters, not raw source offsets. Fully
    /// deleted spans lose their wrappers; partially edited spans keep them.
    /// This is the boundary between the WYSIWYG surface and Markdown storage.
    private func replaceVisibleSelection(with replacement: String, deleting: Bool) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        rehighlight()
        var edits = visibleSourceRanges(in: selection)
        if replaceInsideSingleSpan(edits, selection: selection,
                                   replacement: replacement, deleting: deleting) {
            clearPendingInlineStyle()
            return
        }

        if deleting {
            // Removing every visible character in a span should remove its
            // now-empty syntax too. Prefer outer wrappers when spans nest.
            let complete = inlineSpans(intersecting: selection).filter {
                self.selection(selection, coversVisibleContentOf: $0)
            }.sorted { $0.range.length > $1.range.length }
            var outermost: [InlineSpan] = []
            for span in complete where !outermost.contains(where: {
                $0.range.location <= span.range.location
                    && NSMaxRange($0.range) >= NSMaxRange(span.range)
            }) {
                outermost.append(span)
            }
            for span in outermost {
                edits.removeAll { NSIntersectionRange($0, span.range).length > 0 }
                edits.append(span.range)
            }
        }

        edits = mergedRanges(edits)
        guard let first = edits.first else {
            setSelectedRange(NSRange(location: selection.location, length: 0))
            return
        }
        clearPendingInlineStyle()
        for range in edits.reversed() {
            super.insertText(range == first ? replacement : "", replacementRange: range)
        }
        setSelectedRange(NSRange(location: first.location + (replacement as NSString).length, length: 0))
    }

    /// Deletes one visible character; if it was the entire content of a
    /// span, the whole span goes with it (never leave an empty skeleton).
    private func deleteVisibleCharacter(_ charRange: NSRange, caretAfter: Int? = nil) {
        if let span = inlineSpans(around: charRange.location).first(where: { $0.content == charRange }) {
            insertText("", replacementRange: span.range)
            setSelectedRange(NSRange(location: min(caretAfter ?? span.range.location, span.range.location), length: 0))
        } else {
            insertText("", replacementRange: charRange)
            if let caretAfter {
                setSelectedRange(NSRange(location: min(caretAfter, charRange.location), length: 0))
            }
        }
    }

    // MARK: - Continuing inline styles at span edges

    /// Inline spans whose style continues when typing at their end:
    /// (regex, closing delimiter length; nil = length of capture group 1).
    private static let continuableSpans: [(NSRegularExpression, Int?)] = [
        (MarkdownHighlighter.boldItalicText, nil),
        (MarkdownHighlighter.boldText, nil),
        (MarkdownHighlighter.italicText, 1),
        (MarkdownHighlighter.inlineCode, 1),
        (MarkdownHighlighter.colorSpan, ("</span>" as NSString).length),
        (MarkdownHighlighter.halfOpacitySpan, ("</span>" as NSString).length),
    ]

    // Empty formatting commands are editor state, not empty Markdown
    // skeletons. The next visible text is serialized once it exists.
    private var pendingBold = false
    private var pendingItalic = false
    private var pendingCode = false

    private var hasPendingInlineStyle: Bool { pendingBold || pendingItalic || pendingCode }

    private func clearPendingInlineStyle() {
        pendingBold = false
        pendingItalic = false
        pendingCode = false
    }

    private func setPendingStyle(from span: EmphasisSpan) {
        pendingBold = span.bold
        pendingItalic = span.italic
        pendingCode = false
    }

    private func pendingDelimiter() -> String? {
        if pendingCode { return "`" }
        if pendingBold && pendingItalic { return "***" }
        if pendingBold { return "**" }
        if pendingItalic { return "*" }
        return nil
    }

    /// A style span whose visual end is represented by `caret`, whether the
    /// caret is before or after its concealed closing delimiter.
    private func emphasisEnding(at caret: Int) -> EmphasisSpan? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        return emphasisSpans(inLine: lineRange).first {
            NSMaxRange($0.content) == caret || NSMaxRange($0.range) == caret
        }
    }

    private func codeEnds(at caret: Int) -> Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        let local = NSRange(location: 0, length: (line as NSString).length)
        return MarkdownHighlighter.inlineCode.matches(in: line, range: local).contains { match in
            let start = lineRange.location + match.range.location
            let end = start + match.range.length
            return caret == end - 1 || caret == end
        }
    }

    private func pendingStyleMatchesSpanEnding(at caret: Int) -> Bool {
        if pendingCode { return codeEnds(at: caret) }
        guard let span = emphasisEnding(at: caret) else { return false }
        return span.bold == pendingBold && span.italic == pendingItalic
    }

    /// A caret just past a span's closing delimiter is visually at the end of
    /// the styled text (the markers are concealed), so typing there should
    /// continue the style: returns the position inside the delimiter(s).
    private func styleContinuationLocation(for caret: Int) -> Int {
        let ns = string as NSString
        var location = caret
        var moved = true
        while moved, location > 0, location <= ns.length {
            moved = false
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)
            let localCaret = location - lineRange.location
            for (regex, closeLength) in Self.continuableSpans where !moved {
                regex.enumerateMatches(in: line, range: local) { m, _, stop in
                    guard let m, NSMaxRange(m.range) == localCaret else { return }
                    location -= closeLength ?? m.range(at: 1).length
                    moved = true
                    stop.pointee = true
                }
            }
        }
        return location
    }

    // MARK: - Slash commands

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string
        // Typing at the end of a bold/italic/code/color span continues the
        // style. Whitespace stays outside: a trailing space inside the
        // delimiters would invalidate the markdown span.
        if replacementRange.location == NSNotFound, !hasMarkedText() {
            let sel = selectedRange()
            if sel.length == 0 {
                let isWhitespace = inserted?.allSatisfy { $0.isWhitespace } == true
                // Whitespace at the visible end belongs outside Markdown's
                // closing delimiter (trailing whitespace would invalidate
                // emphasis). Remember the style so the next word resumes it.
                if isWhitespace, let span = emphasisEnding(at: sel.location) {
                    setPendingStyle(from: span)
                    if sel.location != NSMaxRange(span.range) {
                        setSelectedRange(NSRange(location: NSMaxRange(span.range), length: 0))
                    }
                }
                if isWhitespace, pendingCode,
                   let span = inlineSpans(around: sel.location).first(where: {
                       NSMaxRange($0.content) == sel.location || NSMaxRange($0.range) == sel.location
                   }) {
                    if sel.location != NSMaxRange(span.range) {
                        setSelectedRange(NSRange(location: NSMaxRange(span.range), length: 0))
                    }
                }
                // A formatting command at an empty caret creates no raw
                // markers. Materialize a balanced span around the first
                // non-whitespace input, leaving its caret inside the closer.
                if !isWhitespace, hasPendingInlineStyle,
                   !pendingStyleMatchesSpanEnding(at: selectedRange().location), let inserted,
                   let delimiter = pendingDelimiter() {
                    var caret = selectedRange().location
                    // A style toggle at the end of an existing run begins a
                    // new run; never mutate the already-authored characters.
                    if let span = emphasisEnding(at: caret) {
                        caret = NSMaxRange(span.range)
                        setSelectedRange(NSRange(location: caret, length: 0))
                    }
                    let replacement = delimiter + inserted + delimiter
                    super.insertText(replacement, replacementRange: NSRange(location: caret, length: 0))
                    setSelectedRange(NSRange(location: caret + (delimiter as NSString).length
                                             + (inserted as NSString).length, length: 0))
                    return
                }
                if let first = inserted?.first, !first.isWhitespace {
                    let inside = styleContinuationLocation(for: sel.location)
                    if inside != sel.location {
                        setSelectedRange(NSRange(location: inside, length: 0))
                    }
                }
                // A caret at a span's visual start is just after the opening
                // concealed markers; typing there belongs BEFORE the span
                // (space before `code`, not ` code` inside it).
                let caret = selectedRange().location
                if caret == sel.location,
                   let span = inlineSpans(around: caret).first(where: {
                       $0.content.location == caret && $0.range.location < caret
                   }) {
                    setSelectedRange(NSRange(location: span.range.location, length: 0))
                }
            } else {
                // Interpret the selection on the rendered layer. Hidden
                // syntax may lie inside its raw offsets but is not selected.
                if let inserted {
                    replaceVisibleSelection(with: inserted, deleting: false)
                    return
                }
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        if referencesEnabled, referenceCandidates != nil, !hasMarkedText() {
            let caret = selectedRange().location
            let ns = self.string as NSString
            if inserted == "@", caret > 0,
               caret == 1 || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: caret - 2)) ?? " ") {
                referenceTrigger = "@"
                referenceRange = NSRange(location: caret - 1, length: 1)
                updateReferences()
            } else if inserted == "[", caret >= 2,
                      ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[[" {
                referenceTrigger = "[["
                referenceRange = NSRange(location: caret - 2, length: 2)
                updateReferences()
            }
        }
        guard inserted == "/" else { return }
        let ns = self.string as NSString
        let caret = selectedRange().location
        guard caret > 0 else { return }
        let lineRange = ns.lineRange(for: NSRange(location: caret - 1, length: 0))
        let prefix = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        if prefix.trimmingCharacters(in: .whitespaces) == "/" {
            showSlashMenu(slashRange: NSRange(location: caret - 1, length: 1))
        }
    }

    private struct SlashCommand {
        let title: String
        let snippet: String
        /// Caret offset within the snippet after insertion; nil = end.
        let caretOffset: Int?
    }

    private static let slashCommands: [SlashCommand?] = [
        SlashCommand(title: "# Heading 1", snippet: "# ", caretOffset: nil),
        SlashCommand(title: "## Heading 2", snippet: "## ", caretOffset: nil),
        SlashCommand(title: "### Heading 3", snippet: "### ", caretOffset: nil),
        nil,
        SlashCommand(title: "- Bullet list", snippet: "- ", caretOffset: nil),
        SlashCommand(title: "1. Numbered list", snippet: "1. ", caretOffset: nil),
        SlashCommand(title: "[ ] Task", snippet: "- [ ] ", caretOffset: nil),
        nil,
        SlashCommand(title: "> Quote", snippet: "> ", caretOffset: nil),
        SlashCommand(title: "``` Code block", snippet: "```\n\n```", caretOffset: 4),
        SlashCommand(title: "--- Divider", snippet: "---\n", caretOffset: nil),
    ]

    private var pendingSlashRange: NSRange?

    private func showSlashMenu(slashRange: NSRange) {
        pendingSlashRange = slashRange
        let menu = NSMenu()
        menu.font = Theme.interfaceFont(size: 13)
        for (index, command) in Self.slashCommands.enumerated() {
            guard let command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: command.title, action: #selector(applySlashCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        guard let window else { return }
        let screenRect = firstRect(forCharacterRange: slashRange, actualRange: nil)
        let local = convert(window.convertFromScreen(screenRect), from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: local.minX, y: local.maxY + 4), in: self)
    }

    @objc private func applySlashCommand(_ sender: NSMenuItem) {
        guard let range = pendingSlashRange,
              let command = Self.slashCommands[sender.tag] else { return }
        pendingSlashRange = nil
        insertText(command.snippet, replacementRange: range)
        if let offset = command.caretOffset {
            setSelectedRange(NSRange(location: range.location + offset, length: 0))
        }
    }

    // MARK: - List continuation

    /// A visual caret at the first/last character of an inline span may be
    /// represented inside its concealed opener/closer in the raw source.
    /// Paragraph breaks belong outside every wrapper sharing that visual
    /// edge, otherwise `*\ntext*` exposes a dangling delimiter.
    private func moveCaretOutsideInlineBoundaryForBreak() {
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        rehighlight()
        let spans = inlineSpans(around: sel.location)
        let atStart = spans.filter { span in
            visibleSourceRanges(in: span.content).first?.location == sel.location
        }
        if let location = atStart.map(\.range.location).min() {
            setSelectedRange(NSRange(location: location, length: 0))
            return
        }
        let atEnd = spans.filter { span in
            visibleSourceRanges(in: span.content).last.map(NSMaxRange) == sel.location
        }
        if let location = atEnd.map({ NSMaxRange($0.range) }).max() {
            setSelectedRange(NSRange(location: location, length: 0))
        }
    }

    private static let taskMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]\[[ xX]\][ \t]"#)
    private static let bulletMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]"#)
    private static let orderedMarker = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])[ \t]"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^(\s*)>[ \t]?"#)
    private static let headingMarker = try! NSRegularExpression(pattern: #"^\s*#{1,6}[ \t]"#)
    private static let anyListMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])[ \t]"#)

    override func insertNewline(_ sender: Any?) {
        clearPendingInlineStyle()
        moveCaretOutsideInlineBoundaryForBreak()
        let sel = selectedRange()
        let ns = string as NSString
        guard sel.length == 0, sel.location <= ns.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        let lineNS = line as NSString
        let localRange = NSRange(location: 0, length: lineNS.length)

        var continuation: String?
        var markerLength = 0

        if let m = Self.taskMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + lineNS.substring(with: m.range(at: 2)) + " [ ] "
        } else if let m = Self.bulletMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + lineNS.substring(with: m.range(at: 2)) + " "
        } else if let m = Self.orderedMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            let next = (Int(lineNS.substring(with: m.range(at: 2))) ?? 0) + 1
            continuation = lineNS.substring(with: m.range(at: 1)) + "\(next)" + lineNS.substring(with: m.range(at: 3)) + " "
        } else if let m = Self.quoteMarker.firstMatch(in: line, range: localRange) {
            markerLength = m.range.length
            continuation = lineNS.substring(with: m.range(at: 1)) + "> "
        }

        guard let continuation, sel.location - lineRange.location >= markerLength else {
            super.insertNewline(sender)
            return
        }

        let content = lineNS.substring(from: markerLength).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Empty list item: Enter exits the list by clearing the marker.
            insertText("", replacementRange: NSRange(location: lineRange.location, length: lineNS.length))
        } else {
            insertText("\n" + continuation, replacementRange: sel)
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let lineRange = listLineRange() else {
            super.insertTab(sender)
            return
        }
        insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        guard let lineRange = listLineRange() else {
            super.insertBacktab(sender)
            return
        }
        let ns = string as NSString
        let line = ns.substring(with: lineRange)
        let removable = line.prefix(2).prefix(while: { $0 == " " }).count
        if removable > 0 {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: removable))
        }
    }

    private func listLineRange() -> NSRange? {
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let match = Self.anyListMarker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        return match != nil ? lineRange : nil
    }

    // MARK: - Inline formatting

    @objc func toggleBoldMD(_ sender: Any?) { toggleInline("**") }
    @objc func toggleItalicMD(_ sender: Any?) { toggleInline("*") }
    @objc func toggleCodeMD(_ sender: Any?) { toggleInline("`") }

    /// Trims surrounding whitespace/newlines out of a range: a triple-clicked
    /// line includes its trailing newline, which would put a closing
    /// delimiter on the next line.
    private func trimmedToContent(_ range: NSRange) -> NSRange {
        let ns = string as NSString
        var sel = range
        let whitespace = CharacterSet.whitespacesAndNewlines
        while sel.length > 0,
              let scalar = Unicode.Scalar(ns.character(at: sel.location)),
              whitespace.contains(scalar) {
            sel.location += 1
            sel.length -= 1
        }
        while sel.length > 0,
              let scalar = Unicode.Scalar(ns.character(at: NSMaxRange(sel) - 1)),
              whitespace.contains(scalar) {
            sel.length -= 1
        }
        return sel
    }

    // MARK: - Text color (serialized as inline HTML spans)

    private static let textStyleOpenTag = try! NSRegularExpression(
        pattern: #"<span style="(color:#[0-9A-Fa-f]{6}|opacity:0\.5)">"#)
    private static let colorCloseTag = "</span>"

    /// A single content character with the color of the innermost span that
    /// covers it. Tags themselves are not content, so they never survive a
    /// rewrite — the serializer emits fresh, balanced ones.
    private struct ColoredChar {
        let unit: unichar
        let location: Int
        var style: String?
    }

    private static func sameStyle(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.caseInsensitiveCompare(b) == .orderedSame
        default: return false
        }
    }

    /// Walks `range` tag by tag, returning its content characters tagged with
    /// the color in effect, plus the full range of each outermost span. A
    /// `</span>` with nothing open is treated as content so stray text is
    /// never silently eaten.
    private func colorScan(in range: NSRange) -> (chars: [ColoredChar], spans: [NSRange]) {
        let ns = string as NSString
        let closeLength = (Self.colorCloseTag as NSString).length
        var chars: [ColoredChar] = []
        var spans: [NSRange] = []
        var open: [(hex: String, start: Int)] = []
        var i = range.location
        let end = NSMaxRange(range)
        while i < end {
            let rest = NSRange(location: i, length: end - i)
            if let m = Self.textStyleOpenTag.firstMatch(in: string, options: .anchored, range: rest) {
                open.append((ns.substring(with: m.range(at: 1)), i))
                i = NSMaxRange(m.range)
                continue
            }
            if !open.isEmpty, i + closeLength <= end,
               ns.substring(with: NSRange(location: i, length: closeLength)) == Self.colorCloseTag {
                let span = open.removeLast()
                if open.isEmpty {
                    spans.append(NSRange(location: span.start, length: i + closeLength - span.start))
                }
                i += closeLength
                continue
            }
            chars.append(ColoredChar(unit: ns.character(at: i), location: i, style: open.last?.hex))
            i += 1
        }
        return (chars, spans)
    }

    /// Paints the selection `hex`, replacing whatever colors it already
    /// carries; reapplying the color it uniformly carries strips it instead.
    ///
    /// The selection is flattened rather than wrapped: wrapping a mixed or
    /// half-covered stretch of text nests spans inside spans (or splits a
    /// tag down the middle), and the highlighter, which matches one span at
    /// a time, then renders the leftover tags as literal text.
    func applyColor(hex: String) {
        applyTextStyle("color:#\(hex)")
    }

    func applyHalfOpacity() {
        applyTextStyle("opacity:0.5")
    }

    /// Splits a visual selection into independently formattable paragraph
    /// ranges. Block syntax belongs to the paragraph rather than its text,
    /// so list, quote, and heading prefixes are deliberately excluded. The
    /// first and last ranges retain the exact partial selection boundaries.
    private func inlineStyleTargets(in selection: NSRange) -> [NSRange] {
        let originalSelection = trimmedToContent(selection)
        guard originalSelection.length > 0 else { return [] }
        let ns = string as NSString
        let paragraphs = ns.paragraphRange(for: originalSelection)
        var targets: [NSRange] = []
        var location = paragraphs.location
        while location < NSMaxRange(paragraphs) {
            let lineRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let intersection = NSIntersectionRange(originalSelection, lineRange)
            if intersection.length > 0 {
                let line = ns.substring(with: lineRange)
                let local = NSRange(location: 0, length: (line as NSString).length)
                let prefix = Self.taskMarker.firstMatch(in: line, range: local)
                    ?? Self.bulletMarker.firstMatch(in: line, range: local)
                    ?? Self.orderedMarker.firstMatch(in: line, range: local)
                    ?? Self.quoteMarker.firstMatch(in: line, range: local)
                    ?? Self.headingMarker.firstMatch(in: line, range: local)
                let contentStart = lineRange.location + (prefix.map { NSMaxRange($0.range) } ?? 0)
                let start = max(intersection.location, contentStart)
                let end = NSMaxRange(intersection)
                if end > start {
                    let target = trimmedToContent(NSRange(location: start, length: end - start))
                    if target.length > 0 { targets.append(target) }
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        return targets
    }

    /// Applies an inline operation to each selected paragraph from bottom to
    /// top, keeping earlier raw ranges stable while Markdown delimiters are
    /// inserted or removed on later lines.
    private func applyToInlineStyleTargets(
        selection: NSRange,
        operation: (NSRange) -> Void
    ) {
        let originalSelection = trimmedToContent(selection)
        let targets = inlineStyleTargets(in: originalSelection)
        guard !targets.isEmpty else { return }

        var totalDelta = 0
        for target in targets.reversed() {
            let before = (string as NSString).length
            operation(target)
            totalDelta += (string as NSString).length - before
        }
        let finalStart = targets.first!.location
        let finalEnd = min((string as NSString).length,
                           NSMaxRange(originalSelection) + totalDelta)
        setSelectedRange(NSRange(location: finalStart, length: max(0, finalEnd - finalStart)))
    }

    private func applyTextStyle(_ style: String) {
        let selection = selectedRange()
        applyToInlineStyleTargets(selection: selection) { target in
            setSelectedRange(target)
            applyTextStyleToSelection(style)
        }
    }

    private func applyTextStyleToSelection(_ style: String) {
        let ns = string as NSString
        let sel = trimmedToContent(selectedRange())
        guard sel.length > 0 else { return }

        // Spans never cross a blank line in practice, so the paragraphs the
        // selection touches are enough context to re-serialize from.
        let (chars, spans) = colorScan(in: ns.paragraphRange(for: sel))

        // Rewrite the selection plus any span it only partly covers, so the
        // uncovered remainder keeps its own color under a tag of its own.
        var start = sel.location
        var end = NSMaxRange(sel)
        for span in spans where NSIntersectionRange(span, sel).length > 0 {
            start = min(start, span.location)
            end = max(end, NSMaxRange(span))
        }
        let region = NSRange(location: start, length: end - start)

        var painted = chars.filter { $0.location >= start && $0.location < end }
        let covered = painted.indices.filter { NSLocationInRange(painted[$0].location, sel) }
        guard !covered.isEmpty else { return }
        let uniform = covered.allSatisfy { Self.sameStyle(painted[$0].style, style) }
        for i in covered { painted[i].style = uniform ? nil : style }

        var units: [unichar] = []
        func emit(_ text: String) { units.append(contentsOf: text.utf16) }
        var current: String?
        var selStart = 0, selEnd = 0
        for (i, c) in painted.enumerated() {
            if !Self.sameStyle(c.style, current) {
                if current != nil { emit(Self.colorCloseTag) }
                if let style = c.style { emit("<span style=\"\(style)\">") }
                current = c.style
            }
            if i == covered.first { selStart = units.count }
            units.append(c.unit)
            if i == covered.last { selEnd = units.count }
        }
        if current != nil { emit(Self.colorCloseTag) }

        insertText(String(utf16CodeUnits: units, count: units.count), replacementRange: region)
        setSelectedRange(NSRange(location: region.location + selStart, length: selEnd - selStart))
    }

    /// An emphasis span on one line: full range including delimiters, inner
    /// content, and which style layers it carries.
    private struct EmphasisSpan {
        let range: NSRange
        let content: NSRange
        let bold: Bool
        let italic: Bool
    }

    private func emphasisSpans(inLine lineRange: NSRange) -> [EmphasisSpan] {
        let ns = string as NSString
        let line = ns.substring(with: lineRange)
        let local = NSRange(location: 0, length: (line as NSString).length)
        func global(_ r: NSRange) -> NSRange {
            NSRange(location: lineRange.location + r.location, length: r.length)
        }
        var spans: [EmphasisSpan] = []
        var boldMarkerRanges: [NSRange] = []
        MarkdownHighlighter.boldItalicText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            spans.append(EmphasisSpan(range: global(m.range), content: global(m.range(at: 2)),
                                      bold: true, italic: true))
        }
        MarkdownHighlighter.boldText.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            let r = global(m.range)
            guard !spans.contains(where: { $0.bold && $0.italic && NSIntersectionRange($0.range, r).length > 0 }) else { return }
            let content = m.range(at: 2)
            boldMarkerRanges.append(NSRange(location: m.range.location,
                                             length: content.location - m.range.location))
            boldMarkerRanges.append(NSRange(location: NSMaxRange(content),
                                             length: NSMaxRange(m.range) - NSMaxRange(content)))
            spans.append(EmphasisSpan(range: r, content: global(content), bold: true, italic: false))
        }
        for m in MarkdownHighlighter.validItalicMatches(in: line, range: local,
                                                         blockedByBoldMarkers: boldMarkerRanges) {
            let r = global(m.range)
            guard !spans.contains(where: { $0.bold && $0.italic && NSIntersectionRange($0.range, r).length > 0 }) else { continue }
            spans.append(EmphasisSpan(range: r, content: global(m.range(at: 2)), bold: false, italic: true))
        }
        return spans
    }

    /// Layer-aware bold/italic toggling: `*`, `**`, and `***` are treated as
    /// independent style layers on the same text, not opaque characters, so
    /// bolding an italicized word gives `***word***` and toggling one layer
    /// off a combined span leaves the other intact. Returns false when the
    /// selection touches no emphasis span (the caller then wraps naively).
    private func toggleEmphasis(bold: Bool, selection sel: NSRange) -> Bool {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= NSMaxRange(lineRange) else { return false }
        let spans = emphasisSpans(inLine: lineRange)

        // A span containing the selection: toggle its layer. A zero-length
        // caret must be strictly inside (a caret at the boundary is "next to"
        // the span, not on it). Prefer a span that has the layer being
        // toggled (unwrap beats promote), innermost first.
        let containing = spans.filter { span in
            sel.location >= span.range.location && NSMaxRange(sel) <= NSMaxRange(span.range)
                && (sel.length > 0 || (sel.location > span.range.location && sel.location < NSMaxRange(span.range)))
        }.sorted { $0.range.length < $1.range.length }
        if let span = containing.first(where: { bold ? $0.bold : $0.italic }) ?? containing.first {
            let hasLayer = bold ? span.bold : span.italic
            let content = ns.substring(with: span.content)
            let newDelimiter: String
            if hasLayer {
                // Remove this layer, keeping the other if present.
                newDelimiter = (bold ? span.italic : span.bold) ? (bold ? "*" : "**") : ""
            } else {
                // Adding a layer rewrites the whole span, so only do it when
                // the selection means the whole span; a sub-range selection
                // falls back to wrapping just that range.
                let coversContent = sel.location <= span.content.location
                    && NSMaxRange(sel) >= NSMaxRange(span.content)
                guard sel.length == 0 || coversContent else { return false }
                newDelimiter = "***"
            }
            insertText(newDelimiter + content + newDelimiter, replacementRange: span.range)
            setSelectedRange(NSRange(location: span.range.location + (newDelimiter as NSString).length,
                                     length: (content as NSString).length))
            return true
        }

        // The selection reaches beyond span boundaries: grow it to whole
        // spans, strip this layer from every span inside, and wrap the lot —
        // Word-style "make the whole selection bold".
        let touching = spans.filter { NSIntersectionRange($0.range, sel).length > 0 }
        guard !touching.isEmpty else { return false }
        var grown = sel
        for span in touching { grown = NSUnionRange(grown, span.range) }
        let rebuilt = NSMutableString(string: ns.substring(with: grown))
        let stripped = spans
            .filter { $0.range.location >= grown.location && NSMaxRange($0.range) <= NSMaxRange(grown) }
            .filter { bold ? $0.bold : $0.italic }
        for span in stripped.sorted(by: { $0.range.location > $1.range.location }) {
            let keep = (bold ? span.italic : span.bold) ? (bold ? "*" : "**") : ""
            let local = NSRange(location: span.range.location - grown.location, length: span.range.length)
            rebuilt.replaceCharacters(in: local, with: keep + ns.substring(with: span.content) + keep)
        }
        let delimiter = bold ? "**" : "*"
        insertText(delimiter + (rebuilt as String) + delimiter, replacementRange: grown)
        setSelectedRange(NSRange(location: grown.location + (delimiter as NSString).length,
                                 length: rebuilt.length))
        return true
    }

    /// Span-aware inline-code toggling, mirroring the emphasis behavior:
    /// a caret or selection inside a `code` span unwraps it; a selection
    /// crossing span boundaries grows to whole spans, merges their contents,
    /// and wraps the lot. Returns false when no span is involved (the caller
    /// then wraps naively).
    private func toggleCodeSpan(selection sel: NSRange) -> Bool {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard NSMaxRange(sel) <= NSMaxRange(lineRange) else { return false }
        let line = ns.substring(with: lineRange)
        let local = NSRange(location: 0, length: (line as NSString).length)
        var spans: [(range: NSRange, content: NSRange)] = []
        MarkdownHighlighter.inlineCode.enumerateMatches(in: line, range: local) { m, _, _ in
            guard let m else { return }
            let r = NSRange(location: lineRange.location + m.range.location, length: m.range.length)
            spans.append((r, NSRange(location: r.location + 1, length: r.length - 2)))
        }

        let containing = spans.first { span in
            sel.location >= span.range.location && NSMaxRange(sel) <= NSMaxRange(span.range)
                && (sel.length > 0 || (sel.location > span.range.location && sel.location < NSMaxRange(span.range)))
        }
        if let span = containing {
            let content = ns.substring(with: span.content)
            insertText(content, replacementRange: span.range)
            setSelectedRange(NSRange(location: span.range.location, length: (content as NSString).length))
            return true
        }

        let touching = spans.filter { NSIntersectionRange($0.range, sel).length > 0 }
        guard !touching.isEmpty else { return false }
        var grown = sel
        for span in touching { grown = NSUnionRange(grown, span.range) }
        let rebuilt = NSMutableString(string: ns.substring(with: grown))
        for span in touching.sorted(by: { $0.range.location > $1.range.location }) {
            let local = NSRange(location: span.range.location - grown.location, length: span.range.length)
            rebuilt.replaceCharacters(in: local, with: ns.substring(with: span.content))
        }
        insertText("`" + (rebuilt as String) + "`", replacementRange: grown)
        setSelectedRange(NSRange(location: grown.location + 1, length: rebuilt.length))
        return true
    }

    private func toggleInline(_ delimiter: String) {
        let ns = string as NSString
        var sel = selectedRange()

        if sel.length == 0, hasPendingInlineStyle {
            if delimiter == "**" { pendingBold.toggle(); pendingCode = false }
            else if delimiter == "*" { pendingItalic.toggle(); pendingCode = false }
            else if delimiter == "`" {
                let enable = !pendingCode
                clearPendingInlineStyle()
                pendingCode = enable
            }
            return
        }

        if sel.length == 0 {
            let word = selectionRange(forProposedRange: sel, granularity: .selectByWord)
            let wordText = ns.substring(with: word)
            if !wordText.isEmpty,
               wordText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
                sel = word
            }
        }

        sel = trimmedToContent(sel)

        // A caret on whitespace has no word to format. Enter a Word-like
        // typing mode without inserting an invalid empty Markdown span.
        if sel.length == 0 {
            if delimiter == "**" { pendingBold.toggle(); pendingCode = false }
            else if delimiter == "*" { pendingItalic.toggle(); pendingCode = false }
            else if delimiter == "`" { pendingCode.toggle(); pendingBold = false; pendingItalic = false }
            return
        }

        let targets = inlineStyleTargets(in: sel)
        if targets.count > 1 || targets.first != sel {
            applyToInlineStyleTargets(selection: sel) { target in
                toggleInline(delimiter, selection: target)
            }
            return
        }

        toggleInline(delimiter, selection: sel)
    }

    private func toggleInline(_ delimiter: String, selection sel: NSRange) {
        let ns = string as NSString
        let dLen = (delimiter as NSString).length

        if delimiter == "**" || delimiter == "*" {
            if toggleEmphasis(bold: delimiter == "**", selection: sel) { return }
        }
        if delimiter == "`" {
            if toggleCodeSpan(selection: sel) { return }
        }

        let selected = ns.substring(with: sel)

        if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter), (selected as NSString).length >= 2 * dLen {
            // Selection includes the delimiters: unwrap.
            let inner = (selected as NSString).substring(with: NSRange(location: dLen, length: (selected as NSString).length - 2 * dLen))
            insertText(inner, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location, length: (inner as NSString).length))
        } else if sel.location >= dLen,
                  NSMaxRange(sel) + dLen <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - dLen, length: dLen)) == delimiter,
                  ns.substring(with: NSRange(location: NSMaxRange(sel), length: dLen)) == delimiter {
            // Delimiters surround the selection: unwrap.
            let outer = NSRange(location: sel.location - dLen, length: sel.length + 2 * dLen)
            insertText(selected, replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: sel.length))
        } else {
            insertText(delimiter + selected + delimiter, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + dLen, length: sel.length))
        }
    }

    /// All fence lines in the document, in order.
    private func fenceLineRanges() -> [NSRange] {
        let ns = string as NSString
        var result: [NSRange] = []
        var position = 0
        while position < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: position, length: 0))
            let line = ns.substring(with: lineRange)
            if MarkdownHighlighter.fence.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                result.append(lineRange)
            }
            position = NSMaxRange(lineRange)
        }
        return result
    }

    /// Wraps the selected paragraphs in a fenced code block, or unwraps the
    /// block the selection is inside (or has selected, fences included).
    @objc func toggleCodeBlockMD(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let paragraphs = ns.paragraphRange(for: sel)
        let fences = fenceLineRanges()
        let above = fences.filter { NSMaxRange($0) <= paragraphs.location }
        let intersecting = fences.filter { NSIntersectionRange($0, paragraphs).length > 0 }

        func removeFences(open: NSRange, close: NSRange?) {
            if let close { insertText("", replacementRange: close) }
            insertText("", replacementRange: open)
            setSelectedRange(NSRange(location: min(open.location, (string as NSString).length), length: 0))
        }

        if above.count % 2 == 1 {
            // Selection is inside a block: remove its enclosing fences.
            let open = above.last!
            let close = fences.first { $0.location >= paragraphs.location && NSIntersectionRange($0, open).length == 0 }
            removeFences(open: open, close: close)
            return
        }
        if let open = intersecting.first {
            // Selection covers the block, fences included.
            let close = fences.first { $0.location > open.location }
            removeFences(open: open, close: close)
            return
        }

        let insertEnd = NSMaxRange(paragraphs)
        let endsWithNewline = insertEnd > paragraphs.location && ns.character(at: insertEnd - 1) == 0x0A
        insertText(endsWithNewline ? "```\n" : "\n```", replacementRange: NSRange(location: insertEnd, length: 0))
        insertText("```\n", replacementRange: NSRange(location: paragraphs.location, length: 0))
        setSelectedRange(NSRange(location: paragraphs.location + 4, length: paragraphs.length))
    }

    @objc func insertLinkMD(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let selected = ns.substring(with: sel)
        insertText("[\(selected)]()", replacementRange: sel)
        if selected.isEmpty {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        } else {
            setSelectedRange(NSRange(location: sel.location + sel.length + 3, length: 0))
        }
    }

    @objc func setHeading(_ sender: NSMenuItem) {
        let level = sender.tag
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let existing = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]"#)
        let localRange = NSRange(location: 0, length: (line as NSString).length)

        var stripLength = 0
        var currentLevel = 0
        if let m = existing.firstMatch(in: line, range: localRange) {
            stripLength = m.range.length
            currentLevel = m.range(at: 1).length
        }
        let newPrefix = (level > 0 && level != currentLevel) ? String(repeating: "#", count: level) + " " : ""
        insertText(newPrefix, replacementRange: NSRange(location: lineRange.location, length: stripLength))
    }

    // MARK: - Paste as plain text

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}
