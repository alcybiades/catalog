import SwiftUI
import AppKit

/// Recently read articles, shared by every Wikipedia tab.
@MainActor @Observable
final class WikiRecents {
    static let shared = WikiRecents()
    private static let key = "wikiRecents"
    private(set) var titles: [String]

    private init() {
        titles = AppState.defaults.stringArray(forKey: Self.key) ?? []
    }

    func record(_ title: String) {
        var list = titles.filter { $0.caseInsensitiveCompare(title) != .orderedSame }
        list.insert(title, at: 0)
        titles = Array(list.prefix(12))
        AppState.defaults.set(titles, forKey: Self.key)
    }

    func forget(_ title: String) {
        titles.removeAll { $0 == title }
        AppState.defaults.set(titles, forKey: Self.key)
    }
}

/// What the home page asks its window to do.
struct HomeActions {
    var newNote: () -> Void
    var openFolder: () -> Void
    var openFile: () -> Void
    var openRecent: (URL) -> Void
    var recentFiles: () -> [URL]
}

/// One Wikipedia tab: its reading history, loaded articles, and scroll
/// requests. A home tab is the same page with the launcher masthead.
@MainActor @Observable
final class WikiPage {
    enum Style { case home, wikipedia }

    let style: Style
    private(set) var path: [ArticleRoute] = []
    private var articles: [UUID: Article] = [:]
    /// The page's own title has scrolled under the glass.
    var showsTitle = false { didSet { if showsTitle != oldValue { onChromeChange?() } } }
    var scrollTarget: String?
    var viewer: ViewerItem? { didSet { if (viewer == nil) != (oldValue == nil) { onChromeChange?() } } }
    private(set) var searchFocusRequest = 0

    @ObservationIgnored var homeActions: HomeActions?
    /// Title or article changed; the window refreshes its tab strip.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The title scrolled under the glass, or the image viewer opened or
    /// closed; the window updates its glass and bar.
    @ObservationIgnored var onChromeChange: (() -> Void)?
    /// The tab's hosting view, created once and kept while the tab lives so
    /// switching tabs preserves scroll position and loaded images.
    @ObservationIgnored var hostView: NSView?

    init(style: Style) {
        self.style = style
    }

    var route: ArticleRoute? { path.last }
    var article: Article? { route.flatMap { articles[$0.id] } }
    var canGoBack: Bool { !path.isEmpty }

    var title: String {
        if let article { return article.title }
        if let route { return route.isRandom ? "Random article" : route.query }
        return style == .home ? "Home" : "Wikipedia"
    }

    func open(_ query: String, fragment: String? = nil) {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var fragment = fragment
        // Titles can't contain "#", so "Kyoto#History" means a section.
        if fragment == nil, let hash = trimmed.firstIndex(of: "#") {
            let section = trimmed[trimmed.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            fragment = section.isEmpty ? nil : section
            trimmed = trimmed[..<hash].trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { return }
        push(ArticleRoute(query: trimmed, fragment: fragment))
    }

    func openRandom() {
        push(ArticleRoute(query: "", isRandom: true))
    }

    func goHome() {
        path.removeAll()
        articles.removeAll()
        settle()
        searchFocusRequest += 1
    }

    func goBack() {
        guard let last = path.popLast() else { return }
        articles[last.id] = nil
        settle()
    }

    /// Records a finished load so going back, the tab title, and the
    /// assistant all see the article.
    func loaded(_ article: Article, for route: ArticleRoute) {
        articles[route.id] = article
        WikiRecents.shared.record(article.title)
        onChange?()
    }

    func cachedArticle(for route: ArticleRoute) -> Article? { articles[route.id] }

    /// Routes taps on in-article links; other URLs go to the system.
    func handle(_ url: URL) -> OpenURLAction.Result {
        if let destination = WikiLink.destination(of: url) {
            open(destination.title, fragment: destination.fragment)
            return .handled
        }
        return .systemAction
    }

    private func push(_ route: ArticleRoute) {
        path.append(route)
        settle()
    }

    private func settle() {
        showsTitle = false
        viewer = nil
        onChange?()
    }
}
