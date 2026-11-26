import Foundation

/// GitHub-flavored Markdown pipe tables, read from a note's source.
///
/// A table is a header row, a delimiter row (`---`, `:--`, `:-:`, `--:`)
/// with as many cells, and the body rows after them, up to a blank line or
/// the start of another block. Leading and trailing pipes are optional, and
/// `\|` is a pipe inside a cell. Every range is in the note's coordinates,
/// so the editor can style and edit cells in place.
enum MarkdownTable {

    enum Alignment: Equatable { case none, left, center, right }

    enum RowKind: Equatable { case header, delimiter, body }

    struct Cell: Equatable {
        /// The source between the cell's pipes, padding included.
        var range: NSRange
        /// The cell's text, without its padding. An empty cell's is a caret
        /// position inside its padding.
        var content: NSRange
    }

    struct Row: Equatable {
        var kind: RowKind
        /// The whole line, through its newline.
        var line: NSRange
        var cells: [Cell]
    }

    struct Table: Equatable {
        /// Every row, through the last one's newline.
        var range: NSRange
        var alignments: [Alignment]
        /// Header, delimiter, then body rows, in order.
        var rows: [Row]
        /// Columns the delimiter row declares.
        var columnCount: Int { alignments.count }
        var header: Row { rows[0] }
        var bodyRows: ArraySlice<Row> { rows.dropFirst(2) }
        /// Rows that hold text: all but the delimiter row.
        var textRows: [Row] { rows.filter { $0.kind != .delimiter } }

        func row(containing location: Int) -> Row? {
            rows.first { location >= $0.line.location && (location < NSMaxRange($0.line) || isLineEnd(location, of: $0)) }
        }

        /// The end of the last line counts as part of it when it has no newline.
        private func isLineEnd(_ location: Int, of row: Row) -> Bool {
            location == NSMaxRange(row.line) && row.line == rows.last?.line
        }
    }

    // MARK: - Rows

    /// Splits one line (no newline) into cells. `offset` is the line's
    /// location in the note; `prefix` skips a blockquote marker.
    static func cells(of line: NSString, offset: Int = 0, prefix: Int = 0) -> [Cell] {
        let length = line.length
        var start = prefix
        while start < length, isSpace(line.character(at: start)) { start += 1 }
        var end = length
        while end > start, isSpace(line.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }
        // Unescaped pipe positions.
        var pipes: [Int] = []
        var index = start
        while index < end {
            let c = line.character(at: index)
            if c == 0x5C { index += 2; continue }  // backslash escapes the next character
            if c == 0x7C { pipes.append(index) }
            index += 1
        }
        let leading = pipes.first == start
        let trailing = pipes.last == end - 1 && (pipes.count > 1 || !leading)
        var bounds: [Int] = []  // separators between cells
        bounds.append(leading ? start : start - 1)
        bounds += pipes.filter { !(leading && $0 == start) && !(trailing && $0 == end - 1) }
        bounds.append(trailing ? end - 1 : end)
        var result: [Cell] = []
        for i in 0..<(bounds.count - 1) {
            let rawStart = bounds[i] + 1
            // Without a leading pipe, the first cell's padding runs back to
            // the line's start (or the quote marker).
            let rangeStart = i == 0 && !leading ? prefix : rawStart
            let rangeEnd = bounds[i + 1]
            let lastWithoutPipe = i == bounds.count - 2 && !trailing
            let range = NSRange(location: rangeStart, length: (lastWithoutPipe ? length : rangeEnd) - rangeStart)
            var contentStart = max(rawStart, rangeStart)
            var contentEnd = rangeEnd
            while contentStart < contentEnd, isSpace(line.character(at: contentStart)) { contentStart += 1 }
            while contentEnd > contentStart, isSpace(line.character(at: contentEnd - 1)) { contentEnd -= 1 }
            if contentStart == contentEnd {
                // An empty cell's caret sits after one space of padding.
                contentStart = min(max(rawStart, rangeStart) + 1, rangeEnd)
                if rangeEnd == max(rawStart, rangeStart) { contentStart = rangeEnd }
                contentEnd = contentStart
            }
            result.append(Cell(range: NSRange(location: range.location + offset, length: range.length),
                               content: NSRange(location: contentStart + offset, length: contentEnd - contentStart)))
        }
        return result
    }

    /// The alignments a delimiter row declares, or nil if it isn't one.
    static func alignments(ofDelimiter line: NSString, prefix: Int = 0) -> [Alignment]? {
        guard hasPipe(line, from: prefix) else { return nil }
        let cells = cells(of: line, prefix: prefix)
        guard !cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in cells {
            let text = line.substring(with: cell.content)
            guard text.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let left = text.hasPrefix(":"), right = text.hasSuffix(":") && text.count > 1
            result.append(left && right ? .center : right ? .right : left ? .left : .none)
        }
        return result
    }

    /// Escapes text typed into a cell so it stays one cell on one line.
    static func escapeCellText(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if character == "|", previous != "\\" { result.append("\\|") }
            else if character == "\n" || character == "\r" { result.append(" ") }
            else { result.append(character) }
            previous = character
        }
        return result
    }

    /// A new body row of `count` empty cells.
    static func emptyRow(columns count: Int) -> String {
        "|" + String(repeating: "   |", count: max(count, 1))
    }

    // MARK: - Tables

    /// The table whose rows include `location`'s line. With `quoted`, rows
    /// are blockquote lines (an embedded quote's) and their `>` markers are
    /// set aside; `limit` stops the table before an attribution line.
    static func table(containing location: Int, in text: NSString, quoted: Bool = false, limit: Int? = nil) -> Table? {
        guard let scan = scan(containing: location, in: text, quoted: quoted, limit: limit),
              let table = scan.table else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        return line.location >= table.range.location ? table : nil
    }

    /// The block of row-like lines around `location` and the table in it,
    /// if any (which may start below `location`'s line). Lines of one block
    /// share a result, so a caller styling line by line can scan it once.
    static func scan(containing location: Int, in text: NSString, quoted: Bool = false,
                     limit: Int? = nil) -> (block: NSRange, table: Table?)? {
        guard text.length > 0, location <= text.length else { return nil }
        let end = min(limit ?? text.length, text.length)
        guard location < end || (location == end && end == text.length && end > 0) else { return nil }
        let lineAt = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        guard isRowLine(text, lineAt, quoted: quoted) else { return nil }
        // The block of row-like lines around it.
        var start = lineAt.location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard isRowLine(text, previous, quoted: quoted) else { break }
            start = previous.location
        }
        var lines: [NSRange] = []
        var position = start
        while position < end {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            guard line.location < end, isRowLine(text, line, quoted: quoted) else { break }
            lines.append(line)
            position = NSMaxRange(line)
        }
        guard let lastLine = lines.last else { return nil }
        let block = NSRange(location: start, length: NSMaxRange(lastLine) - start)
        // The first header + delimiter pair starts the table; the rest of the
        // block is its body.
        for i in 0..<max(0, lines.count - 1) {
            let headerLine = content(text, lines[i])
            let delimiterLine = content(text, lines[i + 1])
            let headerPrefix = quoted ? quotePrefix(headerLine) : 0
            let delimiterPrefix = quoted ? quotePrefix(delimiterLine) : 0
            guard !quoted || headerPrefix > 0 && delimiterPrefix > 0,
                  leadingIndent(headerLine, from: headerPrefix) < 4,
                  let alignments = alignments(ofDelimiter: delimiterLine, prefix: delimiterPrefix) else { continue }
            let headerCells = cells(of: headerLine, offset: lines[i].location, prefix: headerPrefix)
            guard headerCells.count == alignments.count else { continue }
            var rows = [Row(kind: .header, line: lines[i], cells: headerCells),
                        Row(kind: .delimiter, line: lines[i + 1],
                            cells: cells(of: delimiterLine, offset: lines[i + 1].location, prefix: delimiterPrefix))]
            for line in lines[(i + 2)...] {
                let body = content(text, line)
                rows.append(Row(kind: .body, line: line,
                                cells: cells(of: body, offset: line.location, prefix: quoted ? quotePrefix(body) : 0)))
            }
            let range = NSRange(location: lines[i].location, length: NSMaxRange(lines.last!) - lines[i].location)
            return (block, Table(range: range, alignments: alignments, rows: rows))
        }
        return (block, nil)
    }

    /// Every (unquoted) table in a note, top to bottom, skipping fenced code.
    static func tables(in text: NSString) -> [Table] {
        var result: [Table] = []
        var position = 0
        var inCode = false
        while position < text.length {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            let body = content(text, line)
            if fence.firstMatch(in: body as String, range: NSRange(location: 0, length: body.length)) != nil {
                inCode.toggle()
            } else if !inCode, let table = table(containing: line.location, in: text), table.range.location == line.location {
                result.append(table)
                position = NSMaxRange(table.range)
                continue
            }
            position = NSMaxRange(line)
        }
        return result
    }

    // MARK: - Lines

    private static let fence = try! NSRegularExpression(pattern: #"^\s*(```|~~~)"#)
    /// Lines that start another block, which ends a table.
    private static let blockStart = try! NSRegularExpression(
        pattern: #"^[ \t]{0,3}(#{1,6}([ \t]|$)|>|```|~~~|[-*+][ \t]|\d+[.)][ \t])|^[ \t]*([-*_])([ \t]*\3){2,}[ \t]*$"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)

    private static func content(_ text: NSString, _ line: NSRange) -> NSString {
        var length = line.length
        while length > 0, [0x0A, 0x0D].contains(text.character(at: line.location + length - 1)) { length -= 1 }
        return text.substring(with: NSRange(location: line.location, length: length)) as NSString
    }

    static func quotePrefix(_ line: NSString) -> Int {
        quoteMarker.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))?.range.length ?? 0
    }

    private static func isRowLine(_ text: NSString, _ lineRange: NSRange, quoted: Bool) -> Bool {
        var line = content(text, lineRange)
        if quoted {
            let prefix = quotePrefix(line)
            guard prefix > 0 else { return false }
            line = line.substring(from: prefix) as NSString
        }
        let range = NSRange(location: 0, length: line.length)
        guard (line as String).trimmingCharacters(in: .whitespaces).isEmpty == false else { return false }
        return blockStart.firstMatch(in: line as String, range: range) == nil
    }

    private static func hasPipe(_ line: NSString, from start: Int) -> Bool {
        var index = start
        while index < line.length {
            let c = line.character(at: index)
            if c == 0x5C { index += 2; continue }
            if c == 0x7C { return true }
            index += 1
        }
        return false
    }

    private static func leadingIndent(_ line: NSString, from start: Int) -> Int {
        var index = start
        while index < line.length, isSpace(line.character(at: index)) { index += 1 }
        return index - start
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }
}
