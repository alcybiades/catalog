import AppKit

/// Watches one file for writes from anything else (the assistant's CLIs,
/// another app), surviving atomic saves that replace the file.
final class FileWatcher {
    let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var rearm: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm(attempts: 0)
    }

    deinit {
        debounce?.cancel()
        rearm?.cancel()
        source?.cancel()
    }

    private func arm(attempts: Int) {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-replace, or gone: look again shortly, for a while.
            guard attempts < 40 else { return }
            let retry = DispatchWorkItem { [weak self] in self?.arm(attempts: attempts + 1) }
            rearm = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: retry)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
                // An atomic save swapped in a new file: follow the path.
                let retry = DispatchWorkItem { [weak self] in self?.arm(attempts: 0) }
                rearm = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: retry)
            }
            changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        // Anything written while unwatched still counts.
        if attempts > 0 { changed() }
    }

    /// Writes arrive in bursts (truncate, then write): settle first.
    private func changed() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

/// Plays an outside change into the editor the way a person would make it:
/// scrolling to each spot, flashing and backspacing removed text, and typing
/// the new text in quick chunks, with a highlight that fades once done.
@MainActor
final class LiveTextAnimation {
    let doc: Document
    /// The note before and after; the editor ends exactly on `target`.
    let original: String
    let target: String
    /// Whether the note still has unsaved edits of the user's once done.
    let keepsEdits: Bool
    /// Off once the user scrolls, so the animation stops pulling the view.
    var followsEdits = true
    private(set) var finished = false

    private weak var textView: NSTextView?
    private let steps: [LiveEditStep]
    private var index = 0
    private var timer: Timer?
    private var selection: NSRange
    /// Text typed so far, for the highlight (top-to-bottom, so earlier
    /// ranges never shift).
    private var inserted: [NSRange] = []
    /// Applies one change to the text view as the assistant's (no undo).
    private let replace: (NSRange, String) -> Void
    private let completion: (LiveTextAnimation) -> Void

    init(doc: Document, textView: NSTextView, target: String, keepsEdits: Bool,
         replace: @escaping (NSRange, String) -> Void, completion: @escaping (LiveTextAnimation) -> Void) {
        self.doc = doc
        self.textView = textView
        original = doc.storage.string
        self.target = target
        self.keepsEdits = keepsEdits
        self.replace = replace
        self.completion = completion
        selection = textView.selectedRange()
        steps = LiveEditPlan.steps(for: TextDiff.edits(from: original, to: target), in: original)
    }

    func start() {
        guard !steps.isEmpty else { finish(); return }
        LiveHighlight.clear(textView)
        let timer = Timer(timeInterval: 1 / LiveEditPlan.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private var attached: Bool {
        guard let textView else { return false }
        return textView.textStorage === doc.storage
    }

    private func tick() {
        guard !finished else { return }
        guard attached, index < steps.count else { finish(); return }
        let step = steps[index]
        index += 1
        perform(step)
        if index >= steps.count { finish() }
    }

    private func perform(_ step: LiveEditStep) {
        switch step {
        case .reveal(let range):
            reveal(range)
            LiveHighlight.show(inserted, removing: range, in: textView)
            return
        case .delete(let range):
            replace(range, "")
            reveal(NSRange(location: range.location, length: 0))
        case .insert(let location, let text):
            replace(NSRange(location: location, length: 0), text)
            let length = (text as NSString).length
            if let last = inserted.last, NSMaxRange(last) == location {
                inserted[inserted.count - 1].length += length
            } else {
                inserted.append(NSRange(location: location, length: length))
            }
            reveal(NSRange(location: location + length, length: 0))
        }
        // The user's caret stays put relative to their text.
        selection = map(selection, through: step)
        textView?.setSelectedRange(selection)
        LiveHighlight.show(inserted, removing: nil, in: textView)
    }

    private func map(_ range: NSRange, through step: LiveEditStep) -> NSRange {
        let start = LiveEditPlan.map(range.location, through: step)
        let end = LiveEditPlan.map(NSMaxRange(range), through: step)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func reveal(_ range: NSRange) {
        guard followsEdits, let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let scrollView = textView.enclosingScrollView else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        let visible = scrollView.contentView.documentVisibleRect
        // Already comfortably on screen: leave the view alone.
        if rect.minY >= visible.minY + 24 && rect.maxY <= visible.maxY - 24 { return }
        // Otherwise bring it to about a third of the way down.
        let y = max(0, min(rect.midY - visible.height / 3, textView.frame.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Jumps to the end: any steps left are applied in one go.
    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if attached, let textView {
            let current = doc.storage.string
            if current != target, let span = TextDiff.changedSpan(current as NSString, target as NSString) {
                replace(span.old, (target as NSString).substring(with: span.new))
                if span.new.length > 0 { inserted.append(span.new) }
                selection = NSRange(location: min(selection.location, (target as NSString).length), length: 0)
            }
            let length = (target as NSString).length
            inserted = inserted.compactMap { range in
                let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
                return clipped.length > 0 ? clipped : nil
            }
            textView.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: length)))
            LiveHighlight.fade(inserted, in: textView)
        }
        completion(self)
    }

    /// The text this animation typed, for highlighting it after the fact.
    var insertedRanges: [NSRange] { inserted }
}

/// The temporary background marking an assistant's edit: layout-manager
/// attributes, so styling passes don't touch them and nothing gets dirty.
@MainActor
enum LiveHighlight {
    private static var fades: [ObjectIdentifier: Timer] = [:]

    static var insertColor: NSColor { (Theme.link ?? Theme.code).withAlphaComponent(Theme.palette.isDark ? 0.24 : 0.18) }
    static var removeColor: NSColor { NSColor.systemRed.withAlphaComponent(Theme.palette.isDark ? 0.32 : 0.22) }

    static func clear(_ textView: NSTextView?) {
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        fades.removeValue(forKey: ObjectIdentifier(textView))?.invalidate()
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    static func show(_ ranges: [NSRange], removing: NSRange?, in textView: NSTextView?, alpha: CGFloat = 1) {
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        let color = insertColor.withAlphaComponent(insertColor.alphaComponent * alpha)
        let text = storage.string as NSString
        for range in ranges {
            // Line by line, leaving out the breaks, which would fill to the margin.
            var location = NSIntersectionRange(range, all).location
            let end = NSMaxRange(NSIntersectionRange(range, all))
            while location < end {
                let lineBreak = text.rangeOfCharacter(from: .newlines, range: NSRange(location: location, length: end - location))
                let stop = lineBreak.location == NSNotFound ? end : lineBreak.location
                if stop > location {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: color,
                                                        forCharacterRange: NSRange(location: location, length: stop - location))
                }
                location = lineBreak.location == NSNotFound ? end : NSMaxRange(lineBreak)
            }
        }
        if let removing {
            let clipped = NSIntersectionRange(removing, all)
            if clipped.length > 0 { layoutManager.addTemporaryAttribute(.backgroundColor, value: removeColor, forCharacterRange: clipped) }
        }
    }

    /// Holds the highlight a moment, then fades it out.
    static func fade(_ ranges: [NSRange], in textView: NSTextView, hold: TimeInterval = 0.6, duration: TimeInterval = 0.9) {
        let key = ObjectIdentifier(textView)
        fades.removeValue(forKey: key)?.invalidate()
        guard !ranges.isEmpty else { clear(textView); return }
        show(ranges, removing: nil, in: textView)
        let storage = textView.textStorage.map(ObjectIdentifier.init)
        let started = Date().addingTimeInterval(hold)
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak textView] timer in
            MainActor.assumeIsolated {
                // Another note took the view: its highlight is gone already.
                guard let textView, textView.textStorage.map(ObjectIdentifier.init) == storage else {
                    timer.invalidate(); fades.removeValue(forKey: key); return
                }
                let progress = Date().timeIntervalSince(started) / duration
                guard progress < 1 else {
                    timer.invalidate(); fades.removeValue(forKey: key)
                    clear(textView)
                    return
                }
                if progress > 0 { show(ranges, removing: nil, in: textView, alpha: CGFloat(1 - progress)) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fades[key] = timer
    }
}
