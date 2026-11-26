import AppKit
import SwiftUI

/// The first page of a window and of every new Wikipedia tab. As the home
/// tab it is a launcher — Wikipedia, a folder, a file, or a blank note; as a
/// Wikipedia tab it is Encyclopedia's search page.
struct HomeView: View {
    @Environment(WikiPage.self) private var page
    /// Settings' interface font; read here so the page restyles live.
    @AppStorage(Theme.interfaceFontKey, store: AppState.defaults) private var interfaceFamily = Theme.defaultInterfaceFontFamily

    @State private var query = ""
    @State private var appeared = false
    @State private var recentFiles: [URL] = []
    @State private var actionsSize: CGSize = .zero
    @State private var suggestions: [String] = []
    @State private var highlighted: Int?
    @FocusState private var searchFocused: Bool

    private var isLauncher: Bool { page.style == .home }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: PageMetrics.contentTop)
                VStack(spacing: 26) {
                    masthead
                    VStack(spacing: 16) {
                        if isLauncher {
                            launcherActions
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { actionsSize = $0 }
                        }
                        // Spans the action pills exactly, or a fixed column
                        // on a Wikipedia tab.
                        // Lays out at field height; the open suggestion list
                        // draws over the content below rather than pushing it.
                        Color.clear
                            .frame(height: fieldHeight)
                            .overlay(alignment: .top) { searchField.fixedSize(horizontal: false, vertical: true) }
                            .frame(width: isLauncher && actionsSize.width > 0 ? actionsSize.width : nil)
                            .frame(maxWidth: isLauncher ? nil : 420)
                    }
                    .zIndex(1)
                    shortcuts
                        .frame(width: isLauncher && actionsSize.width > 0 ? actionsSize.width : nil)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, WikiTheme.padding)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height }
            // Clicking the page outside a control leaves the search field.
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = false }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            recentFiles = page.homeActions?.recentFiles() ?? []
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { appeared = true }
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if focused {
                Task { await loadSuggestions() }
            } else {
                // After any click on a suggestion has landed.
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !searchFocused { withAnimation(.snappy(duration: 0.2)) { suggestions = [] } }
                }
            }
        }
        .onChange(of: page.searchFocusRequest) {
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                searchFocused = true
            }
        }
    }

    // MARK: Pieces

    private var masthead: some View {
        // Logo and wordmark on one line, the logo centered on the capitals.
        HStack(alignment: .capCenter, spacing: 12) {
            Image(systemName: isLauncher ? "text.book.closed.fill" : "book.closed.fill")
                .font(.system(size: 31, weight: .regular))
                .alignmentGuide(.capCenter) { $0[VerticalAlignment.center] }
                .foregroundStyle(WikiTheme.heading.gradient)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
            Text(isLauncher ? "Catalog" : "Encyclopedia")
                .font(.custom("Hoefler Text", fixedSize: Self.wordmarkSize).weight(.semibold))
                .alignmentGuide(.capCenter) { $0[.firstTextBaseline] - Self.wordmarkCapHeight / 2 }
                .foregroundStyle(WikiTheme.heading)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    /// The pills', search field's, and suggestions' text size.
    private static let textSize: CGFloat = 14
    private static let wordmarkSize: CGFloat = 40
    private static let wordmarkCapHeight: CGFloat =
        NSFontManager.shared.font(withFamily: "Hoefler Text", traits: .boldFontMask, weight: 9, size: wordmarkSize)?.capHeight
            ?? wordmarkSize * 0.66

    private var searchField: some View {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let expanded = !suggestions.isEmpty
        // Rounded like a capsule at field height; suggestions extend the
        // same shape downward instead of floating as a separate card.
        let shape = RoundedRectangle(cornerRadius: fieldHeight / 2, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(searchFocused ? WikiTheme.foreground : WikiTheme.secondary)
                TextField("Search Wikipedia", text: $query)
                    .textFieldStyle(.plain)
                    .font(WikiTheme.interface(interfaceFamily, size: Self.textSize))
                    .foregroundStyle(WikiTheme.foreground)
                    .offset(y: capCentering)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .onSubmit(go)
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onKeyPress(.escape) {
                        guard !suggestions.isEmpty else { return .ignored }
                        suggestions = []
                        return .handled
                    }
                if hasQuery {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(WikiTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(0.6)))
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: fieldHeight)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }

            if expanded {
                Rectangle()
                    .fill(WikiTheme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 14)
                suggestionRows
            }
        }
        .overlay(shape.strokeBorder(WikiTheme.hairline, lineWidth: 1).opacity(expanded ? 1 : 0))
        // Translucent like the assistant: the open list crossfades from
        // SwiftUI glass to AppKit glass, which blurs the page beneath.
        .background {
            ZStack {
                Color.clear
                    .glassEffect(.regular.interactive(), in: shape)
                    .opacity(expanded ? 0 : 1)
                PanelGlass(tint: ChatDock.panelTint, cornerRadius: fieldHeight / 2)
                    .opacity(expanded ? 1 : 0)
            }
            .shadow(color: .black.opacity(expanded ? 0.25 : 0), radius: 16, y: 6)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: hasQuery)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .task(id: query) { await loadSuggestions() }
    }

    /// The text field centers its line box (ascender to descender), which
    /// seats capitals high; this moves their middle to the field's middle.
    private var capCentering: CGFloat {
        guard let font = NSFontManager.shared.font(withFamily: WikiTheme.interfaceFamily(interfaceFamily),
                                                   traits: [], weight: 5, size: Self.textSize) else { return 0 }
        return (max(0, font.capHeight - font.ascender - font.descender)).rounded() / 2
    }

    /// As tall as the action pills (so the same capsule), whatever the font.
    private var fieldHeight: CGFloat {
        isLauncher && actionsSize.height > 0 ? actionsSize.height : 38
    }

    /// Article titles starting with the query; ↑/↓ pick one, Return opens it.
    private var suggestionRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, title in
                Button { pick(title) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WikiTheme.secondary)
                        Text(title)
                            .font(WikiTheme.interface(interfaceFamily, size: Self.textSize))
                            .foregroundStyle(WikiTheme.foreground)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(index == highlighted ? WikiTheme.wash.opacity(0.08) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(.vertical, 6)
        .padding(.bottom, 4)
    }

    private func loadSuggestions() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let titles = (try? await WikipediaClient.suggestions(for: term)) ?? []
        guard !Task.isCancelled, searchFocused else { return }
        withAnimation(.snappy(duration: 0.2)) {
            suggestions = titles
            highlighted = nil
        }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let next = (highlighted ?? -1) + delta
        highlighted = next < 0 ? nil : min(next, suggestions.count - 1)
        return .handled
    }

    /// The launcher's other starting points, above Wikipedia's search.
    private var launcherActions: some View {
        HStack(spacing: 10) {
            Button { page.homeActions?.newNote() } label: {
                Label("Blank Note", systemImage: "square.and.pencil")
            }
            Button { page.homeActions?.openFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
            Button { page.homeActions?.openFile() } label: {
                Label("Open File", systemImage: "doc")
            }
        }
        .buttonStyle(GlassPillStyle(horizontal: 17, vertical: 10))
        // Each pill keeps its natural width in the interface font, and the
        // search field spans the row.
        .font(WikiTheme.interface(interfaceFamily, size: Self.textSize))
        .lineLimit(1)
        .fixedSize()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    /// A recent file or article, for the single Recent list.
    private struct RecentItem: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let open: () -> Void
        var forget: (() -> Void)?
    }

    /// Files and articles together, most recently opened first; entries from
    /// before opening times were kept follow in their own lists' order.
    private var recentItems: [RecentItem] {
        var items: [RecentItem] = []
        if isLauncher {
            items += recentFiles.map { url in
                RecentItem(id: "file:" + url.path, label: url.lastPathComponent, symbol: "doc.text",
                           open: { page.homeActions?.openRecent(url) })
            }
        }
        items += WikiRecents.shared.titles.map { title in
            RecentItem(id: "wiki:" + title, label: title, symbol: "book",
                       open: { page.open(title) },
                       forget: { withAnimation(.snappy) { WikiRecents.shared.forget(title) } })
        }
        let times = RecentTimes.all
        return items.enumerated()
            .sorted { a, b in
                let (ta, tb) = (times[a.element.id] ?? 0, times[b.element.id] ?? 0)
                return ta != tb ? ta > tb : a.offset < b.offset
            }
            .prefix(10)
            .map(\.element)
    }

    private var shortcuts: some View {
        let items = recentItems
        return VStack(spacing: 10) {
            if !items.isEmpty {
                Text("Recent")
                    .font(WikiTheme.interface(interfaceFamily, size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(WikiTheme.dim)
                FlowLayout(spacing: 8, alignment: .center) {
                    ForEach(items) { item in
                        Button(action: item.open) {
                            HStack(spacing: 6) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(WikiTheme.secondary)
                                Text(item.label)
                                    .font(WikiTheme.interface(interfaceFamily, size: 13))
                                    .foregroundStyle(WikiTheme.foreground.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .background(WikiTheme.wash.opacity(0.05), in: Capsule())
                        .overlay(Capsule().strokeBorder(WikiTheme.hairline, lineWidth: 1))
                        .help(item.label)
                        .contextMenu {
                            if let forget = item.forget {
                                Button("Remove from Recents", systemImage: "minus.circle", action: forget)
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private var footer: some View {
        Text("Articles from Wikipedia · CC BY-SA 4.0")
            .font(WikiTheme.interface(interfaceFamily, size: 11))
            .foregroundStyle(WikiTheme.dim)
            .padding(.bottom, 16)
            .padding(.top, 24)
    }

    private func go() {
        if let highlighted, suggestions.indices.contains(highlighted) {
            pick(suggestions[highlighted])
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pick(trimmed)
    }

    private func pick(_ title: String) {
        searchFocused = false
        suggestions = []
        highlighted = nil
        page.open(title)
        query = ""
    }
}

/// Wraps chips onto as many centered lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = arrange(subviews, maxWidth: maxWidth)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, maxWidth: bounds.width) {
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - line.width) / 2
            case .trailing: x = bounds.maxX - line.width
            default: x = bounds.minX
            }
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), proposal: .init(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: maxWidth, height: nil))
            let needed = lines[lines.count - 1].indices.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if needed > maxWidth && !lines[lines.count - 1].indices.isEmpty {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines[lines.count - 1] = line
        }
        return lines.filter { !$0.indices.isEmpty }
    }
}

private extension VerticalAlignment {
    /// The middle of a line's capital letters.
    enum CapCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let capCenter = VerticalAlignment(CapCenter.self)
}
