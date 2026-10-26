import SwiftUI
import AppKit

/// Geometry shared by the AppKit tab strip and the SwiftUI page bars. The
/// page bar sits one row below the tabs; content starts beneath both and
/// scrolls up under them, behind a Liquid Glass fade.
enum PageMetrics {
    static let tabBarHeight: CGFloat = TabBarView.cornerPadding + 31 + 8
    static let control: CGFloat = 36
    /// Horizontal inset, matching the tab strip's corner padding.
    static let inset: CGFloat = TabBarView.cornerPadding
    static let barTop: CGFloat = tabBarHeight + 2
    static let barBottom: CGFloat = barTop + control
    /// Where page content starts: below the bar, with room to breathe.
    static let contentTop: CGFloat = barBottom + 12
    /// The glass covers the tabs and the bar, fading out below them.
    static let glassHeight: CGFloat = barBottom + 64
}

/// One line of a page's table of contents.
struct OutlineEntry: Identifiable, Hashable {
    var id: String
    var title: String
    var level: Int
}

/// What the Share button hands to the system share sheet.
enum ShareSpec {
    case none
    case url(URL)
    /// A note plus the local images it embeds.
    case note(URL, images: [URL])
    case text(String)
}

/// Window-wide state the SwiftUI chrome reads: whether the assistant panel
/// is open, and the current page's title, outline, and share items.
@MainActor @Observable
final class WindowChrome {
    /// Where the assistant is: tucked into its button, floating above the
    /// page's lower-right corner, or docked as the right sidebar.
    enum ChatMode { case closed, floating, docked }

    var chatMode = ChatMode.closed
    /// The floating panel shown while the docked sidebar is dragged out.
    var chatPreview = false
    /// False to swap the button and panel without the morph.
    var chatMorphAnimated = true
    var outline: [OutlineEntry] = []
    var share: ShareSpec = .none
    /// Images have no outline; the Contents button stays, disabled.
    var hasOutline = true
    /// The Wikipedia page on screen, if any, for its Back button.
    var page: WikiPage?
    /// The page's title, shown in the bar's pill once its heading scrolls away.
    var title = ""

    @ObservationIgnored var toggleChat: () -> Void = {}
    @ObservationIgnored var jump: (OutlineEntry?) -> Void = { _ in }

    var chatOpen: Bool { chatMode != .closed }
    var chatFloating: Bool { chatMode == .floating || chatPreview }
}

// MARK: - Action cluster

/// The lower-left glass capsule: Contents and Share.
struct PageActions: View {
    let outline: [OutlineEntry]
    let contentsEnabled: Bool
    let share: ShareSpec
    /// nil jumps to the top.
    let onJump: (OutlineEntry?) -> Void

    private let width = PageMetrics.control + 4

    var body: some View {
        HStack(spacing: 0) {
            contents
            shareButton
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(WikiTheme.foreground)
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var contents: some View {
        Menu {
            Button("Top") { onJump(nil) }
            if !outline.isEmpty { Divider() }
            ForEach(outline) { entry in
                Button(String(repeating: "    ", count: max(0, entry.level - 2)) + entry.title) { onJump(entry) }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
                .frame(width: width, height: PageMetrics.control)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: width, height: PageMetrics.control)
        .disabled(!contentsEnabled)
        .opacity(contentsEnabled ? 1 : 0.35)
        .help("Contents")
    }

    @ViewBuilder
    private var shareButton: some View {
        let icon = Image(systemName: "square.and.arrow.up").frame(width: width, height: PageMetrics.control)
        switch share {
        case .none:
            icon.opacity(0.35).help("Nothing to share yet")
        case .url(let url):
            ShareLink(item: url) { icon }.buttonStyle(.plain).help("Share")
        case .text(let text):
            ShareLink(item: text) { icon }.buttonStyle(.plain).help("Share")
        case .note(let url, let images) where images.isEmpty:
            ShareLink(item: url) { icon }.buttonStyle(.plain).help("Share")
        case .note(let url, let images):
            Menu {
                ShareLink("Note", item: url)
                ShareLink("Note and \(images.count) image\(images.count == 1 ? "" : "s")", items: [url] + images)
                ShareLink("Images only", items: images)
            } label: { icon }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(width: width, height: PageMetrics.control)
                .help("Share")
        }
    }
}

/// The cluster for every page, hosted above the window's glass. It reads
/// the current page's outline and share items from the window chrome.
struct PageActionsView: View {
    let chrome: WindowChrome

    var body: some View {
        PageActions(outline: chrome.outline, contentsEnabled: chrome.hasOutline,
                    share: chrome.share, onJump: chrome.jump)
            .tint(WikiTheme.foreground)
            .preferredColorScheme(.dark)
            .fixedSize()
    }
}

// MARK: - Assistant dock

/// The assistant's floating home in the page's lower-right corner: a glass
/// button that morphs into a chat panel, keeping its bottom-right corner
/// and corner radius, and morphs back when minimized. The hosting view is
/// always the open panel's size; it only takes clicks inside the button
/// while closed.
struct ChatDock: View {
    let chrome: WindowChrome
    let session: AgentSession
    let actions: AgentPanel.Actions

    static let size: CGFloat = 52
    /// Distance from the page's right edge.
    static let margin: CGFloat = 20
    /// Height the button and the status pill beneath it take from the
    /// page's bottom edge.
    static let clearance: CGFloat = size + 10 + 20 + 10
    static let panelSize = CGSize(width: 360, height: 560)
    static let morph = Animation.spring(response: 0.44, dampingFraction: 0.86)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let open = chrome.chatFloating
            let shape = RoundedRectangle(cornerRadius: Self.size / 2, style: .continuous)
            ZStack(alignment: .bottomTrailing) {
                // Glass alone doesn't reliably blur the AppKit text beneath;
                // once open, a near-opaque backdrop keeps the chat legible.
                WikiTheme.background.opacity(open ? 0.94 : 0)
                if open {
                    AgentPanel(session: session, style: .floating, actions: actions)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity.animation(.easeOut(duration: open ? 0.22 : 0.12)))
                } else {
                    Button(action: chrome.toggleChat) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(WikiTheme.foreground)
                            .frame(width: Self.size, height: Self.size)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .help("Ask the Assistant (⌘J)")
                    .accessibilityLabel("Assistant")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: open ? proxy.size.width : Self.size,
                   height: open ? proxy.size.height : Self.size, alignment: .bottomTrailing)
            .clipShape(shape)
            .glassEffect(.regular.interactive(!open), in: shape)
            .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 18, y: 6)
            // Reduce Motion cross-fades between button and panel instead.
            .id(reduceMotion ? open : false)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .animation(chrome.chatMorphAnimated ? (reduceMotion ? .easeInOut(duration: 0.2) : Self.morph) : nil,
                   value: chrome.chatFloating)
        .tint(WikiTheme.foreground)
        .preferredColorScheme(.dark)
    }
}

/// Where a floating panel dragged to the window's right edge will dock.
final class ChatDockHint: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.foreground.withAlphaComponent(0.10).cgColor
        layer?.borderColor = Theme.foreground.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = ChatDock.size / 2
        layer?.cornerCurve = .continuous
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var isShowing = false

    func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        isShowing = showing
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = showing ? 1 : 0
        }
    }
}

// MARK: - Glass

/// The glass behind the tab strip and page bar: AppKit's Liquid Glass, so
/// it samples whatever page scrolls beneath it (SwiftUI glass in a hosting
/// view doesn't blur the AppKit text view, or reliably its own scroll
/// content), fading out below the bar. Installed only while content is
/// under the tabs: a live backdrop otherwise keeps the window on the
/// slower compositing path.
final class PageGlassBackdrop: NSView {
    private var glass: NSGlassEffectView?
    private let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.85).cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.55, 1]
        // Layer coordinates are bottom-up here: opaque at the window's top.
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
        glass?.frame = bounds
    }

    var isShowing: Bool { glass != nil }

    func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        if showing {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = 0
            // A touch of the window's own tint keeps text over the glass legible.
            glass.tintColor = Theme.background.withAlphaComponent(0.35)
            glass.alphaValue = 0
            addSubview(glass)
            self.glass = glass
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                glass.animator().alphaValue = 1
            }
        } else if let glass {
            self.glass = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                glass.animator().alphaValue = 0
            }, completionHandler: { glass.removeFromSuperview() })
        }
    }
}

// MARK: - Hosting

/// Hosts SwiftUI inside the AppKit window without letting it claim the
/// titlebar safe area or bridge into the window's (shape-only) toolbar.
final class PageHostingView<Content: View>: NSHostingView<Content> {
    /// Click-through views never take mouse events (the glass overlay).
    var passesThrough = false
    /// Limits clicks to part of the view, in its own coordinates.
    var hitRegion: ((NSView, NSPoint) -> Bool)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sceneBridgingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if passesThrough { return nil }
        if let hitRegion, let superview, !hitRegion(self, convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Wikipedia tab

/// The root of a Wikipedia (or home) tab: the page and its full-window
/// image viewer. Its bar (Back, title, actions) lives above the window's
/// glass, in `WikiBackButton`, `WikiTitlePill`, and `PageActionsView`.
struct WikiTabView: View {
    let page: WikiPage

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if let route = page.route {
                    ArticleScreen(route: route).id(route.id)
                } else {
                    HomeView()
                }
            }
            .opacity(page.viewer == nil ? 1 : 0)
            .allowsHitTesting(page.viewer == nil)
            .transition(.opacity)

            if let item = page.viewer {
                ImageViewer(image: item.image, caption: item.caption) {
                    withAnimation(.easeInOut(duration: 0.2)) { page.viewer = nil }
                }
                .padding(.top, PageMetrics.tabBarHeight - 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page.route?.id)
        .animation(.easeInOut(duration: 0.2), value: page.viewer?.id)
        .environment(page)
        .environment(\.openURL, OpenURLAction { page.handle($0) })
        .tint(WikiTheme.foreground)
        .preferredColorScheme(.dark)
    }
}

/// Wikipedia's Back button, at the start of the bar under the tabs.
struct WikiBackButton: View {
    let chrome: WindowChrome

    var body: some View {
        Button { chrome.page?.goBack() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WikiTheme.foreground)
                .frame(width: PageMetrics.control, height: PageMetrics.control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Back (⌘[)")
        .preferredColorScheme(.dark)
        .fixedSize()
    }
}

/// The page's title, centered in the bar once its heading scrolls away.
struct WikiTitlePill: View {
    let chrome: WindowChrome

    var body: some View {
        Text(chrome.title)
            .font(WikiTheme.interface(size: 14, weight: .semibold))
            .foregroundStyle(WikiTheme.heading)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: PageMetrics.control)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: 420)
            .preferredColorScheme(.dark)
            .fixedSize(horizontal: false, vertical: true)
    }
}
