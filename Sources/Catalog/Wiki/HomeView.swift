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
                VStack(spacing: 30) {
                    masthead
                    VStack(spacing: 20) {
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
                            .frame(maxWidth: isLauncher ? nil : 460)
                    }
                    .zIndex(1)
                    shortcuts
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, WikiTheme.padding)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            recentFiles = page.homeActions?.recentFiles() ?? []
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { appeared = true }
            searchFocused = true
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
        // Logo and wordmark on one line.
        HStack(spacing: 14) {
            Image(systemName: isLauncher ? "text.book.closed.fill" : "book.closed.fill")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(WikiTheme.heading.gradient)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
            Text(isLauncher ? "Catalog" : "Encyclopedia")
                .font(.custom("Hoefler Text", fixedSize: 46).weight(.semibold))
                .foregroundStyle(WikiTheme.heading)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    private var searchField: some View {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let expanded = !suggestions.isEmpty
        // Rounded like a capsule at field height; suggestions extend the
        // same shape downward instead of floating as a separate card.
        let shape = RoundedRectangle(cornerRadius: fieldHeight / 2, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(searchFocused ? WikiTheme.foreground : WikiTheme.secondary)
                TextField("Search Wikipedia", text: $query)
                    .textFieldStyle(.plain)
                    .font(WikiTheme.interface(interfaceFamily, size: 16))
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
                            .font(.system(size: 16))
                            .foregroundStyle(WikiTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(0.6)))
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: fieldHeight)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }

            if expanded {
                Rectangle()
                    .fill(WikiTheme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                suggestionRows
            }
        }
        .background(WikiTheme.background.opacity(expanded ? 0.85 : 0), in: shape)
        .overlay(shape.strokeBorder(WikiTheme.hairline, lineWidth: 1).opacity(expanded ? 1 : 0))
        .glassEffect(.regular.interactive(), in: shape)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: hasQuery)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
        .task(id: query) { await loadSuggestions() }
    }

    /// The text field centers its line box (ascender to descender), which
    /// seats capitals high; this moves their middle to the field's middle.
    private var capCentering: CGFloat {
        guard let font = NSFontManager.shared.font(withFamily: WikiTheme.interfaceFamily(interfaceFamily),
                                                   traits: [], weight: 5, size: 16) else { return 0 }
        return (max(0, font.capHeight - font.ascender - font.descender)).rounded() / 2
    }

    /// As tall as the action pills (so the same capsule), whatever the font.
    private var fieldHeight: CGFloat {
        isLauncher && actionsSize.height > 0 ? actionsSize.height : 44
    }

    /// Article titles starting with the query; ↑/↓ pick one, Return opens it.
    private var suggestionRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, title in
                Button { pick(title) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WikiTheme.secondary)
                        Text(title)
                            .font(WikiTheme.interface(interfaceFamily, size: 16))
                            .foregroundStyle(WikiTheme.foreground)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
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
        guard !Task.isCancelled else { return }
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
        .buttonStyle(GlassPillStyle(horizontal: 20, vertical: 12))
        // Each pill keeps its natural width in the interface font, and the
        // search field spans the row.
        .font(WikiTheme.interface(interfaceFamily, size: 16))
        .lineLimit(1)
        .fixedSize()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private var shortcuts: some View {
        VStack(spacing: 18) {
            if isLauncher && !recentFiles.isEmpty {
                chips("Recent files", items: recentFiles.prefix(8).map { ($0.path, $0.lastPathComponent) }) { path in
                    page.homeActions?.openRecent(URL(fileURLWithPath: path))
                }
            }
            if !WikiRecents.shared.titles.isEmpty {
                chips("Recently read", items: WikiRecents.shared.titles.prefix(8).map { ($0, $0) },
                      onTap: { page.open($0) },
                      onForget: { title in withAnimation(.snappy) { WikiRecents.shared.forget(title) } })
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private func chips(_ heading: String, items: [(id: String, label: String)],
                       onTap: @escaping (String) -> Void,
                       onForget: ((String) -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            Text(heading)
                .font(WikiTheme.interface(interfaceFamily, size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(WikiTheme.dim)
            FlowLayout(spacing: 8, alignment: .center) {
                ForEach(items, id: \.id) { item in
                    Button {
                        onTap(item.id)
                    } label: {
                        Text(item.label)
                            .font(WikiTheme.interface(interfaceFamily, size: 15))
                            .foregroundStyle(WikiTheme.foreground.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .background(WikiTheme.wash.opacity(0.05), in: Capsule())
                    .overlay(Capsule().strokeBorder(WikiTheme.hairline, lineWidth: 1))
                    .help(item.id)
                    .contextMenu {
                        if let onForget {
                            Button("Remove from Recents", systemImage: "minus.circle") { onForget(item.id) }
                        }
                    }
                }
            }
        }
        .transition(.opacity)
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
