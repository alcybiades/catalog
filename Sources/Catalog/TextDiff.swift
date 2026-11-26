import Foundation

/// One replacement in a string, in UTF-16 offsets (NSString / NSTextStorage
/// coordinates): `range` of the old text becomes `replacement`.
struct TextEdit: Equatable {
    var range: NSRange
    var replacement: String
}

/// Word-level diffs between two versions of a note, for showing an outside
/// change (the assistant's) as edits in place rather than a wholesale reload.
enum TextDiff {
    /// Above this many tokens on a side, diff whole lines instead; above
    /// `lineLimit` lines, replace the changed span in one piece. Keeps the
    /// diff (on the main thread) to a few milliseconds.
    static let tokenLimit = 2500
    static let lineLimit = 1500

    /// Non-overlapping edits, in ascending order, that turn `old` into `new`.
    static func edits(from old: String, to new: String) -> [TextEdit] {
        let a = old as NSString, b = new as NSString
        guard let span = changedSpan(a, b) else { return [] }
        let oldTokens = tokens(a, in: span.old), newTokens = tokens(b, in: span.new)
        if oldTokens.count <= tokenLimit && newTokens.count <= tokenLimit {
            return merge(align(oldTokens, newTokens, a, b, span), in: a)
        }
        let oldLines = lines(a, in: span.old), newLines = lines(b, in: span.new)
        if oldLines.count <= lineLimit && newLines.count <= lineLimit {
            return align(oldLines, newLines, a, b, span)
        }
        return [TextEdit(range: span.old, replacement: b.substring(with: span.new))]
    }

    /// The edits applied to `text` (ranges in its coordinates, ascending).
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    /// Three-way merge: `theirs` (the file as the assistant left it) and
    /// `mine` (unsaved edits) both started from `base`. Nil when their
    /// changes touch the same text.
    static func merge(base: String, mine: String, theirs: String) -> String? {
        if mine == base { return theirs }
        if theirs == base || theirs == mine { return mine }
        let ours = edits(from: base, to: mine), other = edits(from: base, to: theirs)
        for x in ours {
            for y in other where conflict(x.range, y.range) { return nil }
        }
        let combined = (ours + other).sorted { a, b in
            a.range.location != b.range.location ? a.range.location < b.range.location : a.range.length < b.range.length
        }
        return apply(combined, to: base)
    }

    /// Edits conflict when their ranges overlap or both insert at one spot;
    /// an edit ending where another starts is fine unless one is an insertion.
    private static func conflict(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 && b.length == 0 { return a.location == b.location }
        if a.length == 0 { return a.location >= b.location && a.location <= NSMaxRange(b) }
        if b.length == 0 { return b.location >= a.location && b.location <= NSMaxRange(a) }
        return a.location < NSMaxRange(b) && b.location < NSMaxRange(a)
    }

    /// The single span that differs, trimmed of the common prefix and
    /// suffix and widened to whole words (and composed characters).
    static func changedSpan(_ a: NSString, _ b: NSString) -> (old: NSRange, new: NSRange)? {
        if a.isEqual(to: b as String) { return nil }
        let limit = min(a.length, b.length)
        var prefix = 0
        while prefix < limit && a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix && a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        // Back off into whole words, so a changed word retypes from its start.
        while prefix > 0 && (isWord(a, prefix - 1) && (isWord(a, prefix) || isWord(b, prefix)) || splitsCluster(a, prefix) || splitsCluster(b, prefix)) {
            prefix -= 1
        }
        while suffix > 0 && (isWord(a, a.length - suffix) && (isWord(a, a.length - suffix - 1) || isWord(b, b.length - suffix - 1))
                              || splitsCluster(a, a.length - suffix) || splitsCluster(b, b.length - suffix)) {
            suffix -= 1
        }
        return (NSRange(location: prefix, length: a.length - suffix - prefix),
                NSRange(location: prefix, length: b.length - suffix - prefix))
    }

    private static func isWord(_ s: NSString, _ index: Int) -> Bool {
        guard index >= 0 && index < s.length else { return false }
        let c = s.character(at: index)
        if c < 128 { return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        // Other letters, and surrogates (whose pairs are kept whole anyway).
        if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
        return Unicode.Scalar(c).map { CharacterSet.alphanumerics.contains($0) } ?? false
    }

    /// Whether a boundary at `index` would cut a composed character in two.
    private static func splitsCluster(_ s: NSString, _ index: Int) -> Bool {
        guard index > 0 && index < s.length else { return false }
        return s.rangeOfComposedCharacterSequence(at: index).location != index
    }

    private struct Token { let text: String; let range: NSRange }

    /// Words, runs of spaces, line breaks, and single other characters.
    private static func tokens(_ s: NSString, in span: NSRange) -> [Token] {
        var result: [Token] = []
        var index = span.location
        let end = NSMaxRange(span)
        while index < end {
            let start = index
            let first = s.rangeOfComposedCharacterSequence(at: index)
            index = min(end, NSMaxRange(first))
            let c = s.character(at: start)
            if isWord(s, start) {
                while index < end && isWord(s, index) { index = min(end, NSMaxRange(s.rangeOfComposedCharacterSequence(at: index))) }
            } else if c == 32 || c == 9 {
                while index < end && (s.character(at: index) == 32 || s.character(at: index) == 9) { index += 1 }
            }
            let range = NSRange(location: start, length: index - start)
            result.append(Token(text: s.substring(with: range), range: range))
        }
        return result
    }

    private static func lines(_ s: NSString, in span: NSRange) -> [Token] {
        var result: [Token] = []
        var index = span.location
        let end = NSMaxRange(span)
        while index < end {
            let line = s.lineRange(for: NSRange(location: index, length: 0))
            let range = NSRange(location: index, length: min(end, NSMaxRange(line)) - index)
            result.append(Token(text: s.substring(with: range), range: range))
            index = NSMaxRange(range)
        }
        return result
    }

    /// Myers (via CollectionDifference) over tokens, folded into edits.
    private static func align(_ old: [Token], _ new: [Token], _ a: NSString, _ b: NSString,
                              _ span: (old: NSRange, new: NSRange)) -> [TextEdit] {
        let difference = new.map(\.text).difference(from: old.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var edits: [TextEdit] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count && j < new.count && !removed.contains(i) && !inserted.contains(j) {
                i += 1; j += 1
                continue
            }
            let location = i < old.count ? old[i].range.location : NSMaxRange(span.old)
            var length = 0
            var text = ""
            while i < old.count && removed.contains(i) { length += old[i].range.length; i += 1 }
            while j < new.count && inserted.contains(j) { text += new[j].text; j += 1 }
            edits.append(TextEdit(range: NSRange(location: location, length: length), replacement: text))
        }
        return edits
    }

    /// Joins edits separated only by a space or two, so "the quick brown"
    /// → "a slow red" reads as one rewrite rather than three.
    private static func merge(_ edits: [TextEdit], in old: NSString) -> [TextEdit] {
        var result: [TextEdit] = []
        for edit in edits {
            if let last = result.last {
                let gap = NSRange(location: NSMaxRange(last.range), length: edit.range.location - NSMaxRange(last.range))
                let between = old.substring(with: gap)
                if gap.length <= 2, between.allSatisfy({ $0 == " " }) {
                    result[result.count - 1] = TextEdit(range: NSRange(location: last.range.location, length: NSMaxRange(edit.range) - last.range.location),
                                                        replacement: last.replacement + between + edit.replacement)
                    continue
                }
            }
            result.append(edit)
        }
        return result
    }
}

/// The frames of a live edit: deletions run backward like backspacing,
/// insertions type forward in chunks, top to bottom through the note.
enum LiveEditStep: Equatable {
    /// Flash the text about to be deleted (or the spot about to be typed at).
    case reveal(NSRange)
    case delete(NSRange)
    case insert(location: Int, text: String)
}

enum LiveEditPlan {
    /// Frames per second the animation runs at.
    static let frameRate = 60.0
    /// The longest an edit animates, in frames, however big it is.
    static let maxFrames = 96
    /// Typing and deleting pace at small sizes, in UTF-16 units per frame.
    static let typePace = 3
    static let deletePace = 10
    /// Frames spent flashing text before deleting it.
    static let revealFrames = 4

    /// Steps (one per frame) that turn the text the edits were computed
    /// against into its target. Offsets are in the live, partly edited text.
    static func steps(for edits: [TextEdit], in old: String) -> [LiveEditStep] {
        guard !edits.isEmpty else { return [] }
        // Too many separate spots to visit in the budget: fold neighbors
        // together, so a sweeping rewrite becomes a quick top-to-bottom reveal.
        let edits = coalesce(edits, in: old as NSString, to: maxFrames / 3)
        let inserted = edits.reduce(0) { $0 + ($1.replacement as NSString).length }
        let deleted = edits.reduce(0) { $0 + $1.range.length }
        let deletions = edits.filter { $0.range.length > 0 }.count
        // Natural pace first; scale up chunk sizes until it fits the budget.
        let pauses = min(deletions * revealFrames, maxFrames / 3)
        let reveal = deletions == 0 ? 0 : max(1, pauses / deletions)
        let budget = max(edits.count, maxFrames - deletions * reveal)
        var typeChunk = typePace, deleteChunk = deletePace
        func frames() -> Int {
            edits.reduce(0) { total, edit in
                total + Int((Double(edit.range.length) / Double(deleteChunk)).rounded(.up))
                    + Int((Double((edit.replacement as NSString).length) / Double(typeChunk)).rounded(.up))
            }
        }
        if frames() > budget {
            let scale = Double(frames()) / Double(budget)
            typeChunk = max(typePace, Int((Double(typePace) * scale).rounded(.up)))
            deleteChunk = max(deletePace, Int((Double(deletePace) * scale).rounded(.up)))
            // Many small edits can't go faster per edit: one frame each.
            if frames() > budget { typeChunk = max(typeChunk, inserted); deleteChunk = max(deleteChunk, deleted) }
        }
        let source = old as NSString
        var steps: [LiveEditStep] = []
        var shift = 0
        for edit in edits {
            let location = edit.range.location + shift
            if edit.range.length > 0 {
                for _ in 0..<reveal { steps.append(.reveal(NSRange(location: location, length: edit.range.length))) }
                // Backspace from the end, in whole composed characters.
                var end = NSMaxRange(edit.range)
                while end > edit.range.location {
                    var start = max(edit.range.location, end - deleteChunk)
                    if start > edit.range.location { start = source.rangeOfComposedCharacterSequence(at: start).location }
                    if start >= end { start = source.rangeOfComposedCharacterSequence(at: end - 1).location }
                    start = max(edit.range.location, start)
                    steps.append(.delete(NSRange(location: start + shift, length: end - start)))
                    end = start
                }
            }
            let text = edit.replacement as NSString
            var offset = 0
            while offset < text.length {
                var end = min(text.length, offset + typeChunk)
                if end < text.length { end = text.rangeOfComposedCharacterSequence(at: end).location }
                if end <= offset { end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset)) }
                steps.append(.insert(location: location + offset, text: text.substring(with: NSRange(location: offset, length: end - offset))))
                offset = end
            }
            shift += text.length - edit.range.length
        }
        return steps
    }

    /// At most `limit` edits, each covering a run of neighbors (and the
    /// unchanged text between them).
    static func coalesce(_ edits: [TextEdit], in old: NSString, to limit: Int) -> [TextEdit] {
        guard edits.count > limit else { return edits }
        let size = Int((Double(edits.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: edits.count, by: size).map { start in
            let group = edits[start..<min(edits.count, start + size)]
            let range = NSRange(location: group.first!.range.location,
                                length: NSMaxRange(group.last!.range) - group.first!.range.location)
            let local = group.map { TextEdit(range: NSRange(location: $0.range.location - range.location, length: $0.range.length),
                                             replacement: $0.replacement) }
            return TextEdit(range: range, replacement: TextDiff.apply(local, to: old.substring(with: range)))
        }
    }

    /// The text after running `steps` on `text` (what the editor shows).
    static func run(_ steps: [LiveEditStep], on text: String) -> String {
        let result = NSMutableString(string: text)
        for step in steps {
            switch step {
            case .reveal: break
            case .delete(let range): result.deleteCharacters(in: range)
            case .insert(let location, let inserted): result.insert(inserted, at: location)
            }
        }
        return result as String
    }

    /// A position (the caret) carried through one step.
    static func map(_ location: Int, through step: LiveEditStep) -> Int {
        switch step {
        case .reveal: return location
        case .delete(let range):
            if location >= NSMaxRange(range) { return location - range.length }
            return min(location, range.location)
        case .insert(let at, let text):
            return location > at ? location + (text as NSString).length : location
        }
    }
}
