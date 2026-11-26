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
        guard !snapshotting, let textStorage, let container = textContainers.first, glyphs.length > 0 else { draw(glyphs); return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let hidden = hiddenTables[ObjectIdentifier(textStorage)] ?? []
        var tables: [(glyphs: NSRange, clip: NSRect, hidden: Bool)] = []
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
            tables.append((tableGlyphs, clip, hidden.contains(table.range.location)))
        }
        guard !tables.isEmpty else { draw(glyphs); return }
        var cursor = glyphs.location
        for table in tables.sorted(by: { $0.glyphs.location < $1.glyphs.location }) {
            if table.glyphs.location > cursor { draw(NSRange(location: cursor, length: table.glyphs.location - cursor)) }
            if !table.hidden {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: table.clip).addClip()
                draw(table.glyphs)
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            cursor = max(cursor, NSMaxRange(table.glyphs))
        }
        if cursor < NSMaxRange(glyphs) { draw(NSRange(location: cursor, length: NSMaxRange(glyphs) - cursor)) }
    }

    /// The whole table holding `charIndex` (every column, as scrolled to 0)
    /// drawn into an image, with its frame's top-left in text container
    /// coordinates, for sliding natively during a live scroll.
    func tableSnapshot(at charIndex: Int, scale: CGFloat, appearance: NSAppearance) -> (image: CGImage, size: NSSize)? {
        guard let textStorage, let container = textContainers.first, let table = tableBlock(at: charIndex),
              let width = table.block.edges.last else { return nil }
        let glyphs = glyphRange(forCharacterRange: table.range, actualCharacterRange: nil)
        var rows = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in rows = rows.union(rect) }
        guard !rows.isNull else { return nil }
        let top = rows.minY + table.block.topMargin
        let height = rows.maxY - table.block.bottomMargin - top
        let size = NSSize(width: ceil(width) + 2, height: ceil(height))
        guard height > 0, let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let offset = tableOffset(at: table.range.location, in: textStorage)
        // The rows lie shifted left by the offset; move them back to 0.
        let origin = NSPoint(x: offset - container.lineFragmentPadding - table.block.baseIndent, y: -top)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        snapshotting = true
        appearance.performAsCurrentDrawingAppearance {
            drawBackground(forGlyphRange: glyphs, at: origin)
            drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        snapshotting = false
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { return nil }
        return (image, size)
    }

    /// Hides or shows a table's text-view drawing (during a live scroll).
    func setTableHidden(_ hidden: Bool, at location: Int) {
        guard let textStorage, let table = tableBlock(at: location) else { return }
        let key = ObjectIdentifier(textStorage)
        if hidden { hiddenTables[key, default: []].insert(table.range.location) }
        else { hiddenTables[key]?.remove(table.range.location) }
        invalidateDisplay(forCharacterRange: table.range)
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

    /// Direct scrolls (`scroll(to:)`) skip the constraint; pin them too.
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
}

/// Each table wider than the page gets a horizontal scroll view laid over
/// its visible frame, as wide as the frame, holding an empty document as
/// wide as the table. AppKit then handles the swipe, its momentum and the
/// scroller natively, and the page never sees the sideways gesture; the
/// scroll position drives the table's offset in the layout manager, which
/// draws the text beneath. Clicks pass through to the text view, so cells
/// stay editable.
final class TableScrollers: NSObject, NSLayoutManagerDelegate {
    private weak var textView: NSTextView?
    private var views: [Int: TableScrollView] = [:]
    private var pending = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
    }

    /// Starts tracking layout; call once the layout manager is in place.
    func attach() {
        textView?.layoutManager?.delegate = self
        setNeedsUpdate()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        setNeedsUpdate()
    }

    func setNeedsUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.update()
        }
    }

    /// What the scroll views' placement depends on; a table scrolling
    /// changes none of it, so its ticks skip re-measuring the document.
    private struct Placement: Equatable {
        var storage: ObjectIdentifier
        var generation: Int
        var size: NSSize
        var inset: NSSize
    }
    private var placed: Placement?

    /// Places a scroll view over each wide table and drops the rest.
    func update() {
        guard let textView, let layout = textView.layoutManager as? CodeBackgroundLayoutManager,
              let storage = textView.textStorage, let container = textView.textContainer else {
            views.values.forEach { $0.removeFromSuperview() }
            views = [:]
            placed = nil
            return
        }
        let placement = Placement(storage: ObjectIdentifier(storage), generation: layout.editGeneration,
                                  size: textView.bounds.size, inset: textView.textContainerInset)
        if placement == placed {
            for (location, view) in views where !view.isLive { view.setOffset(layout.tableOffset(at: location, in: storage)) }
            return
        }
        placed = placement
        // The text changed under a live scroll: settle it before re-placing.
        views.values.filter(\.isLive).forEach { $0.endLiveScroll() }
        var frames: [Int: (frame: NSRect, width: CGFloat)] = [:]
        let all = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.mdTable, in: all) { value, range, _ in
            guard let block = value as? TableBlock, frames[range.location] == nil,
                  let table = layout.tableBlock(at: range.location), table.range.location == range.location,
                  let limits = layout.tableScrollLimits(table.block), limits.maxOffset > 0.5,
                  let width = block.edges.last else { return }
            let glyphs = layout.glyphRange(forCharacterRange: table.range, actualCharacterRange: nil)
            var bounds = NSRect.null
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in bounds = bounds.union(rect) }
            guard !bounds.isNull else { return }
            let origin = textView.textContainerOrigin
            let left = origin.x + container.lineFragmentPadding + table.block.baseIndent
            let top = bounds.minY + table.block.topMargin + origin.y
            let bottom = bounds.maxY - table.block.bottomMargin + origin.y
            guard bottom > top else { return }
            // The scroller sits just below the table's bottom rule, not on
            // its last row.
            let below = TableScrollView.scrollerHeight + 3
            frames[table.range.location] = (NSRect(x: left, y: top, width: limits.view, height: bottom - top + below), width)
        }
        for (location, view) in views where frames[location] == nil {
            layout.setTableHidden(false, at: location)
            view.removeFromSuperview()
            views[location] = nil
        }
        for (location, placement) in frames {
            let view = views[location] ?? {
                let view = TableScrollView(textView: textView)
                textView.addSubview(view)
                views[location] = view
                return view
            }()
            view.onScroll = { [weak self, weak layout] x in
                guard let layout, let key = self?.location(of: view) else { return }
                layout.setTableOffset(x, forTableAt: key)
            }
            // A swipe slides a snapshot of the whole table natively; the
            // text view's table hides meanwhile and catches up at the end.
            view.onLiveBegin = { [weak self, weak layout, weak textView] in
                guard let layout, let textView, let key = self?.location(of: view),
                      let snapshot = layout.tableSnapshot(at: key, scale: textView.window?.backingScaleFactor ?? 2,
                                                          appearance: textView.effectiveAppearance) else { return false }
                view.showSnapshot(snapshot.image, size: snapshot.size)
                // Diagnostics: the snapshot beside the scroll log.
                if AppState.isTesting, let log = ProcessInfo.processInfo.environment["CATALOG_SCROLL_LOG"],
                   let data = NSBitmapImageRep(cgImage: snapshot.image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: log + ".table.png"))
                }
                layout.setTableHidden(true, at: key)
                return true
            }
            view.onLiveEnd = { [weak self, weak layout, weak textView] x in
                guard let layout, let key = self?.location(of: view) else { view.removeSnapshot(); return }
                layout.setTableHidden(false, at: key)
                layout.setTableOffset(x, forTableAt: key)
                // Draw the settled table under the snapshot, then drop it.
                textView?.displayIfNeeded()
                DispatchQueue.main.async { view.removeSnapshot() }
            }
            if view.frame != placement.frame { view.frame = placement.frame }
            view.setContentWidth(placement.width)
            view.setOffset(layout.tableOffset(at: location, in: storage))
        }
    }

    private func location(of view: TableScrollView) -> Int? {
        views.first { $0.value === view }?.key
    }

    /// The scroll views, for tests.
    var scrollViews: [Int: NSScrollView] { views }
}

/// A horizontal scroll view over one table. Vertical gestures go on to the
/// page; mouse events go through to the text view beneath.
final class TableScrollView: NSScrollView {
    /// The overlay scroller's thickness, which hangs below the table.
    static let scrollerHeight = NSScroller.scrollerWidth(for: .small, scrollerStyle: .overlay)
    var onScroll: ((CGFloat) -> Void)?
    /// A swipe began: show a snapshot and stop driving the layout per tick
    /// (false when no snapshot could be made, so ticks drive it as before).
    var onLiveBegin: (() -> Bool)?
    /// The swipe and its momentum ended at this offset.
    var onLiveEnd: ((CGFloat) -> Void)?
    private(set) var isLive = false
    private var pendingEnd: DispatchWorkItem?
    private var snapshotView: NSView?
    private weak var textView: NSTextView?
    private var syncing = false
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        horizontalScroller?.controlSize = .small
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = PassThroughView(textView: textView)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContentWidth(_ width: CGFloat) {
        let size = NSSize(width: width, height: bounds.height)
        if documentView?.frame.size != size { documentView?.setFrameSize(size) }
    }

    func setOffset(_ x: CGFloat) {
        guard abs(contentView.bounds.origin.x - x) > 0.5 else { return }
        syncing = true
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
        syncing = false
    }

    @objc private func boundsChanged() {
        guard !syncing, !isLive else { return }
        onScroll?(contentView.bounds.origin.x)
    }

    private func beginLiveScroll() {
        guard !isLive else { return }
        isLive = onLiveBegin?() ?? false
    }

    func endLiveScroll() {
        pendingEnd?.cancel()
        pendingEnd = nil
        guard isLive else { return }
        isLive = false
        onLiveEnd?(contentView.bounds.origin.x)
    }

    func showSnapshot(_ image: CGImage, size: NSSize) {
        removeSnapshot()
        let view = SnapshotView(frame: NSRect(origin: .zero, size: size))
        view.layer?.contents = image
        documentView?.addSubview(view)
        snapshotView = view
    }

    func removeSnapshot() {
        snapshotView?.removeFromSuperview()
        snapshotView = nil
    }

    /// A gesture's first movement picks its axis: sideways scrolls the
    /// table, anything else scrolls the page. Both see it begin and end.
    override func scrollWheel(with event: NSEvent) {
        let page = textView?.enclosingScrollView
        let discrete = event.phase == [] && event.momentumPhase == []
        if discrete || event.phase == .began || event.phase == .mayBegin { axis = .undecided }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if axis == .undecided, dx != 0 || dy != 0 { axis = abs(dx) > abs(dy) ? .horizontal : .vertical }
        if axis == .horizontal, !discrete {
            if event.phase == .began || event.phase == .changed { beginLiveScroll() }
            // Momentum follows the lift-off almost at once if it's coming.
            if event.momentumPhase == .began { pendingEnd?.cancel(); pendingEnd = nil }
        }
        switch axis {
        case .horizontal: super.scrollWheel(with: event)
        case .vertical: page?.scrollWheel(with: event)
        case .undecided:
            super.scrollWheel(with: event)
            page?.scrollWheel(with: event)
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled || event.phase == .cancelled {
            endLiveScroll()
        } else if event.phase == .ended, isLive {
            let end = DispatchWorkItem { [weak self] in self?.endLiveScroll() }
            pendingEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: end)
        }
        if discrete || event.momentumPhase == .ended || event.momentumPhase == .cancelled { axis = .undecided }
    }
}

/// A table's snapshot, sliding with the scroll view's document during a
/// live scroll; clicks fall through to the document beneath.
private final class SnapshotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The table scroll view's document: transparent, sending clicks, drags
/// and context menus to the text view beneath, with the text cursor.
private final class PassThroughView: NSView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
    private weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { textView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { textView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { textView?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { textView?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { textView?.otherMouseDown(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { textView?.menu(for: event) }
    override func pressureChange(with event: NSEvent) { textView?.pressureChange(with: event) }
}
