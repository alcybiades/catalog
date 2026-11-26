import AppKit

/// Editing a rendered table in place. Its pipes and padding are concealed
/// (see `MarkdownHighlighter`), so the caret lives in cells: clicks and
/// vertical movement land in the nearest cell, arrows step from one cell to
/// the next, deleting at a cell's edge does nothing, Tab and Return move
/// between cells and rows (adding a row past the last), and a typed or
/// pasted `|` is escaped so the row keeps its cells. Every edit is an
/// ordinary text change, so undo and saving see plain Markdown.
extension EditorTextView {

    /// A table as it is in the source now.
    struct TableSource { let table: MarkdownTable.Table }

    /// The rendered table row on `location`'s line. Its source is read
    /// afresh: the styled table's ranges go stale as text above it changes.
    func tableRow(at location: Int) -> (block: TableSource, index: Int)? {
        guard let textStorage, textStorage.length > 0 else { return nil }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: min(max(0, location), ns.length), length: 0))
        guard line.location < textStorage.length,
              textStorage.attribute(.mdTable, at: line.location, effectiveRange: nil) != nil else { return nil }
        let quoted = MarkdownTable.quotePrefix(ns.substring(with: line) as NSString) > 0
        let limit = quoted ? EmbeddedQuote.block(containing: line.location, in: ns)?.attribution.line.location : nil
        guard let table = MarkdownTable.table(containing: line.location, in: ns, quoted: quoted, limit: limit),
              let index = table.rows.firstIndex(where: { $0.line.location == line.location }) else { return nil }
        return (TableSource(table: table), index)
    }

    /// The cell whose text `location` is in or at an edge of.
    func tableCell(at location: Int, in row: MarkdownTable.Row) -> Int? {
        row.cells.firstIndex { location >= $0.content.location && location <= NSMaxRange($0.content) }
    }

    private func isConcealed(_ range: NSRange) -> Bool {
        guard let textStorage, range.length > 0 else { return true }
        var index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange()
            guard textStorage.attribute(.mdMarker, at: index, effectiveRange: &effective) != nil else { return false }
            index = NSMaxRange(effective)
        }
        return true
    }

    /// Whether `location` shows at the start (or end) of a cell's text:
    /// only concealed syntax (say a `**`) lies between them.
    private func isVisually(at location: Int, start: Bool, of cell: MarkdownTable.Cell) -> Bool {
        start ? isConcealed(NSRange(location: cell.content.location, length: location - cell.content.location))
            : isConcealed(NSRange(location: location, length: NSMaxRange(cell.content) - location))
    }

    private func textRows(of table: MarkdownTable.Table) -> [Int] {
        table.rows.indices.filter { table.rows[$0].kind != .delimiter }
    }

    private func placeCaret(_ location: Int) {
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// The syntax the caret reveals: an embedded quote's whole block, or a
    /// table's delimiter row (so its alignment can be edited).
    func revealRange(at caret: Int) -> NSRange? {
        let text = string as NSString
        if let quote = EmbeddedQuote.block(containing: caret, in: text)?.range { return quote }
        guard let table = MarkdownTable.table(containing: caret, in: text),
              let row = table.row(containing: caret), row.kind == .delimiter else { return nil }
        return row.line
    }

    // MARK: Caret

    /// Keeps a caret that lands in a table row (a click, ↑/↓) in a cell:
    /// one on the concealed syntax goes to the cell nearest the click, and
    /// one in the delimiter row to the row it was headed for. Returns true
    /// when the row is a table's, so no other snapping applies.
    func keepCaretInTableCell(previous: Int) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (block, index) = tableRow(at: sel.location) else { return false }
        let table = block.table
        let row = table.rows[index]
        let caret = sel.location
        if row.kind == .delimiter {
            if (textStorage?.attribute(.mdTableSyntax, at: row.line.location, effectiveRange: nil) as? Int) == 3 { return true }
            let rows = textRows(of: table)
            let upward = previous > caret
            let target = upward ? rows.last(where: { $0 < index }) : rows.first(where: { $0 > index }) ?? rows.last(where: { $0 < index })
            guard let target else { return true }
            let column = tableRow(at: previous).flatMap { $0.block.table.range == block.table.range ? tableCell(at: previous, in: table.rows[$0.index]) : nil } ?? 0
            let cells = table.rows[target].cells
            if let cell = cells.indices.contains(column) ? cells[column] : cells.last { placeCaret(NSMaxRange(cell.content)) }
            return true
        }
        guard !row.cells.isEmpty else { return true }
        if let cell = tableCell(at: caret, in: row) {
            let content = row.cells[cell].content
            // Inside a cell's text, the usual snapping (out of a concealed
            // `**`, say) applies; an empty cell's caret is already home.
            return content.length == 0 || caret == content.location || caret == NSMaxRange(content)
        }
        // On concealed syntax: the nearest cell edge, by where the click
        // was when there was one.
        var candidates: [Int] = []
        for cell in row.cells { candidates += [cell.content.location, NSMaxRange(cell.content)] }
        let best: Int
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
           event.window === window, let x = containerX(of: convert(event.locationInWindow, from: nil)) {
            best = candidates.min { abs(xPosition(of: $0) - x) < abs(xPosition(of: $1) - x) } ?? caret
        } else {
            best = candidates.min { abs($0 - caret) < abs($1 - caret) } ?? caret
        }
        if best != caret { setSelectedRange(NSRange(location: best, length: 0)) }
        return true
    }

    private func containerX(of point: NSPoint) -> CGFloat? { point.x - textContainerOrigin.x }

    /// The x (in container coordinates) where the caret at `location` draws.
    private func xPosition(of location: Int) -> CGFloat {
        guard let layoutManager else { return 0 }
        let length = (string as NSString).length
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, length - 1)))
        guard glyph < layoutManager.numberOfGlyphs else { return 0 }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
        if location >= length {
            return x + layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer!).width
        }
        return x
    }

    /// ← and → step between cells: from a cell's start to the previous
    /// cell's end, from its end to the next cell's start, and across rows
    /// at the row's ends. Returns false to move within the cell.
    func moveCaretAcrossTableCells(forward: Bool) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (block, index) = tableRow(at: sel.location) else { return false }
        let table = block.table
        let row = table.rows[index]
        guard row.kind != .delimiter, let column = tableCell(at: sel.location, in: row) else { return false }
        let cell = row.cells[column]
        guard isVisually(at: sel.location, start: !forward, of: cell) else { return false }
        let rows = textRows(of: table)
        if forward {
            if column + 1 < row.cells.count {
                placeCaret(row.cells[column + 1].content.location)
            } else if let next = rows.first(where: { $0 > index }), let first = table.rows[next].cells.first {
                placeCaret(first.content.location)
            } else {
                placeCaret(min(NSMaxRange(table.range), (string as NSString).length))
            }
        } else {
            if column > 0 {
                placeCaret(NSMaxRange(row.cells[column - 1].content))
            } else if let previous = rows.last(where: { $0 < index }), let last = table.rows[previous].cells.last {
                placeCaret(NSMaxRange(last.content))
            } else {
                placeCaret(max(0, table.range.location - 1))
            }
        }
        return true
    }

    // MARK: Deleting

    /// Deleting never reaches past a cell: at its start (backward) or end
    /// (forward) it does nothing, so pipes and rows stay put.
    func tableBlocksDeletion(backward: Bool) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (block, index) = tableRow(at: sel.location) else {
            // Forward delete just before a table would merge it upward.
            if !backward, sel.length == 0, let textStorage, sel.location < textStorage.length,
               (string as NSString).character(at: sel.location) == 0x0A,
               tableRow(at: sel.location + 1)?.index == 0 { return true }
            return false
        }
        let row = block.table.rows[index]
        guard row.kind != .delimiter, let column = tableCell(at: sel.location, in: row) else { return true }
        let cell = row.cells[column]
        return isVisually(at: sel.location, start: backward, of: cell)
    }

    /// The raw ranges a selected-text edit should change, when the selection
    /// touches a table (else nil): cell text only, so pipes and line breaks
    /// survive, except that fully selected body rows (or a whole table) go
    /// entirely. `visible` is the selection's rendered characters.
    func tableAwareEdits(_ visible: [NSRange], selection: NSRange) -> [NSRange]? {
        guard let textStorage, selection.length > 0 else { return nil }
        var blocks: [TableSource] = []
        textStorage.enumerateAttribute(.mdTable, in: selection) { value, range, _ in
            guard value != nil else { return }
            var location = range.location
            while location < NSMaxRange(range) {
                guard let (block, _) = tableRow(at: location) else { break }
                if !blocks.contains(where: { $0.table.range == block.table.range }) { blocks.append(block) }
                location = NSMaxRange(block.table.range)
            }
        }
        guard !blocks.isEmpty else { return nil }
        // Within one cell, it's ordinary text.
        if let (block, index) = tableRow(at: selection.location), let column = tableCell(at: selection.location, in: block.table.rows[index]),
           NSMaxRange(selection) <= NSMaxRange(block.table.rows[index].cells[column].content) { return nil }
        var edits = visible
        func covers(_ range: NSRange) -> Bool {
            var trimmed = range
            if trimmed.length > 0, (string as NSString).character(at: NSMaxRange(trimmed) - 1) == 0x0A { trimmed.length -= 1 }
            return selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(trimmed)
        }
        func replace(within range: NSRange, with whole: NSRange?) {
            edits = edits.flatMap { edit -> [NSRange] in
                let overlap = NSIntersectionRange(edit, range)
                guard overlap.length > 0 else { return [edit] }
                var pieces: [NSRange] = []
                if edit.location < range.location { pieces.append(NSRange(location: edit.location, length: range.location - edit.location)) }
                if NSMaxRange(edit) > NSMaxRange(range) { pieces.append(NSRange(location: NSMaxRange(range), length: NSMaxRange(edit) - NSMaxRange(range))) }
                return pieces
            }
            if let whole { edits.append(whole) }
        }
        for block in blocks {
            let table = block.table
            if covers(table.range) {
                let end = min(NSMaxRange(selection), NSMaxRange(table.range))
                replace(within: table.range, with: NSRange(location: table.range.location, length: end - table.range.location))
                continue
            }
            for row in table.rows {
                if row.kind == .body, selection.location <= row.line.location, NSMaxRange(selection) >= NSMaxRange(row.line) {
                    replace(within: row.line, with: row.line)
                } else {
                    // Only cell text changes in a partly selected row.
                    var keep = NSRange(location: row.line.location, length: 0)
                    for cell in row.cells {
                        replace(within: NSRange(location: keep.location, length: cell.content.location - keep.location), with: nil)
                        keep = NSRange(location: NSMaxRange(cell.content), length: 0)
                    }
                    replace(within: NSRange(location: keep.location, length: NSMaxRange(row.line) - keep.location), with: nil)
                }
            }
        }
        return edits.sorted { $0.location < $1.location }
    }

    // MARK: Typing

    /// Text typed or pasted into a cell, escaped to stay in it: `|` becomes
    /// `\|`, and line breaks become spaces. Nil outside a cell, and at the
    /// open end of a row without a closing pipe (where a `|` adds a column).
    func tableCellText(for inserted: String, at selection: NSRange) -> String? {
        guard inserted.contains(where: { $0 == "|" || $0 == "\n" || $0 == "\r" }),
              let (block, index) = tableRow(at: selection.location) else { return nil }
        let row = block.table.rows[index]
        guard row.kind != .delimiter, let column = tableCell(at: selection.location, in: row) else { return nil }
        let ns = string as NSString
        var lineEnd = NSMaxRange(row.line)
        while lineEnd > row.line.location, [0x0A, 0x0D].contains(ns.character(at: lineEnd - 1)) { lineEnd -= 1 }
        guard NSMaxRange(row.cells[column].range) < lineEnd else { return nil }
        let escaped = MarkdownTable.escapeCellText(inserted)
        // A `\` just before the caret would otherwise swallow the escape.
        if escaped.hasPrefix("\\|"), selection.location > 0, ns.character(at: selection.location - 1) == 0x5C,
           !inserted.hasPrefix("\\") {
            return "\\" + escaped
        }
        return escaped
    }

    /// Pastes plain text into a cell, escaped. Returns false outside one.
    func pasteIntoTableCell() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              tableCellText(for: text, at: selectedRange()) != nil else { return false }
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    // MARK: Tab and Return

    /// Tab: the next cell (the first of the next row after a row's last,
    /// adding a row after the table's last). Shift-Tab: the previous cell.
    /// The caret goes to the end of the cell's text.
    func moveToAdjacentTableCell(forward: Bool) -> Bool {
        let sel = selectedRange()
        guard let (block, index) = tableRow(at: sel.location) else { return false }
        let table = block.table
        let rows = textRows(of: table)
        let rowIndex = table.rows[index].kind == .delimiter ? (rows.first ?? 0) : index
        let row = table.rows[rowIndex]
        let column = tableCell(at: sel.location, in: row)
            ?? row.cells.lastIndex { $0.content.location <= sel.location } ?? 0
        if forward {
            if column + 1 < row.cells.count {
                placeCaret(NSMaxRange(row.cells[column + 1].content))
            } else if let next = rows.first(where: { $0 > rowIndex }), let first = table.rows[next].cells.first {
                placeCaret(NSMaxRange(first.content))
            } else {
                appendTableRow(after: row, in: table, column: 0)
            }
        } else {
            if column > 0, column - 1 < row.cells.count {
                placeCaret(NSMaxRange(row.cells[column - 1].content))
            } else if let previous = rows.last(where: { $0 < rowIndex }), let last = table.rows[previous].cells.last {
                placeCaret(NSMaxRange(last.content))
            }
        }
        return true
    }

    /// Return: the same column in the next row, adding a row after the
    /// last. Return in an empty last row removes it, leaving the table.
    func insertNewlineInTable() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, let (block, index) = tableRow(at: sel.location) else { return false }
        let table = block.table
        let row = table.rows[index]
        let rows = textRows(of: table)
        if row.kind == .delimiter {
            // Just typed: start the first body row.
            if let next = rows.first(where: { $0 > index }), let first = table.rows[next].cells.first {
                placeCaret(NSMaxRange(first.content))
            } else {
                appendTableRow(after: row, in: table, column: 0)
            }
            return true
        }
        let column = tableCell(at: sel.location, in: row) ?? 0
        if let next = rows.first(where: { $0 > index }) {
            let cells = table.rows[next].cells
            if let cell = cells.indices.contains(column) ? cells[column] : cells.last { placeCaret(NSMaxRange(cell.content)) }
            return true
        }
        if row.kind == .body, row.cells.allSatisfy({ $0.content.length == 0 }) {
            let ns = string as NSString
            var lineEnd = NSMaxRange(row.line)
            while lineEnd > row.line.location, [0x0A, 0x0D].contains(ns.character(at: lineEnd - 1)) { lineEnd -= 1 }
            // Keep a blank line so the text after is no longer a row.
            insertText("", replacementRange: NSRange(location: row.line.location, length: lineEnd - row.line.location))
            placeCaret(row.line.location)
            return true
        }
        appendTableRow(after: row, in: table, column: column)
        return true
    }

    /// Adds an empty row after `row` (with its quote marker, if quoted) and
    /// puts the caret in its cell at `column`.
    private func appendTableRow(after row: MarkdownTable.Row, in table: MarkdownTable.Table, column: Int) {
        let ns = string as NSString
        var lineEnd = NSMaxRange(row.line)
        while lineEnd > row.line.location, [0x0A, 0x0D].contains(ns.character(at: lineEnd - 1)) { lineEnd -= 1 }
        let line = ns.substring(with: NSRange(location: row.line.location, length: lineEnd - row.line.location)) as NSString
        let prefix = line.substring(to: MarkdownTable.quotePrefix(line))
        // A whitespace-only quote prefix would fold the row into a paragraph.
        let newRow = prefix + MarkdownTable.emptyRow(columns: table.columnCount)
        let start = lineEnd + 1 + (prefix as NSString).length
        insertText("\n" + newRow, replacementRange: NSRange(location: lineEnd, length: 0))
        highlightEdits()
        let cells = MarkdownTable.cells(of: newRow as NSString, offset: lineEnd + 1, prefix: (prefix as NSString).length)
        let target = cells.indices.contains(column) ? cells[column] : cells.first
        placeCaret(target.map { $0.content.location } ?? start)
    }
}
