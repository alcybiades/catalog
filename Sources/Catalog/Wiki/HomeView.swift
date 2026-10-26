import SwiftUI

/// The first page of a window and of every new Wikipedia tab. As the home
/// tab it is a launcher — Wikipedia, a folder, a file, or a blank note; as a
/// Wikipedia tab it is Encyclopedia's search page.
struct HomeView: View {
    @Environment(WikiPage.self) private var page
    @AppStorage(WikiTheme.bodyFontKey, store: AppState.defaults) private var bodyFamily = WikiTheme.defaultBodyFamily

    @State private var query = ""
    @State private var appeared = false
    @State private var recentFiles: [URL] = []
    @FocusState private var searchFocused: Bool
    @Namespace private var glass

    private var isLauncher: Bool { page.style == .home }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: PageMetrics.contentTop)
                VStack(spacing: 30) {
                    masthead
                    searchField
                    if isLauncher { launcherActions }
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
        VStack(spacing: 14) {
            Image(systemName: isLauncher ? "text.book.closed.fill" : "book.closed.fill")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(WikiTheme.heading.gradient)
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
                .padding(.bottom, 2)
            Text(isLauncher ? "Catalog" : "Encyclopedia")
                .font(WikiTheme.body(bodyFamily, size: 46).weight(.semibold))
                .foregroundStyle(WikiTheme.heading)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if isLauncher {
                Text("Notes & Encyclopedia")
                    .font(WikiTheme.interface(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(2.4)
                    .foregroundStyle(WikiTheme.foreground.opacity(0.75))
                    .padding(.top, -8)
            }
            Text(isLauncher
                 ? "Start from Wikipedia, a folder of notes, or a blank page."
                 : "Every article on Wikipedia, ready to read and question.")
                .font(WikiTheme.body(bodyFamily, size: 17).italic())
                .foregroundStyle(WikiTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    private var searchField: some View {
        let hasQuery = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(searchFocused ? WikiTheme.foreground : WikiTheme.secondary)
                    TextField("Search Wikipedia", text: $query)
                        .textFieldStyle(.plain)
                        .font(WikiTheme.body(bodyFamily, size: 20))
                        .foregroundStyle(WikiTheme.foreground)
                        .focused($searchFocused)
                        .autocorrectionDisabled()
                        .onSubmit(go)
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
                .padding(.horizontal, 20)
                .frame(height: 58)
                .glassEffect(.regular.interactive(), in: Capsule())
                .glassEffectID("field", in: glass)
                .contentShape(Capsule())
                .onTapGesture { searchFocused = true }

                if hasQuery {
                    Button(action: go) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(WikiTheme.foreground.opacity(0.8))
                    .glassEffectID("go", in: glass)
                    .help("I’m Feeling Lucky")
                    .accessibilityLabel("Go")
                    .transition(.scale(0.5).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: hasQuery)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96)
    }

    /// The launcher's other starting points, beside Wikipedia's search.
    private var launcherActions: some View {
        HStack(spacing: 10) {
            Button { page.homeActions?.newNote() } label: {
                Label("Blank Note", systemImage: "square.and.pencil")
            }
            Button { page.homeActions?.openFolder() } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            Button { page.homeActions?.openFile() } label: {
                Label("Open File…", systemImage: "doc")
            }
        }
        .buttonStyle(.glassPill)
        .font(WikiTheme.interface(size: 14))
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private var shortcuts: some View {
        VStack(spacing: 18) {
            Button {
                page.openRandom()
            } label: {
                Label("Surprise me", systemImage: "dice")
                    .font(WikiTheme.interface(size: 14))
            }
            .buttonStyle(.glassPill)

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
                .font(WikiTheme.interface(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(WikiTheme.dim)
            FlowLayout(spacing: 8, alignment: .center) {
                ForEach(items, id: \.id) { item in
                    Button {
                        onTap(item.id)
                    } label: {
                        Text(item.label)
                            .font(WikiTheme.body(bodyFamily, size: 15))
                            .foregroundStyle(WikiTheme.foreground.opacity(0.9))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .background(Color.white.opacity(0.05), in: Capsule())
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
            .font(WikiTheme.interface(size: 11))
            .foregroundStyle(WikiTheme.dim)
            .padding(.bottom, 16)
            .padding(.top, 24)
    }

    private func go() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchFocused = false
        page.open(trimmed)
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
