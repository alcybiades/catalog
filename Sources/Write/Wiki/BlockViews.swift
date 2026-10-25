import SwiftUI

/// Identifies an image to show full screen.
struct ViewerItem: Identifiable {
    let id = UUID()
    var image: WikiImage
    var caption: AttributedString?
}

struct BlockView: View {
    let block: Block
    let font: ReaderFont
    var onImage: (ViewerItem) -> Void

    var body: some View {
        switch block.kind {
        case .heading(let level, let text, _):
            Text(text)
                .font(font.scaled(level <= 2 ? 1.5 : level == 3 ? 1.22 : 1.06))
                .foregroundStyle(WikiTheme.heading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? font.size * 1.3 : font.size * 0.6)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let text):
            ProseText(text: text, font: font.body, color: WikiTheme.foreground)

        case .note(let text):
            ProseText(text: text, font: font.scaled(0.84).italic(), color: WikiTheme.secondary)
                .padding(.leading, 2)

        case .list(let items):
            VStack(alignment: .leading, spacing: font.size * 0.35) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if !item.marker.isEmpty {
                            Text(item.marker)
                                .font(font.body)
                                .foregroundStyle(WikiTheme.listMarker)
                                .frame(minWidth: item.marker.count > 1 ? 22 : 10, alignment: .trailing)
                        }
                        ProseText(text: item.text, font: font.body, color: WikiTheme.foreground)
                    }
                    .padding(.leading, CGFloat(item.level) * 22 + (item.marker.isEmpty ? 0 : 4))
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 14) {
                Capsule()
                    .fill(WikiTheme.quote.opacity(0.5))
                    .frame(width: 3)
                ProseText(text: text, font: font.body, color: WikiTheme.quote)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)

        case .figure(let images, let caption):
            FigureView(images: images, caption: caption, font: font, onImage: onImage)

        case .table(let table):
            TableView(table: table, font: font)

        case .math(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(font.scaled(1.04))
                    .foregroundStyle(WikiTheme.italic)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

        case .preformatted(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: font.size * 0.78, design: .monospaced))
                    .foregroundStyle(WikiTheme.code)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(Color(hex: 0x2E2E2E, opacity: 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .timeline(let timeline):
            GraphicalTimelineView(timeline: timeline, font: font)
                .padding(.vertical, 6)

        case .cladogram(let root):
            CladogramView(root: root, font: font, onImage: onImage)
                .padding(.vertical, 6)

        case .map(let map, let caption):
            LocationMapView(map: map, caption: caption, font: font, onImage: onImage)
        }
    }
}

/// Selectable article prose with in-app links.
struct ProseText: View {
    let text: AttributedString
    let font: Font
    let color: Color

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .tint(WikiTheme.link)
            .lineSpacing(WikiTheme.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

struct FigureView: View {
    let images: [WikiImage]
    let caption: AttributedString?
    let font: ReaderFont
    var maxHeight: CGFloat = 400
    var onImage: (ViewerItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if images.count == 1, let image = images.first {
                ImageTile(image: image, maxHeight: maxHeight) { onImage(ViewerItem(image: image, caption: caption)) }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            ImageTile(image: image, fixedHeight: 190) { onImage(ViewerItem(image: image, caption: caption)) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollClipDisabled()
            }
            if let caption {
                Text(caption)
                    .font(font.scaled(0.8))
                    .foregroundStyle(WikiTheme.secondary)
                    .tint(WikiTheme.link.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: images.count == 1 ? .center : .leading)
                    .multilineTextAlignment(images.count == 1 ? .center : .leading)
            }
        }
        .padding(.vertical, 6)
    }
}

/// An image sized to its true aspect ratio before it loads, so the page never jumps.
struct ImageTile: View {
    let image: WikiImage
    var maxHeight: CGFloat = 400
    var fixedHeight: CGFloat?
    var action: () -> Void
    /// EasyTimeline images come without a size; learn it on load.
    @State private var loadedSize: CGSize?

    private var aspectRatio: Double {
        if image.width > 0 && image.height > 0 { return image.aspectRatio }
        if let loadedSize, loadedSize.height > 0 { return loadedSize.width / loadedSize.height }
        return 3
    }

    private var maxWidth: CGFloat {
        if image.width > 0 { return max(image.width * 1.6, 200) }
        return loadedSize.map { max($0.width, 200) } ?? .infinity
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let fixedHeight {
                    remote.frame(width: fixedHeight * aspectRatio, height: fixedHeight)
                } else {
                    AspectFitLayout(aspectRatio: aspectRatio, maxWidth: maxWidth, maxHeight: maxHeight) { remote }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(WikiTheme.hairline, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(image.file ?? "Image")
    }
}

extension ImageTile {
    private var remote: some View {
        RemoteImage(url: image.url, contentMode: image.width > 0 ? .fill : .fit) { size in
            guard image.width <= 0, loadedSize != size else { return }
            withAnimation(.easeOut(duration: 0.2)) { loadedSize = size }
        }
    }
}

/// Sizes its content to an aspect ratio within a width and height limit,
/// whatever the proposal (a vertical scroll view proposes no height).
struct AspectFitLayout: Layout {
    var aspectRatio: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? maxWidth, maxWidth)
        guard width.isFinite, aspectRatio > 0 else { return CGSize(width: maxHeight * aspectRatio, height: maxHeight) }
        let height = width / aspectRatio
        return height > maxHeight ? CGSize(width: maxHeight * aspectRatio, height: maxHeight) : CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// A neutral Liquid Glass capsule. (The system `.glass` style picks up the
/// accent tint on macOS; this looks the same on both platforms.)
struct GlassPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WikiTheme.foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassPillStyle {
    static var glassPill: GlassPillStyle { GlassPillStyle() }
}

/// A gentle native-feeling press response.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct TableView: View {
    let table: TableData
    let font: ReaderFont
    @State private var showsAll = false
    @State private var available: CGFloat = 0
    private let collapsedRows = 40
    private let spacing: CGFloat = 18
    private let inset: CGFloat = 16

    /// The longest line in each column, in characters.
    private var columnLengths: [Int] {
        var lengths: [Int] = []
        for row in table.rows {
            for (index, cell) in row.enumerated() {
                let longest = String(cell.text.characters).split(separator: "\n").map(\.count).max() ?? 0
                if index < lengths.count { lengths[index] = max(lengths[index], longest) } else { lengths.append(longest) }
            }
        }
        return lengths
    }

    /// Prose columns get a definite width so their text wraps; without one,
    /// text lays out on a single line and spills over its neighbors. They
    /// share whatever the short columns leave, but never shrink below a
    /// readable measure (the table scrolls sideways instead).
    private var columnWidths: [CGFloat?] {
        let lengths = columnLengths
        let charWidth = font.size * 0.8 * 0.5
        let shortLimit = 24
        let short = lengths.filter { $0 <= shortLimit }
        let longCount = lengths.count - short.count
        guard longCount > 0 else { return lengths.map { _ in nil } }
        let shortWidth = short.reduce(0) { $0 + CGFloat($1) * charWidth }
        let gaps = spacing * CGFloat(max(lengths.count - 1, 0)) + inset * 2
        let room = available > 0 ? (available - shortWidth - gaps) / CGFloat(longCount) : 280
        let width = min(max(room, 200), 520)
        return lengths.map { $0 <= shortLimit ? nil : min(width, max(CGFloat($0) * charWidth, 120)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption = table.caption {
                Text(caption)
                    .font(font.scaled(0.82).italic())
                    .foregroundStyle(WikiTheme.secondary)
                    .tint(WikiTheme.link)
            }
            HorizontalOverflow { grid }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WikiTheme.hairline, lineWidth: 1)
                }
            if table.rows.count > collapsedRows {
                Button {
                    withAnimation(.snappy) { showsAll.toggle() }
                } label: {
                    Label(showsAll ? "Show fewer rows" : "Show all \(table.rows.count) rows",
                          systemImage: showsAll ? "chevron.up" : "chevron.down")
                        .font(WikiTheme.interface(size: 13))
                }
                .buttonStyle(.glassPill)
            }
        }
        .padding(.vertical, 6)
    }

    private var grid: some View {
        let widths = columnWidths
        let rows = showsAll ? table.rows : Array(table.rows.prefix(collapsedRows))
        return Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().overlay(WikiTheme.hairline).gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellText(cell, width: column < widths.count ? widths[column] : nil)
                    }
                }
            }
        }
        .padding(inset)
    }

    @ViewBuilder
    private func cellText(_ cell: TableCell, width: CGFloat?) -> some View {
        let text = Text(cell.text)
            .font(font.scaled(0.8))
            .foregroundStyle(cell.isHeader ? WikiTheme.heading : WikiTheme.foreground)
            .tint(WikiTheme.link)
            .lineSpacing(2)
            .textSelection(.enabled)
        if let width {
            text
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            text
                .fixedSize()
                .frame(minWidth: 40, alignment: .leading)
        }
    }
}

/// The infobox as an "at a glance" card.
struct InfoboxView: View {
    let rows: [InfoRow]
    /// The article's title, for a succession row without one.
    var title: String?
    let font: ReaderFont
    var onImage: (ViewerItem) -> Void
    @State private var expanded = false
    private let collapsedCount = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("At a glance", systemImage: "list.bullet.rectangle")
                    .font(WikiTheme.interface(size: 12, weight: .semibold))
                    .foregroundStyle(WikiTheme.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer()
            }
            .padding(.bottom, 10)

            let visible = expanded ? rows : Array(rows.prefix(collapsedCount))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
            }
            if rows.count > collapsedCount {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? "Show less" : "Show all \(rows.count)")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(WikiTheme.interface(size: 13))
                    .foregroundStyle(WikiTheme.link)
                    .padding(.top, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .card()
    }

    @ViewBuilder
    private func rowView(_ row: InfoRow) -> some View {
        switch row {
        case .header(let title):
            Text(title)
                .font(font.scaled(0.86).weight(.semibold))
                .foregroundStyle(WikiTheme.heading)
                .padding(.top, 6)
        case .pair(let label, let value):
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    labelText(label).frame(width: 118, alignment: .leading)
                    valueText(value)
                }
                .frame(minWidth: 380)
                VStack(alignment: .leading, spacing: 3) {
                    labelText(label)
                    valueText(value)
                }
            }
        case .text(let value):
            valueText(value)
        case .subheader(let value):
            Text(value)
                .font(font.scaled(0.9).weight(.semibold))
                .foregroundStyle(WikiTheme.heading)
                .tint(WikiTheme.link)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        case .succession(let previous, let current, let next):
            succession(previous: previous, current: current ?? title, next: next)
        case .image(let images, let caption):
            FigureView(images: images, caption: caption, font: font, maxHeight: 260, onImage: onImage)
        case .map(let map, let caption):
            LocationMapView(map: map, caption: caption, font: font, maxHeight: 280, onImage: onImage)
        case .range(let range):
            GeologicRangeView(range: range, font: font)
                .padding(.vertical, 2)
        case .timeline(let timeline):
            GraphicalTimelineView(timeline: timeline, font: font, framed: false)
        }
    }

    /// Where the subject sits in its sequence, as Wikipedia's period boxes
    /// show it: what came before, the subject, what came after.
    private func succession(previous: AttributedString?, current: String?, next: AttributedString?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("←").foregroundStyle(WikiTheme.listMarker)
                if let previous { valueText(previous) }
            }
            .opacity(previous == nil ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let current {
                Text(current)
                    .font(font.scaled(0.84).weight(.semibold))
                    .foregroundStyle(WikiTheme.bold)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let next {
                    Text(next)
                        .font(font.scaled(0.84))
                        .foregroundStyle(WikiTheme.foreground)
                        .tint(WikiTheme.link)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("→").foregroundStyle(WikiTheme.listMarker)
            }
            .opacity(next == nil ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(font.scaled(0.84))
        .padding(.vertical, 4)
    }

    private func labelText(_ label: String) -> some View {
        Text(label)
            .font(WikiTheme.interface(size: max(11, font.size * 0.66)))
            .foregroundStyle(WikiTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(_ value: AttributedString) -> some View {
        Text(value)
            .font(font.scaled(0.84))
            .foregroundStyle(WikiTheme.foreground)
            .tint(WikiTheme.link)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
