import SwiftUI

/// One article, laid out under the window's glass chrome: the page scrolls
/// beneath the tab strip and the article bar up to the window's top edge.
struct ArticleScreen: View {
    let route: ArticleRoute

    @Environment(WikiPage.self) private var page
    @AppStorage(WikiTheme.fontSizeKey, store: AppState.defaults) private var fontSize = WikiTheme.defaultFontSize
    @AppStorage(WikiTheme.bodyFontKey, store: AppState.defaults) private var bodyFamily = WikiTheme.defaultBodyFamily

    private enum Phase {
        case loading
        case loaded(Article)
        case failed(Error)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0

    private var font: ReaderFont { ReaderFont(family: bodyFamily, size: fontSize) }

    var body: some View {
        @Bindable var page = page
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: WikiTheme.maxTextWidth, alignment: .leading)
                    .padding(.horizontal, WikiTheme.padding)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, ChatDock.clearance + 16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .contentMargins(.top, PageMetrics.contentTop, for: .scrollContent)
            .contentMargins(.top, PageMetrics.contentTop, for: .scrollIndicators)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 90
            } action: { _, isPast in
                withAnimation(.easeInOut(duration: 0.2)) { page.showsTitle = isPast }
            }
            .onChange(of: page.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                page.scrollTarget = nil
            }
        }
        .task(id: attempt) { await load() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            LoadingView(title: route.isRandom ? nil : route.query, font: font)
                .transition(.opacity)
        case .failed(let error):
            FailureView(error: error, query: route.query) { attempt += 1 } searchAgain: { page.goHome() }
                .transition(.opacity)
        case .loaded(let article):
            ArticleBody(article: article, font: font) { item in
                withAnimation(.easeInOut(duration: 0.2)) { page.viewer = item }
            }
            .transition(.opacity.combined(with: .offset(y: 12)))
        }
    }

    // MARK: Loading

    private func load() async {
        if let cached = page.cachedArticle(for: route), attempt == 0 {
            phase = .loaded(cached)
            return
        }
        if attempt > 0 { withAnimation { phase = .loading } }
        do {
            var query = route.query
            if route.isRandom { query = try await WikipediaClient.randomTitle() }
            let article = try await WikipediaClient.article(for: query)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { phase = .loaded(article) }
            page.loaded(article, for: route)
            if let fragment = route.fragment {
                let wanted = fragment.replacingOccurrences(of: " ", with: "_").lowercased()
                if let section = article.blocks.lazy.compactMap({ block -> String? in
                    if case .heading(_, _, let anchor) = block.kind, anchor.lowercased() == wanted { return anchor }
                    return nil
                }).first {
                    try? await Task.sleep(for: .milliseconds(450))
                    page.scrollTarget = section
                }
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut) { phase = .failed(error) }
        }
    }
}

// MARK: - Article body

private struct ArticleBody: View {
    let article: Article
    let font: ReaderFont
    var onImage: (ViewerItem) -> Void

    private enum Row: Identifiable {
        case block(Block)
        case infobox
        var id: Int {
            switch self {
            case .block(let block): block.id
            case .infobox: -1
            }
        }
    }

    /// Like Wikipedia's mobile layout: the infobox follows the first paragraph.
    private var rows: [Row] {
        var rows = article.blocks.map(Row.block)
        if !article.infobox.isEmpty {
            let firstParagraph = article.blocks.firstIndex { if case .paragraph = $0.kind { true } else { false } }
            rows.insert(.infobox, at: min((firstParagraph ?? -1) + 1, rows.count))
        }
        return rows
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: font.size * 0.85) {
            header
                .id("top")
            ForEach(rows) { row in
                switch row {
                case .infobox:
                    InfoboxView(rows: article.infobox, title: article.title, font: font, onImage: onImage)
                        .padding(.vertical, 6)
                        .id("infobox")
                case .block(let block):
                    BlockView(block: block, font: font, onImage: onImage)
                        .id(anchor(of: block) ?? "block-\(block.id)")
                }
            }
            footer
        }
    }

    private func anchor(of block: Block) -> String? {
        if case .heading(_, _, let anchor) = block.kind { return anchor }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(article.title)
                .font(font.scaled(1.9).weight(.semibold))
                .foregroundStyle(WikiTheme.heading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let summary = article.summary {
                Text(summary)
                    .font(font.scaled(0.92).italic())
                    .foregroundStyle(WikiTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let image = article.leadImage {
                ImageTile(image: image, maxHeight: 380) { onImage(ViewerItem(image: image, caption: article.leadCaption)) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                if let caption = article.leadCaption {
                    Text(WikiTheme.styled(caption))
                        .font(font.scaled(0.8))
                        .foregroundStyle(WikiTheme.secondary)
                        .tint(WikiTheme.link.opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(WikiTheme.hairline).frame(height: 1)
            Text("From Wikipedia, the free encyclopedia. Text is available under the Creative Commons Attribution-ShareAlike 4.0 License.")
                .font(WikiTheme.interface(size: 12))
                .foregroundStyle(WikiTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: article.url) {
                Label("Read on Wikipedia", systemImage: "safari")
                    .font(WikiTheme.interface(size: 12))
            }
            .foregroundStyle(WikiTheme.link)
        }
        .padding(.top, 24)
    }
}

// MARK: - Loading & failure

private struct LoadingView: View {
    let title: String?
    let font: ReaderFont
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(font.scaled(1.9).weight(.semibold))
                    .foregroundStyle(WikiTheme.heading.opacity(0.55))
                    .lineLimit(2)
            } else {
                bar(width: 0.55, height: font.size * 1.6)
            }
            bar(width: 0.4, height: font.size * 0.8).padding(.bottom, 8)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WikiTheme.wash.opacity(0.05))
                .frame(height: 200)
                .padding(.bottom, 8)
            ForEach(0..<9, id: \.self) { index in
                bar(width: [1, 0.96, 0.92, 0.98, 0.7, 1, 0.94, 0.88, 0.6][index], height: font.size * 0.75)
            }
        }
        .mask {
            LinearGradient(
                stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .black, location: 0.5), .init(color: .black.opacity(0.45), location: 1)],
                startPoint: .init(x: shimmer ? 1 : -1, y: 0),
                endPoint: .init(x: shimmer ? 2 : 0, y: 0)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = true }
        }
        .accessibilityLabel("Loading article")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2.5, style: .continuous)
                .fill(WikiTheme.wash.opacity(0.08))
                .frame(width: proxy.size.width * width)
        }
        .frame(height: height)
    }
}

private struct FailureView: View {
    let error: Error
    let query: String
    var retry: () -> Void
    var searchAgain: () -> Void

    private var isNotFound: Bool {
        if case WikiError.notFound = error { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isNotFound ? "text.page.badge.magnifyingglass" : "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(WikiTheme.heading)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(isNotFound ? "No article found" : "Couldn’t load the article")
                .font(WikiTheme.interface(size: 18, weight: .semibold))
                .foregroundStyle(WikiTheme.heading)
            Text(error.localizedDescription)
                .font(WikiTheme.interface(size: 14))
                .foregroundStyle(WikiTheme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if !isNotFound {
                    Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.glassPill)
                }
                Button("New Search", systemImage: "magnifyingglass", action: searchAgain)
                    .buttonStyle(.glassPill)
            }
            .font(WikiTheme.interface(size: 14))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

