import Foundation

// Wikipedia draws some figures with markup instead of images: timelines,
// cladograms, location maps, geological ranges. Read as text they're a stream
// of labels, so they're parsed into models and redrawn natively.

// MARK: - Models

/// Module:Graphical timeline (Hominin timeline, Life timeline, …). Positions
/// and sizes are in em, measured down from the top of the chart.
struct GraphicalTimeline: Sendable {
    struct Bar: Sendable {
        var top: Double
        var height: Double
        var left: Double
        var width: Double
        var color: UInt32?
        var label: AttributedString
        /// The label's center.
        var labelX: Double
        var labelY: Double
        var isVertical: Bool
        var noWrap: Bool
    }

    struct Tick: Sendable {
        var position: Double
        var label: String
    }

    struct Note: Sendable {
        var position: Double
        var text: AttributedString
    }

    var title: AttributedString?
    var height: Double
    var scaleWidth: Double
    var width: Double
    var notesWidth: Double
    var ticks: [Tick]
    var bars: [Bar]
    var notes: [Note]
    var caption: AttributedString?
}

/// A branch of a {{clade}} cladogram.
struct CladeNode: Sendable {
    /// The name above the branch line.
    var label: AttributedString?
    /// A note under the branch line.
    var sublabel: AttributedString?
    /// A leaf's name.
    var text: AttributedString?
    var image: WikiImage?
    var children: [CladeNode] = []

    var leafCount: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.leafCount } }
}

/// {{Location map}}: a base map with dots at fractional positions.
struct LocationMap: Sendable {
    struct Marker: Sendable {
        var x: Double
        var y: Double
        var label: AttributedString?
        var color: UInt32
    }

    var image: WikiImage
    var markers: [Marker]
}

/// {{Geological range}}: the eras of the Phanerozoic with the span a taxon lived.
struct GeologicRange: Sendable {
    struct Period: Sendable {
        var start: Double
        var width: Double
        var color: UInt32?
        var label: String
        var link: URL?
    }

    var periods: [Period]
    /// Fractions of the bar's width.
    var rangeStart: Double
    var rangeEnd: Double
    var text: AttributedString?
}

// MARK: - CSS

/// Inline styles, read just far enough to redraw positioned markup.
struct CSSStyle {
    private var declarations: [String: String] = [:]

    init(_ style: String?) {
        for part in (style ?? "").split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let name = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            declarations[name] = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }

    subscript(name: String) -> String? { declarations[name] }

    /// A length in em; px count as 14 to the em.
    func em(_ name: String) -> Double? {
        guard let value = declarations[name]?.lowercased() else { return nil }
        if value.hasSuffix("em"), let number = Double(value.dropLast(2)) { return number }
        if value.hasSuffix("px"), let number = Double(value.dropLast(2)) { return number / 14 }
        return Double(value)
    }

    func px(_ name: String) -> Double? {
        guard let value = declarations[name]?.lowercased() else { return nil }
        if value.hasSuffix("px") { return Double(value.dropLast(2).trimmingCharacters(in: .whitespaces)) }
        return Double(value)
    }

    func percent(_ name: String) -> Double? {
        guard let value = declarations[name], value.hasSuffix("%") else { return nil }
        return Double(value.dropLast()).map { $0 / 100 }
    }

    var backgroundColor: UInt32? { declarations["background-color"].flatMap(Self.color) }

    static func color(_ value: String) -> UInt32? {
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            let hex = value.dropFirst()
            if hex.count == 3 {
                return UInt32(hex.map { "\($0)\($0)" }.joined(), radix: 16)
            }
            return hex.count == 6 ? UInt32(hex, radix: 16) : nil
        }
        if value.hasPrefix("rgb") {
            let numbers = value.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 3 else { return nil }
            return numbers.prefix(3).reduce(0) { $0 << 8 | UInt32(min(max($1, 0), 255)) }
        }
        return named[value]
    }

    private static let named: [String: UInt32] = [
        "white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
        "lightgray": 0xD3D3D3, "silver": 0xC0C0C0, "pink": 0xFFC0CB, "brown": 0xA52A2A,
    ]
}

// MARK: - Parsing

extension ArticleBuilder {
    static func inlineText(of node: HTMLNode, style: InlineStyle = InlineStyle()) -> AttributedString? {
        var builder = InlineBuilder()
        builder.inlineChildren(of: node, style: style)
        let text = builder.result()
        return text.characters.isEmpty ? nil : text
    }

    // MARK: Graphical timeline

    static func isGraphicalTimeline(_ node: HTMLNode) -> Bool {
        node.tag == "table" && node["id"] == "Container" && node.first(where: { $0["id"] == "Timeline" }) != nil
    }

    static func graphicalTimeline(_ container: HTMLNode) -> GraphicalTimeline? {
        guard let chart = container.first(where: { $0["id"] == "Timeline" }) else { return nil }
        let chartStyle = CSSStyle(chart["style"])
        guard let height = chartStyle.em("height"), height > 0 else { return nil }

        var bars: [GraphicalTimeline.Bar] = []
        for div in chart.children where div.tag == "div" {
            let style = CSSStyle(div["style"])
            guard let top = style.em("top"), let barHeight = style.em("height") else { continue }
            let left = style.em("left") ?? 0
            let width = style.em("width") ?? 1
            // The label div is lowered to the bar's middle ("bottom"), sometimes
            // inside a div that nudges it by top/left.
            var nudgeX = 0.0, nudgeY = 0.0
            var inner = div.children.first { $0.tag == "div" }
            while let current = inner, CSSStyle(current["style"])["bottom"] == nil,
                  let next = current.children.first(where: { $0.tag == "div" }) {
                let nudge = CSSStyle(current["style"])
                nudgeX += nudge.em("left") ?? 0
                nudgeY += nudge.em("top") ?? 0
                inner = next
            }
            let lowered = -(CSSStyle(inner?["style"]).em("bottom") ?? -barHeight / 2)
            let label = inner.flatMap { inlineText(of: $0) } ?? AttributedString()
            bars.append(GraphicalTimeline.Bar(
                top: top, height: barHeight, left: left, width: width,
                color: style.backgroundColor,
                label: label,
                labelX: left + width / 2 + nudgeX,
                labelY: top + lowered + nudgeY,
                isVertical: inner?.first(where: { $0.hasClass("ts-vertical-text") }) != nil,
                noWrap: inner?.first(where: { $0.hasClass("nowrap") }) != nil
            ))
        }
        guard !bars.isEmpty else { return nil }

        var ticks: [GraphicalTimeline.Tick] = []
        var scaleWidth = 4.0
        if let scale = container.first(where: { $0["id"] == "Scale" }) {
            scaleWidth = CSSStyle(scale["style"]).em("width") ?? scaleWidth
            for div in scale.children where div.tag == "div" {
                guard let top = CSSStyle(div["style"]).em("top") else { continue }
                let label = div.textContent.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty { ticks.append(.init(position: top, label: label)) }
            }
        }

        var notes: [GraphicalTimeline.Note] = []
        var notesWidth = 0.0
        if let annotations = container.first(where: { $0["id"] == "Annotations" }) {
            notesWidth = CSSStyle(annotations["style"]).em("width") ?? 10
            for table in annotations.children where table.tag == "table" {
                guard let top = CSSStyle(table["style"]).em("top"),
                      let cell = table.all(where: { $0.tag == "td" }).last,
                      let text = inlineText(of: cell) else { continue }
                let nudge = CSSStyle(cell.first(where: { $0.hasClass("annot-nudge") })?["style"]).em("top") ?? 0
                notes.append(.init(position: top + nudge, text: text))
            }
        }

        return GraphicalTimeline(
            title: container.first(where: { $0["id"] == "Title" }).flatMap { inlineText(of: $0) },
            height: height,
            scaleWidth: scaleWidth,
            width: chartStyle.em("width") ?? bars.map { $0.left + $0.width }.max() ?? 10,
            notesWidth: notesWidth,
            ticks: ticks,
            bars: bars,
            notes: notes,
            caption: container.all(where: { $0["id"] == "Caption" }).last.flatMap { inlineText(of: $0) }
        )
    }

    // MARK: Cladogram

    static func cladogram(_ node: HTMLNode) -> CladeNode? {
        let table = node.tag == "table" ? node : node.first { $0.tag == "table" && $0.hasClass("clade") }
        guard let table else { return nil }
        let root = CladeNode(children: clades(in: table))
        return root.children.isEmpty ? nil : root
    }

    private static func clades(in table: HTMLNode) -> [CladeNode] {
        var nodes: [CladeNode] = []
        for row in rows(of: table) {
            let cells = row.children.filter { $0.tag == "td" }
            if let leaf = cells.first(where: { $0.hasClass("clade-leaf") }) {
                var node = CladeNode()
                node.label = cells.first { $0.hasClass("clade-label") }.flatMap { inlineText(of: $0) }
                if let subclade = leaf.first(where: { $0.tag == "table" && $0.hasClass("clade") }) {
                    node.children = clades(in: subclade)
                } else {
                    node.text = inlineText(of: leaf)
                    node.image = leaf.first { $0.tag == "img" && (Double($0["width"] ?? "") ?? 0) >= 20 }.flatMap(image(from:))
                }
                if node.text != nil || node.image != nil || !node.children.isEmpty { nodes.append(node) }
            } else if let sublabel = cells.first(where: { $0.hasClass("clade-slabel") }), !nodes.isEmpty {
                nodes[nodes.count - 1].sublabel = inlineText(of: sublabel)
            }
        }
        return nodes
    }

    // MARK: Location map

    static func locationMap(_ node: HTMLNode) -> (LocationMap, caption: AttributedString?)? {
        guard let canvas = node.first(where: { $0.tag == "div" && CSSStyle($0["style"])["position"] == "relative" }),
              let base = canvas.first(where: { $0.tag == "img" && !$0.isInside { $0.hasClass("od") } }),
              let image = image(from: base) else { return nil }
        var markers: [LocationMap.Marker] = []
        for dot in canvas.all(where: { $0.hasClass("od") }) {
            let style = CSSStyle(dot["style"])
            guard let y = style.percent("top"), let x = style.percent("left") else { continue }
            let label = dot.children.first { $0.tag == "div" && !$0.hasClass("id") }.flatMap { inlineText(of: $0) }
            let file = dot.first { $0.tag == "img" }?["src"]?.lowercased() ?? ""
            markers.append(.init(x: x, y: y, label: label, color: markerColor(file)))
        }
        // The caption is whatever sits beside the canvas, or a thumb caption.
        var caption = node.first(where: { $0.hasClass("thumbcaption") }).flatMap { inlineText(of: $0) }
        if caption == nil, let wrapper = canvas.parent {
            var builder = InlineBuilder()
            for child in wrapper.children where child !== canvas { builder.inline(child, style: InlineStyle()) }
            let text = builder.result()
            if !text.characters.isEmpty { caption = text }
        }
        return (LocationMap(image: image, markers: markers), caption)
    }

    private static func markerColor(_ file: String) -> UInt32 {
        let colors: [(String, UInt32)] = [
            ("red", 0xFF5A5F), ("green", 0x55E6A5), ("blue", 0x5AA9FF), ("yellow", 0xFFD166),
            ("orange", 0xFFB86C), ("purple", 0xBF8EE8), ("black", 0xE8E8E8), ("white", 0xFFFFFF),
        ]
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return colors.first { name.contains($0.0) }?.1 ?? 0xFF5A5F
    }

    // MARK: Geological range

    static func geologicRange(in node: HTMLNode) -> GeologicRange? {
        guard let row = node.first(where: { $0["id"] == "Timeline-row" }) else { return nil }
        guard let total = CSSStyle(row["style"]).px("width"), total > 0 else { return nil }
        var periods: [GeologicRange.Period] = []
        var rangeStart = Double.infinity
        var rangeEnd = -Double.infinity
        for div in row.children where div.tag == "div" {
            let style = CSSStyle(div["style"])
            if div["id"] == "end-border" { continue }
            if let left = style.px("left"), let width = style.px("width") {
                let label = div.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let link = div.first { $0.tag == "a" }?["href"].flatMap { WikiLink.resolve(href: $0, isRedLink: false) }
                periods.append(.init(start: left / total, width: width / total, color: style.backgroundColor, label: label, link: link))
            } else {
                // The span itself: bars along a strip under the periods.
                for bar in div.children where bar.tag == "div" {
                    let barStyle = CSSStyle(bar["style"])
                    guard barStyle.backgroundColor != nil, let left = barStyle.px("left"), let width = barStyle.px("width") else { continue }
                    rangeStart = min(rangeStart, left / total)
                    rangeEnd = max(rangeEnd, (left + width) / total)
                }
            }
        }
        guard !periods.isEmpty, rangeStart.isFinite else { return nil }
        // "69–66 Ma" sits beside the bar.
        var text: AttributedString?
        if let holder = row.parent {
            var builder = InlineBuilder()
            for child in holder.children where child !== row { builder.inline(child, style: InlineStyle()) }
            let result = builder.result()
            if !result.characters.isEmpty { text = result }
        }
        // The Precambrian runs off the left edge, under the Cambrian.
        if let first = periods.first, periods.count > 1, first.start + first.width > periods[1].start {
            periods[0].width = periods[1].start - first.start
        }
        return GeologicRange(periods: periods, rangeStart: rangeStart, rangeEnd: max(rangeEnd, rangeStart + 0.004), text: text)
    }
}
