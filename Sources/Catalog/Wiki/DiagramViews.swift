import SwiftUI

extension WikiTheme {
    /// Wikipedia's diagram colors are pastels meant for white paper; blended
    /// into the dark glass they keep their hue without glaring.
    static func diagramFill(_ hex: UInt32?) -> Color {
        guard let hex else { return Color.white.opacity(0.06) }
        return Color(hex: 0x1C1D22).mix(with: Color(hex: hex), by: 0.42)
    }

    static func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(WikiTheme.interface(size: 12, weight: .semibold))
            .foregroundStyle(WikiTheme.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

/// The rounded translucent card shared by the infobox and diagrams.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(WikiTheme.hairline, lineWidth: 1)
            }
    }
}

extension View {
    func card(radius: CGFloat = 18) -> some View { modifier(CardBackground(radius: radius)) }
}

// MARK: - Graphical timeline

/// Module:Graphical timeline, redrawn: a time scale, colored spans with
/// their labels, and arrows marking events.
struct GraphicalTimelineView: View {
    let timeline: GraphicalTimeline
    let font: ReaderFont
    /// Inside the infobox the card is already there.
    var framed = true

    @State private var available: CGFloat = 0

    /// Fills the column when there's room, without outgrowing the prose.
    private var em: CGFloat {
        let total = timeline.scaleWidth + timeline.width + timeline.notesWidth
        let fitted = available > 0 ? (available - 8) / total : font.size * 0.62
        return min(max(fitted, 10), font.size * 0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if framed {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.yaxis")
                    if let title = timeline.title {
                        Text(title).textCase(.uppercase)
                    } else {
                        Text("Timeline").textCase(.uppercase)
                    }
                }
                .font(WikiTheme.interface(size: 12, weight: .semibold))
                .foregroundStyle(WikiTheme.secondary)
                .tint(WikiTheme.secondary)
                .tracking(0.6)
            }
            HorizontalOverflow {
                chart
                    .padding(.vertical, em)
                    .padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            if let caption = timeline.caption {
                Text(caption)
                    .font(WikiTheme.interface(size: max(11, em * 0.9)))
                    .foregroundStyle(WikiTheme.secondary)
                    .tint(WikiTheme.link.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(framed ? 18 : 0)
        .modifier(OptionalCard(enabled: framed))
    }

    private var chart: some View {
        let height = timeline.height * em
        return HStack(alignment: .top, spacing: 0) {
            scale.frame(width: timeline.scaleWidth * em, height: height)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white.opacity(0.025))
                ForEach(Array(timeline.bars.enumerated()), id: \.offset) { _, bar in
                    Rectangle()
                        .fill(WikiTheme.diagramFill(bar.color))
                        .frame(width: bar.width * em, height: max(bar.height * em, 1))
                        .position(x: (bar.left + bar.width / 2) * em, y: (bar.top + bar.height / 2) * em)
                }
                ForEach(Array(timeline.bars.enumerated()), id: \.offset) { _, bar in
                    if !bar.label.characters.isEmpty { label(bar) }
                }
            }
            .frame(width: timeline.width * em, height: height)
            if timeline.notesWidth > 0 {
                notes.frame(width: timeline.notesWidth * em, height: height)
            }
        }
        .fixedSize()
    }

    private var scale: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(WikiTheme.secondary.opacity(0.5))
                .frame(width: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            ForEach(Array(timeline.ticks.enumerated()), id: \.offset) { _, tick in
                Text(tick.label)
                    .font(WikiTheme.interface(size: em * 0.82))
                    .foregroundStyle(WikiTheme.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .frame(width: timeline.scaleWidth * em - 1, alignment: .trailing)
                    .position(x: (timeline.scaleWidth * em - 1) / 2, y: tick.position * em)
            }
        }
    }

    @ViewBuilder
    private func label(_ bar: GraphicalTimeline.Bar) -> some View {
        let text = Text(bar.label)
            .font(font.family == "Verdana" ? WikiTheme.interface(size: em * 0.9) : WikiTheme.body(font.family, size: em * 0.95))
            .foregroundStyle(WikiTheme.foreground)
            .tint(WikiTheme.link)
            .multilineTextAlignment(.center)
            .lineSpacing(0)
        let point = CGPoint(x: bar.labelX * em, y: bar.labelY * em)
        if bar.isVertical {
            text.fixedSize().rotationEffect(.degrees(90)).position(point)
        } else if bar.noWrap {
            text.fixedSize().position(point)
        } else {
            text
                .frame(width: max(bar.width * em, 5 * em))
                .fixedSize(horizontal: false, vertical: true)
                .position(point)
        }
    }

    private var notes: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(timeline.notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("←").foregroundStyle(WikiTheme.listMarker)
                    Text(note.text)
                        .foregroundStyle(WikiTheme.foreground)
                        .tint(WikiTheme.link)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(WikiTheme.interface(size: em * 0.82))
                .lineSpacing(0)
                .frame(width: timeline.notesWidth * em - 6, alignment: .leading)
                .position(x: (timeline.notesWidth * em - 6) / 2 + 6, y: note.position * em)
            }
        }
    }
}

/// Content at its natural width, scrolling sideways only when it doesn't fit.
struct HorizontalOverflow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal, showsIndicators: false) { content }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

private struct OptionalCard: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.card() } else { content }
    }
}

// MARK: - Cladogram

/// A {{clade}} tree, drawn as an indented tree: each branch is an elbow from
/// its parent's line, so the topology reads top to bottom.
struct CladogramView: View {
    let root: CladeNode
    let font: ReaderFont
    var onImage: (ViewerItem) -> Void

    fileprivate struct Row: Identifiable {
        let id: Int
        /// For each ancestor column, whether its line continues past this row.
        var guides: [Bool]
        var isLast: Bool
        var node: CladeNode
    }

    private var rows: [Row] {
        var rows: [Row] = []
        func add(_ node: CladeNode, guides: [Bool], isLast: Bool) {
            rows.append(Row(id: rows.count, guides: guides, isLast: isLast, node: node))
            for (index, child) in node.children.enumerated() {
                add(child, guides: guides + [!isLast], isLast: index == node.children.count - 1)
            }
        }
        // A single named top clade is the root; otherwise draw a bare junction.
        let top = root.children.count == 1 ? root.children[0] : root
        rows.append(Row(id: 0, guides: [], isLast: true, node: top))
        for (index, child) in top.children.enumerated() {
            add(child, guides: [], isLast: index == top.children.count - 1)
        }
        return rows
    }

    private var indent: CGFloat { max(16, font.size * 0.95) }
    private var lineHeight: CGFloat { font.size * 0.84 * 1.3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                Text("Cladogram")
            }
            .font(WikiTheme.interface(size: 12, weight: .semibold))
            .foregroundStyle(WikiTheme.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            HorizontalOverflow {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in rowView(row) }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .card()
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(row.guides.enumerated()), id: \.offset) { _, continues in
                Rectangle()
                    .fill(continues ? WikiTheme.secondary.opacity(0.45) : .clear)
                    .frame(width: 1)
                    .frame(width: indent, alignment: .center)
                    .frame(maxHeight: .infinity)
            }
            if row.id > 0 {
                Elbow(isLast: row.isLast, joinY: 3 + lineHeight / 2)
                    .stroke(WikiTheme.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: indent)
                    .frame(maxHeight: .infinity)
            }
            content(row.node)
                .padding(.vertical, 3)
                .padding(.leading, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(_ node: CladeNode) -> some View {
        let isLeaf = node.children.isEmpty
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 8) {
                if let label = node.label {
                    Text(label)
                        .font(font.scaled(0.84).weight(.semibold))
                        .foregroundStyle(WikiTheme.heading)
                        .tint(WikiTheme.heading)
                }
                if let text = node.text {
                    Text(text)
                        .font(font.scaled(0.84))
                        .foregroundStyle(WikiTheme.foreground)
                        .tint(WikiTheme.link)
                }
                if let image = node.image {
                    Button { onImage(ViewerItem(image: image, caption: node.text)) } label: {
                        RemoteImage(url: image.url, maxPixel: 240, contentMode: .fit)
                            .frame(width: lineHeight * 1.6 * image.aspectRatio, height: lineHeight * 1.6)
                    }
                    .buttonStyle(PressableStyle())
                }
                if !isLeaf && node.label == nil {
                    Circle().fill(WikiTheme.secondary.opacity(0.6)).frame(width: 5, height: 5)
                        .frame(height: lineHeight)
                }
            }
            .fixedSize()
            if let sublabel = node.sublabel {
                Text(sublabel)
                    .font(font.scaled(0.72).italic())
                    .foregroundStyle(WikiTheme.secondary)
                    .tint(WikiTheme.link)
                    .fixedSize()
            }
        }
    }
}

/// "├─" or "└─", joining at the first line of the row.
private struct Elbow: Shape {
    var isLast: Bool
    var joinY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        let y = min(joinY, rect.maxY)
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: isLast ? y : rect.maxY))
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

// MARK: - Location map

struct LocationMapView: View {
    let map: LocationMap
    let caption: AttributedString?
    let font: ReaderFont
    var maxHeight: CGFloat = 400
    var onImage: (ViewerItem) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button { onImage(ViewerItem(image: map.image, caption: caption)) } label: {
                AspectFitLayout(
                    aspectRatio: map.image.aspectRatio,
                    maxWidth: map.image.width > 0 ? max(map.image.width * 1.6, 240) : .infinity,
                    maxHeight: maxHeight
                ) {
                    RemoteImage(url: map.image.url)
                        .overlay { markers }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WikiTheme.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(PressableStyle())
            .frame(maxWidth: .infinity)
            if let caption {
                Text(caption)
                    .font(font.scaled(0.8))
                    .foregroundStyle(WikiTheme.secondary)
                    .tint(WikiTheme.link.opacity(0.85))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }

    private var markers: some View {
        GeometryReader { proxy in
            let dot: CGFloat = map.markers.count > 40 ? 5 : 8
            ForEach(Array(map.markers.enumerated()), id: \.offset) { _, marker in
                let point = CGPoint(x: marker.x * proxy.size.width, y: marker.y * proxy.size.height)
                Circle()
                    .fill(Color(hex: marker.color))
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1) }
                    .frame(width: dot, height: dot)
                    .position(point)
                if let label = marker.label {
                    Text(label)
                        .font(WikiTheme.interface(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .fixedSize()
                        .frame(width: 160, alignment: .leading)
                        .position(x: point.x + dot / 2 + 3 + 80, y: point.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

}

// MARK: - Geological range

/// The taxobox strip of geological periods with the span marked beneath.
struct GeologicRangeView: View {
    let range: GeologicRange
    let font: ReaderFont
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(Array(range.periods.enumerated()), id: \.offset) { _, period in
                        let segment = Text(period.label)
                            .font(WikiTheme.interface(size: 9))
                            .foregroundStyle(WikiTheme.foreground.opacity(0.9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: max(period.width * width - 1, 1), height: 16)
                            .background(WikiTheme.diagramFill(period.color))
                            .offset(x: period.start * width)
                        segment
                            .contentShape(Rectangle())
                            .onTapGesture { if let link = period.link { openURL(link) } }
                            .accessibilityLabel(period.link?.lastPathComponent ?? period.label)
                    }
                    Capsule()
                        .fill(WikiTheme.code)
                        .frame(width: max((range.rangeEnd - range.rangeStart) * width, 3), height: 4)
                        .offset(x: range.rangeStart * width, y: 20)
                }
            }
            .frame(height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            if let text = range.text {
                Text(text)
                    .font(WikiTheme.interface(size: max(11, font.size * 0.62)))
                    .foregroundStyle(WikiTheme.code)
                    .tint(WikiTheme.code)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
