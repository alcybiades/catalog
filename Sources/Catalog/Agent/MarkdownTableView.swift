import SwiftUI

/// Markdown split into prose and the pipe tables between it, for read-only
/// rendering (the assistant's replies) that can't lay a table out in text.
enum MarkdownBlocks {
    enum Block: Equatable {
        case text(String)
        case table(MarkdownTable.Table, source: String)
    }

    static func split(_ markdown: String) -> [Block] {
        let ns = markdown as NSString
        let tables = MarkdownTable.tables(in: ns)
        guard !tables.isEmpty else { return [.text(markdown)] }
        var blocks: [Block] = []
        var position = 0
        func appendText(upTo end: Int) {
            guard end > position else { return }
            let text = ns.substring(with: NSRange(location: position, length: end - position))
                .trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.text(text)) }
        }
        for table in tables {
            appendText(upTo: table.range.location)
            blocks.append(.table(table, source: markdown))
            position = NSMaxRange(table.range)
        }
        appendText(upTo: ns.length)
        return blocks
    }

    static func hasTable(_ markdown: String) -> Bool {
        markdown.contains("|") && !MarkdownTable.tables(in: markdown as NSString).isEmpty
    }

    /// A cell's text with its pipe escapes resolved.
    static func cellText(_ cell: MarkdownTable.Cell, in source: String) -> String {
        (source as NSString).substring(with: cell.content).replacingOccurrences(of: "\\|", with: "|")
    }
}

/// A Markdown table drawn as a grid in the assistant's type: a bold header
/// over a washed band and a rule, hairlines between rows and columns, and
/// columns aligned as the delimiter row asks. Wide tables scroll sideways.
struct MarkdownTableView: View {
    let table: MarkdownTable.Table
    let source: String
    let font: Font
    let styled: (String) -> AttributedString

    private var columnCount: Int { table.columnCount }

    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .center: return .center
        case .right: return .trailing
        case .none, .left: return .leading
        }
    }

    private func text(_ row: MarkdownTable.Row, _ column: Int) -> String {
        row.cells.indices.contains(column) ? MarkdownBlocks.cellText(row.cells[column], in: source) : ""
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        cell(text(table.header, column), column: column, header: true)
                    }
                }
                .background(WikiTheme.wash.opacity(0.05))
                Rectangle().fill(WikiTheme.wash.opacity(0.22)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.bodyRows.enumerated()), id: \.offset) { index, row in
                    bodyRow(row, first: index == 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(WikiTheme.wash.opacity(0.16), lineWidth: 1))
            .padding(1)
        }
    }

    @ViewBuilder
    private func bodyRow(_ row: MarkdownTable.Row, first: Bool) -> some View {
        if !first {
            Rectangle().fill(WikiTheme.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
        }
        GridRow {
            ForEach(0..<columnCount, id: \.self) { column in
                cell(text(row, column), column: column, header: false)
            }
        }
    }

    private func cell(_ value: String, column: Int, header: Bool) -> some View {
        Text(styled(value))
            .font(font)
            .fontWeight(header ? .semibold : nil)
            .foregroundStyle(header ? WikiTheme.bold : WikiTheme.foreground)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: alignment(column))
            .overlay(alignment: .leading) {
                if column > 0 { Rectangle().fill(WikiTheme.hairline).frame(width: 1) }
            }
    }
}

/// An assistant reply that holds tables: its prose as styled text, its
/// tables as grids, in order.
struct MarkdownWithTables: View {
    let markdown: String
    let font: ReaderFont
    let styled: (String) -> AttributedString

    var body: some View {
        let blocks = MarkdownBlocks.split(markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .text(let text):
            Text(styled(text))
                .font(font.scaled(0.9))
                .foregroundStyle(WikiTheme.foreground)
                .tint(WikiTheme.link)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .table(let table, let source):
            MarkdownTableView(table: table, source: source, font: font.scaled(0.84), styled: styled)
        }
    }
}
