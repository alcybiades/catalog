import AppKit

/// Tables wider than the page scroll sideways within their frame: a
/// horizontal swipe (or Shift-scroll) over one moves its columns, and the
/// caret entering a hidden cell brings it into view. The offset shifts the
/// rows' line fragments (`setLineFragmentRect`), so clicks, the caret and
/// selection land where the text shows; drawing clips to the frame.
extension CodeBackgroundLayoutManager {
    /// The table (its whole extent and block) whose rows include `charIndex`.
    func tableBlock(at charIndex: Int) -> (range: NSRange, block: TableBlock)? {
        guard let textStorage, charIndex >= 0, charIndex < textStorage.length else { return nil }
        var range = NSRange()
        guard let block = textStorage.attribute(.mdTable, at: charIndex, longestEffectiveRange: &range,
                                                in: NSRange(location: 0, length: textStorage.length)) as? TableBlock
        else { return nil }
        return (range, block)
    }

    func tableOffset(at blockLocation: Int, in storage: NSTextStorage) -> CGFloat {
        tableOffsets[ObjectIdentifier(storage)]?[blockLocation] ?? 0
    }

    func tableOffset(forGlyphAt glyph: Int) -> CGFloat {
        guard let textStorage, let offsets = tableOffsets[ObjectIdentifier(textStorage)], !offsets.isEmpty,
              glyph < numberOfGlyphs,
              let table = tableBlock(at: characterIndexForGlyph(at: glyph)) else { return 0 }
        return offsets[table.range.location] ?? 0
    }

    /// The width of the table's visible window, and how far it can scroll.
    func tableScrollLimits(_ block: TableBlock) -> (view: CGFloat, maxOffset: CGFloat)? {
        guard let container = textContainers.first, let width = block.edges.last, block.edges.count > 1 else { return nil }
        let view = container.size.width - 2 * container.lineFragmentPadding - block.baseIndent - block.tailInset
        guard view > 4 else { return nil }
        return (view, max(0, width - view))
    }

    /// Scrolls the table to `offset` (clamped); true when it can scroll at all.
    @discardableResult
    func setTableOffset(_ offset: CGFloat, forTableAt charIndex: Int) -> Bool {
        guard let textStorage, let table = tableBlock(at: charIndex),
              let limits = tableScrollLimits(table.block), limits.maxOffset > 0.5 else { return false }
        let key = ObjectIdentifier(textStorage)
        let clamped = min(max(offset, 0), limits.maxOffset).rounded()
        let current = tableOffsets[key]?[table.range.location] ?? 0
        guard clamped != current else { return true }
        tableOffsets[key, default: [:]][table.range.location] = clamped == 0 ? nil : clamped
        invalidateLayout(forCharacterRange: table.range, actualCharacterRange: nil)
        invalidateDisplay(forCharacterRange: table.range)
        for view in textContainers.compactMap(\.textView) { view.needsDisplay = true }
        return true
    }

    /// Keeps offsets with their tables as text before them changes length.
    func shiftTableOffsets(in storage: NSTextStorage, edited range: NSRange, delta: Int) {
        let key = ObjectIdentifier(storage)
        guard delta != 0, let offsets = tableOffsets[key], !offsets.isEmpty else { return }
        let oldEnd = NSMaxRange(range) - delta
        var shifted: [Int: CGFloat] = [:]
        for (location, offset) in offsets {
            if location >= oldEnd { shifted[location + delta] = offset }
            else if location < range.location || location < NSMaxRange(range) { shifted[location] = offset }
        }
        tableOffsets[key] = shifted
    }

    /// Draws `glyphs` with each table's part clipped to its visible window.
    func drawClippingTables(_ glyphs: NSRange, at origin: NSPoint, draw: (NSRange) -> Void) {
        guard let textStorage, let container = textContainers.first, glyphs.length > 0 else { draw(glyphs); return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var tables: [(glyphs: NSRange, clip: NSRect)] = []
        var seen = Set<Int>()
        textStorage.enumerateAttribute(.mdTable, in: chars) { value, range, _ in
            guard value is TableBlock, let table = tableBlock(at: range.location),
                  seen.insert(table.range.location).inserted,
                  let limits = tableScrollLimits(table.block) else { return }
            let tableGlyphs = NSIntersectionRange(glyphRange(forCharacterRange: table.range, actualCharacterRange: nil), glyphs)
            guard tableGlyphs.length > 0 else { return }
            var bounds = NSRect.null
            enumerateLineFragments(forGlyphRange: tableGlyphs) { rect, _, _, _, _ in bounds = bounds.union(rect) }
            guard !bounds.isNull else { return }
            let left = container.lineFragmentPadding + table.block.baseIndent
            let clip = NSRect(x: left + origin.x, y: bounds.minY + origin.y, width: limits.view, height: bounds.height)
            tables.append((tableGlyphs, clip))
        }
        guard !tables.isEmpty else { draw(glyphs); return }
        var cursor = glyphs.location
        for table in tables.sorted(by: { $0.glyphs.location < $1.glyphs.location }) {
            if table.glyphs.location > cursor { draw(NSRange(location: cursor, length: table.glyphs.location - cursor)) }
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: table.clip).addClip()
            draw(table.glyphs)
            NSGraphicsContext.current?.restoreGraphicsState()
            cursor = max(cursor, NSMaxRange(table.glyphs))
        }
        if cursor < NSMaxRange(glyphs) { draw(NSRange(location: cursor, length: NSMaxRange(glyphs) - cursor)) }
    }

    /// Whether a table under `point` (container coordinates) is wider than
    /// the page.
    func canScrollTable(at point: NSPoint) -> Bool {
        guard let container = textContainers.first, numberOfGlyphs > 0 else { return false }
        let glyph = glyphIndex(for: point, in: container)
        guard glyph < numberOfGlyphs,
              lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).insetBy(dx: 0, dy: -2).contains(point),
              let table = tableBlock(at: characterIndexForGlyph(at: glyph)),
              let limits = tableScrollLimits(table.block) else { return false }
        return limits.maxOffset > 0.5
    }

    /// Scrolls the table under `point` (container coordinates) by `delta`;
    /// true when there's a scrollable table there.
    func scrollTable(at point: NSPoint, by delta: CGFloat) -> Bool {
        guard let textStorage, let container = textContainers.first, numberOfGlyphs > 0 else { return false }
        let glyph = glyphIndex(for: point, in: container)
        guard glyph < numberOfGlyphs,
              lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).insetBy(dx: 0, dy: -2).contains(point) else { return false }
        let char = characterIndexForGlyph(at: glyph)
        guard let table = tableBlock(at: char) else { return false }
        return setTableOffset(tableOffset(at: table.range.location, in: textStorage) + delta, forTableAt: char)
    }

    /// Scrolls the table holding `charIndex` just enough to show it.
    func revealTableCharacter(_ charIndex: Int) {
        guard let textStorage, let container = textContainers.first, let table = tableBlock(at: charIndex),
              let limits = tableScrollLimits(table.block), limits.maxOffset > 0.5 else { return }
        let glyph = glyphIndexForCharacter(at: charIndex)
        guard glyph < numberOfGlyphs else { return }
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let offset = tableOffset(at: table.range.location, in: textStorage)
        // Unshifted, from the table's left edge.
        let x = fragment.minX + location(forGlyphAt: glyph).x + offset - container.lineFragmentPadding - table.block.baseIndent
        let margin: CGFloat = 24
        var target = offset
        if x < offset + margin { target = x - margin }
        else if x > offset + limits.view - margin { target = x - limits.view + margin }
        // Near either end, go all the way there.
        if target < margin { target = 0 } else if target > limits.maxOffset - margin { target = limits.maxOffset }
        if target != offset { setTableOffset(target, forTableAt: charIndex) }
    }
}

/// The note's clip view only ever scrolls vertically. The page has no
/// horizontal scroller, but AppKit still scrolls sideways to show a caret
/// or selection it thinks is offscreen, as a scrolled table's shifted rows
/// can be, which left the whole page stuck off to one side.
final class VerticalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }
}
