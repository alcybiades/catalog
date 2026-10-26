import AppKit

/// One editor window: its own tab set, text view, inline title, status line,
/// and autosave. Menu actions reach the key window's controller through the
/// responder chain.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    private(set) var documents: [Document]
    private(set) var current = 0
    var currentDocument: Document { documents[current] }
    private var tabActivationOrder: [ObjectIdentifier] = []

    private weak var app: AppDelegate?

    private(set) var textView: EditorTextView!
    private var scrollView: NSScrollView!
    private(set) var tabBar: TabBarView!
    private var statusLabel: NSTextField!
    private var statusPill: StatusPill!
    private let sidebarBackdrop = SidebarBackdrop()
    private let sidebar = FolderSidebar()
    private let divider = SidebarDivider()
    private let preview = FilePreview()
    private let browser = FileBrowser()
    /// The icon browser covers the window; the pages beneath fade out.
    private(set) var browsing = false
    private var browseGeneration = 0
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarAnimationID: UUID?
    /// The folder the user opened. Without one, the sidebar browses
    /// ~/Documents, starting collapsed.
    private(set) var workspace: Workspace?
    private(set) var sidebarCollapsed = true
    private(set) var sidebarWidth: CGFloat = 220
    private var previewOrigin: NSRect?
    // The inline title is an always-editable NSTextView: one view for both
    // reading and editing means the glyphs cannot shift when editing starts
    // (NSTextField swaps in a field editor with subtly different metrics).
    private var titleView: NSTextView!
    private var titleReverting = false
    private let titleUndoManager = UndoManager()
    private static let metricsLayoutManager = NSLayoutManager()
    private var selectionToolbar: SelectionToolbar!
    private var autosaveTimer: Timer?
    private var savedFlashTimer: Timer?
    private var outlineTimer: Timer?
    private var lastAutosave = Date()

    // Pages beyond files: Wikipedia tabs host SwiftUI under the tab strip,
    // notes and images get the glass action cluster, and
    // the assistant floats in the lower-right corner or docks at the right.
    let chrome = WindowChrome()
    let agent = AgentSession()
    private var container: NSView!
    private let contentGuide = NSLayoutGuide()
    private var pageActions: PageHostingView<PageActionsView>!
    private var backButton: PageHostingView<WikiBackButton>!
    private var chatHost: PageHostingView<ChatDock>!
    private let dockHint = ChatDockHint()
    private var chatTrailing: NSLayoutConstraint!
    private var chatBottom: NSLayoutConstraint!
    /// Where a header drag started: the mouse and the dock's offsets.
    private var chatDragStart: (mouse: NSPoint, trailing: CGFloat, bottom: CGFloat)?
    private let pageGlass = PageGlassBackdrop()
    private let agentContainer = NSView()
    private var agentHost: PageHostingView<AgentPanel>!
    private let agentDivider = SidebarDivider()
    private var agentWidthConstraint: NSLayoutConstraint!
    var agentOpen: Bool { chrome.chatOpen }
    /// Whether the assistant opens docked as the sidebar, else floating.
    private(set) var agentPrefersDocked = false
    private(set) var agentWidth: CGFloat = 330
    private var reloadingFromDisk = false

    init(documents: [Document] = [], app: AppDelegate?) {
        self.documents = documents.isEmpty ? [Document()] : documents
        self.app = app
        let window = CatalogWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 420, height: 320)
        window.collectionBehavior = [.fullScreenPrimary]
        buildUI()
        recordTabActivation()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let window else { return }
        let container = applyTerminalBackdrop(to: window)
        self.container = container
        container.addLayoutGuide(contentGuide)

        let layoutManager = CodeBackgroundLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        // Zero fragment padding: AppKit anchors background fills sometimes
        // with and sometimes without it, which misaligns code-band edges.
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        documents[0].storage.addLayoutManager(layoutManager)

        textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Without an explicit maxSize the view stops growing vertically, so
        // narrow windows (more wrapping = taller text) can't scroll to the
        // bottom of the document.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.configure()
        textView.delegate = self
        textView.baseDirectoryProvider = { [weak self] in
            self?.currentDocument.url?.deletingLastPathComponent()
        }
        selectionToolbar = SelectionToolbar(textView: textView)

        titleView = NSTextView(frame: .zero)
        titleView.drawsBackground = false
        titleView.isRichText = false
        titleView.allowsUndo = true
        titleView.isVerticallyResizable = false
        titleView.isHorizontallyResizable = false
        titleView.textContainerInset = .zero
        titleView.textContainer?.lineFragmentPadding = 0
        // Single visual line: a huge fixed container width, clipped by frame.
        titleView.textContainer?.widthTracksTextView = false
        titleView.textContainer?.size = NSSize(width: 10000, height: 10000)
        titleView.delegate = self
        textView.addSubview(titleView)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // Notes scroll up under the tab strip and the glass; keep the
        // scroller itself below the tabs.
        scrollView.scrollerInsets = NSEdgeInsets(top: PageMetrics.tabBarHeight, left: 0, bottom: 0, right: 0)

        tabBar = TabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] index in self?.switchTab(to: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onNewTab = { [weak self] anchor in self?.showNewTabMenu(from: anchor) }
        tabBar.onMove = { [weak self] from, to in self?.moveDocument(from: from, to: to) }
        tabBar.dropTarget = { [weak self] screenPoint in
            guard let self else { return nil }
            return self.app?.tabBar(at: screenPoint, excluding: self)
        }
        tabBar.onTransfer = { [weak self] index, bar, destination in
            guard let self, let target = self.app?.controllers.first(where: { $0.tabBar === bar }) else { return }
            self.app?.moveTab(from: self, at: index, to: target, targetIndex: destination)
        }
        tabBar.onDetach = { [weak self] index, cursor, grab in
            guard let self else { return }
            self.app?.moveTab(from: self, at: index, cursor: cursor, grab: grab)
        }
        tabBar.dragPreview = { [weak self] in self?.pagePreview() }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = Theme.interfaceFont(size: 11)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // A translucent backdrop-colored pill, softening text that passes
        // beneath. It must never use Core Image backgroundFilters: one live
        // CI filter anywhere in the layer tree (even on a hidden view) pushes
        // the whole window onto the WindowServer's uncached compositing path,
        // and any full-window damage — a wide translucent gallery scrolling —
        // then saturates a WindowServer core. Because WindowServer also
        // routes input, that starves event delivery too: trackpad scrolling
        // froze until the fingers lifted.
        statusPill = StatusPill(label: statusLabel)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 7
        statusPill.layer?.cornerCurve = .continuous
        statusPill.layer?.masksToBounds = true
        statusPill.translatesAutoresizingMaskIntoConstraints = false

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebarBackdrop)
        container.addSubview(sidebar)
        container.addSubview(divider)
        container.addSubview(preview)
        sidebarWidthConstraint = sidebar.widthAnchor.constraint(equalToConstant: 0)
        tabBar.onToggleSidebar = { [weak self] in
            guard let self else { return }
            self.sidebarCollapsed.toggle(); self.updateSidebar(animated: true); self.app?.sessionChanged()
        }
        sidebar.onToggleSidebar = { [weak self] in
            guard let self else { return }
            self.sidebarCollapsed.toggle(); self.updateSidebar(animated: true); self.app?.sessionChanged()
        }
        sidebar.onBrowse = { [weak self] in self?.setBrowsing(true) }
        sidebar.onRefresh = { [weak self] in self?.workspace?.refreshIndex() }
        sidebar.onOpen = { [weak self] url in self?.openInCurrentTab(url) }
        divider.onResize = { [weak self] width in
            guard let self else { return }
            self.sidebarCollapsed = width < 90
            if !self.sidebarCollapsed { self.sidebarWidth = max(150, min(width, (self.window?.frame.width ?? 640) - 240)) }
            self.updateSidebar(); self.app?.sessionChanged()
        }
        browser.onToggle = { [weak self] in
            guard let self else { return }
            self.setBrowsing(!self.browsing)
        }
        browser.onOpen = { [weak self] url, origin in
            guard let self else { return }
            self.setBrowsing(false)
            self.previewOrigin = origin
            self.openInCurrentTab(url)
            self.previewOrigin = nil
        }
        textView.referenceCandidates = { [weak self] query in
            guard let workspace = self?.workspace else { return [] }
            return workspace.matches(query).map { ($0, FileReference.relativePath(to: $0, from: workspace.root)) }
        }
        textView.onInsertReference = { [weak self] url, range, style in
            guard let self else { return }
            if self.currentDocument.url == nil { self.promptForSaveURL() }
            guard let source = self.currentDocument.url else { return }
            let text: String
            switch style {
            case .markdown:
                text = FileReference.markdown(to: url, from: source)
            case .wiki:
                text = "[[\(self.workspace?.wikiName(for: url) ?? url.deletingPathExtension().lastPathComponent)]]"
            }
            self.textView.insertText(text, replacementRange: range)
        }
        textView.onOpenReference = { [weak self] destination in self?.follow(destination) }
        textView.onOpenWikiLink = { [weak self] target in self?.followWikiLink(target) }
        textView.wikiLinkResolver = { [weak self] target in self?.resolveWikiLink(target) }
        pageActions = PageHostingView(rootView: PageActionsView(chrome: chrome))
        pageActions.sizingOptions = [.intrinsicContentSize]
        backButton = PageHostingView(rootView: WikiBackButton { [chrome] in chrome.page?.goBack() })
        backButton.sizingOptions = [.intrinsicContentSize]
        chatHost = PageHostingView(rootView: ChatDock(chrome: chrome, session: agent, actions: agentActions(docked: false)))
        chatHost.sizingOptions = []
        chatHost.hitRegion = { [weak self] view, point in
            guard let self else { return false }
            if self.chrome.chatFloating { return true }
            let size = ChatDock.size
            let button = NSRect(x: view.bounds.maxX - size, y: view.isFlipped ? view.bounds.maxY - size : 0, width: size, height: size)
            return NSBezierPath(ovalIn: button).contains(point)
        }
        agentHost = PageHostingView(rootView: AgentPanel(session: agent, style: .docked, actions: agentActions(docked: true)))
        agentHost.sizingOptions = []
        agentContainer.wantsLayer = true
        agentContainer.layer?.masksToBounds = true
        for view in [pageGlass, pageActions!, backButton!, chatHost!, dockHint, agentHost!, agentContainer, agentDivider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        agentContainer.addSubview(agentHost)
        agentDivider.onResize = { [weak self] x in
            guard let self, let window = self.window else { return }
            self.agentWidth = max(280, min(window.frame.width - x, 720))
            self.updateAgentPanel(); self.app?.sessionChanged()
        }
        configureAgent()

        // Back to front: pages, then the glass and its controls, then the
        // tab strip over everything, then the assistant beside it all.
        container.addSubview(scrollView)
        container.addSubview(pageGlass)
        container.addSubview(pageActions)
        container.addSubview(backButton)
        container.addSubview(tabBar)
        container.addSubview(statusPill)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.isHidden = true
        container.addSubview(browser)
        container.addSubview(agentContainer)
        container.addSubview(agentDivider)
        container.addSubview(dockHint)
        container.addSubview(chatHost)
        agentWidthConstraint = agentContainer.widthAnchor.constraint(equalToConstant: 0)
        chatTrailing = chatHost.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: chatRest.trailing)
        chatBottom = chatHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: chatRest.bottom)
        // The open panel's size, shrinking to fit small windows.
        let preferredWidth = chatHost.widthAnchor.constraint(equalToConstant: ChatDock.panelSize.width)
        let preferredHeight = chatHost.heightAnchor.constraint(equalToConstant: ChatDock.panelSize.height)
        preferredWidth.priority = .defaultHigh
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth, preferredHeight,
            chatHost.widthAnchor.constraint(lessThanOrEqualTo: contentGuide.widthAnchor, constant: -2 * ChatDock.margin),
            chatHost.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -(PageMetrics.barBottom + 12 - chatRest.bottom)),
            chatHost.widthAnchor.constraint(greaterThanOrEqualToConstant: ChatDock.size),
            chatHost.heightAnchor.constraint(greaterThanOrEqualToConstant: ChatDock.size),
        ])

        NSLayoutConstraint.activate([
            contentGuide.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentGuide.trailingAnchor.constraint(equalTo: agentContainer.leadingAnchor),
            contentGuide.topAnchor.constraint(equalTo: container.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            agentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            agentContainer.topAnchor.constraint(equalTo: container.topAnchor),
            agentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            agentWidthConstraint,
            agentHost.leadingAnchor.constraint(equalTo: agentContainer.leadingAnchor),
            agentHost.topAnchor.constraint(equalTo: agentContainer.topAnchor),
            agentHost.bottomAnchor.constraint(equalTo: agentContainer.bottomAnchor),
            agentHost.trailingAnchor.constraint(equalTo: agentContainer.trailingAnchor),
            agentDivider.centerXAnchor.constraint(equalTo: agentContainer.leadingAnchor),
            agentDivider.widthAnchor.constraint(equalToConstant: 6),
            agentDivider.topAnchor.constraint(equalTo: container.topAnchor),
            agentDivider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pageGlass.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            pageGlass.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            pageGlass.topAnchor.constraint(equalTo: container.topAnchor),
            pageGlass.heightAnchor.constraint(equalToConstant: PageMetrics.glassHeight),
            // Contents and Share sit in the lower-left corner, mirroring the
            // status pill in the lower right: same side inset, same bottom.
            pageActions.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: ChatDock.margin),
            pageActions.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor),
            backButton.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor, constant: PageMetrics.inset),
            backButton.topAnchor.constraint(equalTo: container.topAnchor, constant: PageMetrics.barTop),
            browser.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            browser.topAnchor.constraint(equalTo: container.topAnchor),
            browser.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: agentContainer.leadingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: PageMetrics.tabBarHeight),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor), sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor), sidebarWidthConstraint,
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -3), divider.widthAnchor.constraint(equalToConstant: 6),
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor), divider.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            preview.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor), preview.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            preview.topAnchor.constraint(equalTo: tabBar.bottomAnchor), preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 9),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -9),
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 3),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -3),
            statusPill.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor, constant: -ChatDock.margin),
            statusPill.leadingAnchor.constraint(greaterThanOrEqualTo: pageActions.trailingAnchor, constant: 12),
            statusPill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            chatTrailing, chatBottom,
            dockHint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            dockHint.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            dockHint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            dockHint.widthAnchor.constraint(equalToConstant: 320),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(viewResized),
            name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewResized),
            name: NSView.frameDidChangeNotification, object: textView)
        textView.postsFrameChangedNotifications = true
        // Keep the selection toolbar tracking the text as it scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        // Upper-center placement, like TextEdit/Notes opening a document.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + (visible.height - size.height) * 0.66
            ))
        } else {
            window.center()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(agentWillModifyFile(_:)), name: .agentWillModifyFile, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange), name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(agentDidModifyFiles(_:)), name: .agentDidModifyFiles, object: nil)

        sidebar.setRoot(AgentSession.defaultDirectory)
        sidebar.isWatched = false
        browser.setRoot(AgentSession.defaultDirectory)
        browser.isWatched = false
        applyTheme()
        updateSidebar()
        updateAgentPanel()
        textView.rehighlight()
        let length = (currentDocument.storage.string as NSString).length
        textView.setSelectedRange(NSIntersectionRange(currentDocument.selection, NSRange(location: 0, length: length)))
        updateInsets()
        refreshChrome()
        focusCurrentPage()
    }

    func windowWillClose(_ notification: Notification) {
        agent.store.detach(agent)
        outlineTimer?.invalidate()
        documents.forEach(retire)
        preview.suspend()
        textView.dismissReferences()
        autosaveTimer?.invalidate()
        savedFlashTimer?.invalidate()
        selectionToolbar.teardown()
        NotificationCenter.default.removeObserver(self)
        app?.windowClosed(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        selectionToolbar.hide()
        textView.dismissReferences()
    }

    @objc private func viewResized() {
        updateInsets()
        updateSidebar()
    }

    @objc private func scrolled() {
        selectionToolbar.noteSelectionChanged()
        updatePageGlass()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textView else { return }
        selectionToolbar.noteSelectionChanged()
    }

    private func updateInsets() {
        let titleFont = Theme.boldFont(size: Theme.fontSize * 1.5).font
        let titleHeight = ceil(titleFont.ascender - titleFont.descender) + 6
        // Symmetric breathing room: the gap above the title (below the tab
        // bar) equals the gap between the title and the body text.
        let titleGap = Theme.fontSize * 0.9
        // The scroll view starts at the window's top edge, under the tabs.
        let titleTop = PageMetrics.tabBarHeight + titleGap
        // Space above the body text (title area) and below it (the plain
        // padding plus clearance so the last line can scroll clear of the
        // assistant button and status pill in the bottom-right corner).
        let topSpace = titleTop + titleHeight + titleGap
        let bottomSpace = Theme.padding + ChatDock.clearance

        let available = textView.bounds.width
        let horizontal = max(Theme.padding, (available - Theme.maxTextWidth) / 2)
        let newInset = NSSize(width: horizontal, height: (topSpace + bottomSpace) / 2)
        textView.extraTopInset = topSpace - bottomSpace
        // Only write when changed: setting the inset resizes the text view,
        // which re-posts the frame notification that got us here.
        if textView.textContainerInset != newInset {
            textView.textContainerInset = newInset
        }

        titleView.font = titleFont
        // NSTextView can seat the first baseline lower than static text
        // drawing does (e.g. Hoefler: 31pt from fragment top vs a 23.8pt
        // ascender). Raise the frame by that difference so the title sits
        // where the ascender-based layout puts it.
        let baselineDelta = max(0, Self.metricsLayoutManager.defaultBaselineOffset(for: titleFont) - titleFont.ascender)
        titleView.frame = NSRect(
            x: horizontal,
            y: titleTop - baselineDelta,
            width: max(120, available - 2 * horizontal),
            height: titleHeight + baselineDelta + 4
        )
    }

    /// Colors this controller sets on plain AppKit views.
    private func applyTheme() {
        titleView.textColor = Theme.secondary
        titleView.insertionPointColor = Theme.cursor
        titleView.selectedTextAttributes = [
            .backgroundColor: Theme.selection,
            .foregroundColor: Theme.palette.selectedText,
        ]
        statusLabel.textColor = Theme.secondary
        statusPill.layer?.backgroundColor = Theme.background.withAlphaComponent(Theme.backgroundOpacity).cgColor
        scrollView.verticalScroller?.knobStyle = Theme.palette.isDark ? .light : .dark
    }

    /// Live theme switch: the window, its views, and the open note's text.
    /// SwiftUI pages follow the palette on their own.
    @objc private func themeDidChange() {
        guard let window else { return }
        applyThemeBackdrop(to: window)
        applyTheme()
        textView.applyTheme()
        selectionToolbar.applyTheme()
        window.contentView?.refreshTheme()
        textView.rehighlight()
        refreshChrome()
    }

    func applyFontChange() {
        textView.rehighlight()
        statusLabel.font = Theme.interfaceFont(size: 11)
        sidebar.refreshFont()
        updateInsets()
        refreshChrome()
    }

    // MARK: - Tabs

    func switchTab(to index: Int) {
        guard documents.indices.contains(index) else { return }
        if browsing { setBrowsing(false) }
        textView.dismissReferences()
        commitTitleIfEditing()
        flushAutosave()
        currentDocument.selection = textView.selectedRange()
        current = index
        recordTabActivation()
        let doc = currentDocument
        // The old selection may lie beyond the incoming text.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.layoutManager?.replaceTextStorage(doc.storage)
        textView.rehighlight()
        let length = (doc.storage.string as NSString).length
        let sel = NSIntersectionRange(doc.selection, NSRange(location: 0, length: length))
        textView.setSelectedRange(sel.location <= length ? sel : NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        refreshChrome()
        focusCurrentPage()
    }

    private func focusCurrentPage() {
        switch currentDocument.kind {
        case .markdown: window?.makeFirstResponder(textView)
        case .wiki: window?.makeFirstResponder(currentDocument.wiki?.hostView)
        default: window?.makeFirstResponder(preview)
        }
    }

    /// Expands the icon browser from the sidebar across the window, or
    /// returns it to the sidebar.
    func setBrowsing(_ on: Bool, animated: Bool = true) {
        guard on != browsing else { return }
        browsing = on
        browseGeneration += 1
        let generation = browseGeneration
        let animate = animated && window?.isVisible == true
        // Everything beneath the browser except the assistant fades with it.
        let pages = container.subviews.filter {
            ![sidebarBackdrop, browser, divider, agentContainer, agentDivider, dockHint, chatHost].contains($0)
        }
        if on {
            browser.isHidden = false
            // The browser's own fill and edge stand in for the backdrop's.
            sidebarBackdrop.isHidden = true
        }
        browser.setExpanded(on, from: sidebarCollapsed ? 0 : sidebar.frame.width, animated: animate) { [weak self] in
            guard let self, self.browseGeneration == generation, !on else { return }
            self.browser.isHidden = true
            self.sidebarBackdrop.isHidden = self.sidebarCollapsed
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? FileBrowser.duration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pages.forEach { $0.animator().alphaValue = on ? 0 : 1 }
        }
        if on { window?.makeFirstResponder(browser.grid) } else { focusCurrentPage() }
    }

    /// Shows `url` in the icon browser, with Back leading up to the sidebar's folder.
    func browse(_ url: URL) {
        browser.show(url, within: sidebar.rootURL)
        setBrowsing(true)
    }

    @objc func newTab(_ sender: Any?) {
        documents.append(Document())
        switchTab(to: documents.count - 1)
    }

    @objc func newWikiTab(_ sender: Any?) {
        documents.append(Document(wiki: WikiPage(style: .wikipedia)))
        switchTab(to: documents.count - 1)
    }

    /// The [+] menu: a note or a Wikipedia page.
    private func showNewTabMenu(from anchor: NSView) {
        let menu = NSMenu()
        for (title, symbol, action, key, modifiers) in [
            ("New Note", "square.and.pencil", #selector(newTab(_:)), "t", NSEvent.ModifierFlags.command),
            ("New Wikipedia Page", "book.closed", #selector(newWikiTab(_:)), "t", [.command, .shift]),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.appearance = Theme.palette.appearance
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 6 : -6), in: anchor)
    }

    @objc func closeTab(_ sender: Any?) {
        closeTab(at: current)
    }

    func closeTab(at index: Int) {
        commitTitleIfEditing()
        guard documents.indices.contains(index), resolveUnsavedChanges(at: index) else { return }
        if documents.count == 1 {
            window?.performClose(nil)
            return
        }
        flushAutosave()
        // resolveUnsavedChanges may have switched `current` onto `index`.
        retire(documents.remove(at: index))
        if current > index { current -= 1 }
        current = min(current, documents.count - 1)
        reattachCurrent()
    }

    /// Removes a tab intact (storage, undo stack, selection, scroll, page)
    /// for moving into another window. Returns nil when this is the only tab.
    /// Its edits are flushed first, so the move itself never prompts.
    func removeDocument(at index: Int) -> Document? {
        guard documents.count > 1, documents.indices.contains(index) else { return nil }
        commitTitleIfEditing()
        flushAutosave()
        let doc = documents[index]
        if index == current {
            doc.selection = textView.selectedRange()
            doc.scrollOrigin = scrollView.contentView.bounds.origin
            // Typing coalesces into one open undo group; close it here.
            textView.breakUndoCoalescing()
        }
        documents.remove(at: index)
        if current > index {
            current -= 1
        } else if current >= documents.count {
            current = documents.count - 1
        }
        // A Wikipedia page's view stays put (hidden) until the new window
        // adopts it, keeping its scroll position and loaded images.
        doc.wiki?.hostView?.isHidden = true
        reattachCurrent()
        return doc
    }

    /// Adopts a tab moved from another window at `index` and shows it.
    func insertDocument(_ doc: Document, at index: Int) {
        commitTitleIfEditing()
        let showing = currentDocument
        documents.insert(doc, at: max(0, min(index, documents.count)))
        current = documents.firstIndex { $0 === showing } ?? 0
        switchTab(to: documents.firstIndex { $0 === doc } ?? current)
        restoreScroll(of: doc)
    }

    /// Reorders a tab within this window; the shown tab stays shown.
    func moveDocument(from source: Int, to destination: Int) {
        guard documents.indices.contains(source), documents.indices.contains(destination), source != destination else { return }
        let showing = currentDocument
        documents.insert(documents.remove(at: source), at: destination)
        current = documents.firstIndex { $0 === showing } ?? 0
        recordTabActivation()
        refreshChrome()
    }

    /// Puts a note that arrived from another window back where it was.
    func restoreScroll(of doc: Document) {
        guard let origin = doc.scrollOrigin else { return }
        doc.scrollOrigin = nil
        guard doc === currentDocument, doc.kind == .markdown else { return }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The page area as composited on screen (glass included), for the
    /// window-like preview that follows a tab dragged out of the strip.
    private func pagePreview() -> NSImage? {
        guard let window, let image = AppDelegate.windowImage(window) else { return nil }
        let scale = CGFloat(image.width) / window.frame.width
        let page = container.convert(contentGuide.frame, to: nil)
        let crop = CGRect(x: page.minX * scale, y: (window.frame.height - page.maxY) * scale,
                          width: page.width * scale, height: page.height * scale)
        guard let cropped = image.cropping(to: crop) else { return nil }
        return NSImage(cgImage: cropped, size: page.size)
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        app?.moveTab(from: self, at: current)
    }

    private func reattachCurrent() {
        recordTabActivation()
        let doc = currentDocument
        // The old selection may lie beyond the incoming text.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.layoutManager?.replaceTextStorage(doc.storage)
        textView.rehighlight()
        let length = doc.storage.length
        let selection = NSIntersectionRange(doc.selection, NSRange(location: 0, length: length))
        textView.setSelectedRange(selection.location <= length ? selection : NSRange(location: 0, length: 0))
        refreshChrome()
        focusCurrentPage()
    }

    private func recordTabActivation() {
        let openTabs = Set(documents.map { ObjectIdentifier($0) })
        let active = ObjectIdentifier(currentDocument)
        tabActivationOrder.removeAll { $0 == active || !openTabs.contains($0) }
        tabActivationOrder.insert(active, at: 0)
    }

    /// Match whole path components, so a sibling like Studio-Archive isn't
    /// treated as part of Studio. Re-evaluate URLs after renames or Save As.
    private var mostRecentSidebarTab: Int? {
        guard let root = workspace?.root.standardizedFileURL.pathComponents else { return nil }
        let candidates = documents.indices.filter { index in
            documents[index].url?.standardizedFileURL.pathComponents.starts(with: root) == true
        }
        if candidates.contains(current) { return current }
        for id in tabActivationOrder {
            if let index = candidates.first(where: { ObjectIdentifier(documents[$0]) == id }) { return index }
        }
        return candidates.first
    }

    @objc func nextTab(_ sender: Any?) {
        switchTab(to: (current + 1) % documents.count)
    }

    @objc func previousTab(_ sender: Any?) {
        switchTab(to: (current - 1 + documents.count) % documents.count)
    }

    private func refreshChrome() {
        let doc = currentDocument
        let editable = doc.kind == .markdown
        let isWiki = doc.kind == .wiki
        scrollView.isHidden = !editable
        preview.isHidden = editable || isWiki
        textView.isEditable = editable
        titleView.isEditable = editable
        showWikiHost(for: doc)
        if !editable {
            selectionToolbar.hide()
            if isWiki { preview.suspend() } else {
                preview.show(doc, from: previewOrigin)
            }
        } else { preview.suspend() }
        // Notes and images get the same glass cluster as Wikipedia pages.
        if chrome.page !== doc.wiki { chrome.page = doc.wiki }
        updatePageGlass()
        updatePageActions()
        updateTabs()
        updateStatus()
        updateAgentContext()
        app?.sessionChanged()
    }

    private func updateTabs() {
        tabBar.update(tabs: documents.map { ($0.name, $0.edited) }, selected: current)
    }

    // MARK: - Text changes → autosave + status

    /// Runs per keystroke, so it stays lean: the text changes nothing in the
    /// session, agent context or window layout. Only the first edit marks the
    /// tab; text-derived chrome (outline, share, word count) waits for a pause.
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === textView else { return }
        guard !reloadingFromDisk else { return }
        if !currentDocument.edited {
            currentDocument.edited = true
            window?.isDocumentEdited = true
            updateTabs()
        }
        outlineTimer?.invalidate()
        outlineTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            updatePageActions()
            // A "saved" flash restores the count itself when it ends.
            if savedFlashTimer?.isValid != true { updateStatus() }
        }
        scheduleAutosave()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        view === titleView ? titleUndoManager : currentDocument.undoManager
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        // Continuous typing keeps resetting the debounce; don't let more than
        // ten seconds of work sit only in memory.
        if Date().timeIntervalSince(lastAutosave) > 10 {
            autosaveNow()
            return
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.autosaveNow()
        }
    }

    /// Named documents save to their file; untitled buffers (and failed
    /// saves) mirror to the recovery store instead.
    private func autosaveNow() {
        lastAutosave = Date()
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        let doc = currentDocument
        guard doc.edited else { return }
        if doc.url != nil {
            if !saveCurrentDocument() { RecoveryStore.write(doc) }
        } else {
            RecoveryStore.write(doc)
        }
    }

    private func flushAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        guard documents.indices.contains(current) else { return }
        autosaveNow()
    }

    /// Assigns only changed strings; each assignment invalidates layout.
    private func updateStatus() {
        let doc = currentDocument
        if window?.title != doc.name { window?.title = doc.name }
        // A Wikipedia tab's status is its article's address, linking to it.
        guard doc.kind != .wiki else {
            let url = doc.wiki?.article?.url
            statusPill.link = url
            let address = url.map { ($0.host() ?? "") + $0.path(percentEncoded: false) } ?? ""
            if statusLabel.stringValue != address { statusLabel.stringValue = address }
            return
        }
        statusPill.link = nil
        let words = doc.storage.string
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let status = "\(doc.name) · \(words)w"
        if statusLabel.stringValue != status { statusLabel.stringValue = status }
        if window?.firstResponder !== titleView, titleView.string != doc.displayTitle {
            titleView.string = doc.displayTitle
        }
    }

    // MARK: - Inline title → file rename

    private func commitTitleIfEditing() {
        guard window?.firstResponder === titleView else { return }
        window?.makeFirstResponder(textView)  // textDidEndEditing commits
    }

    func textDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextView) === titleView else { return }
        if titleReverting {
            titleReverting = false
        } else {
            applyTitle(titleView.string)
        }
        titleView.string = currentDocument.displayTitle
    }

    func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard view === titleView else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            window?.makeFirstResponder(textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            titleReverting = true
            window?.makeFirstResponder(textView)
            return true
        default:
            return false
        }
    }

    private func applyTitle(_ rawTitle: String) {
        let doc = currentDocument
        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("/"), title != doc.displayTitle else {
            titleView.string = doc.displayTitle
            return
        }
        guard let url = doc.url else {
            doc.customTitle = title
            if doc.edited { RecoveryStore.write(doc) }
            refreshChrome()
            return
        }
        flushAutosave()
        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent(title)
            .appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            doc.url = newURL
            app?.recentFileRenamed(from: url, to: newURL)
            sidebar.refresh(); workspace?.refreshIndex()
        } catch {
            NSSound.beep()
            titleView.string = doc.displayTitle
        }
        refreshChrome()
    }

    // MARK: - File operations

    private func updateSidebar(animated: Bool = false) {
        guard animated || sidebarAnimationID == nil, let content = window?.contentView else { return }
        let visible = true
        let expanded = !sidebarCollapsed
        let width = min(sidebarWidth, max(150, content.bounds.width - 240))
        let animate = animated && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animationID = UUID()
        // Suppress resize callbacks while assigning the final geometry.
        sidebarAnimationID = animationID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            sidebarWidthConstraint.constant = expanded ? width : 0
            sidebar.isHidden = !expanded
            divider.isHidden = !expanded
            tabBar.configureSidebar(visible: visible, collapsed: sidebarCollapsed, width: expanded ? width : 0)
            content.layoutSubtreeIfNeeded()
        }
        sidebarBackdrop.configure(expanded: expanded, width: width, height: content.bounds.height, animated: animate)
        // The browser's own fill covers the sidebar while it is open.
        if browsing { sidebarBackdrop.isHidden = true }
        guard animate else { sidebarAnimationID = nil; return }
        if expanded { sidebar.fadeInContents() }
        tabBar.fadeInTabs()
        SidebarTransition.fadeIn([scrollView, preview])
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarTransition.duration) { [weak self] in
            guard let self, self.sidebarAnimationID == animationID else { return }
            self.sidebarAnimationID = nil
            self.updateSidebar()
        }
    }

    /// Restores the sidebar: browsing `root`, or ~/Documents without one.
    func restoreWorkspace(root: URL?, collapsed: Bool, width: CGFloat) {
        textView.dismissReferences()
        textView.referencesEnabled = root != nil
        workspace = root.map(Workspace.init(root:))
        // Wiki links resolve against the index, which fills in asynchronously.
        workspace?.onIndexChanged = { [weak self] in self?.textView.rehighlight() }
        sidebar.isWatched = root != nil
        sidebar.setRoot(root ?? AgentSession.defaultDirectory)
        browser.isWatched = root != nil
        browser.setRoot(root ?? AgentSession.defaultDirectory)
        sidebarCollapsed = collapsed; sidebarWidth = max(150, min(width, 600))
        updateSidebar()
        refreshChrome()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        agent.store.frontmost = agent
        sidebar.refresh()
        browser.refresh()
        // Pick up edits made elsewhere (another app, an agent in a terminal)
        // to notes that have no unsaved changes here.
        for doc in documents where doc.kind == .markdown && !doc.edited { reloadFromDisk(doc) }
    }

    @objc func closeFolder(_ sender: Any?) {
        textView.dismissReferences()
        textView.referencesEnabled = false
        workspace = nil
        sidebar.setRoot(AgentSession.defaultDirectory)
        browser.isWatched = false
        browser.setRoot(AgentSession.defaultDirectory)
        updateSidebar()
        refreshChrome()
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { open(url: url) } }
    }

    // MARK: - Following links

    /// Follows a Markdown link destination. Relative paths resolve against
    /// the linking file exactly as GitHub renders them; `#fragments` scroll
    /// within the document; anything with a scheme goes to the system.
    private func follow(_ destination: String) {
        switch FileReference.target(destination, from: currentDocument.url) {
        case .file(let url, let anchor):
            openLink(url, anchor: anchor)
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .anchor(let anchor):
            scrollToAnchor(anchor)
        case .unresolved:
            NSSound.beep()
        }
    }

    /// Follows an Obsidian `[[wiki link]]`, resolved by note name against
    /// the open folder (or against the file's own directory without one).
    private func followWikiLink(_ target: String) {
        let (name, anchor) = FileReference.splitAnchor(target)
        guard !name.isEmpty else {
            if let anchor { scrollToAnchor(anchor) }
            return
        }
        guard let url = resolveWikiLink(target) else { NSSound.beep(); return }
        openLink(url, anchor: anchor)
    }

    private func resolveWikiLink(_ target: String) -> URL? {
        if let workspace { return workspace.resolveWikiLink(target, from: currentDocument.url) }
        guard let source = currentDocument.url else { return nil }
        return FileReference.resolveWikiSibling(target, from: source)
    }

    private func openLink(_ url: URL, anchor: String?) {
        // A link to a file Catalog cannot display hands off to the system
        // rather than opening an unreadable tab.
        if FileKind.classify(url) == .unsupported, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        guard open(url: url, forceNewTab: true) else { return }
        if let anchor { scrollToAnchor(anchor) }
    }

    /// Scrolls the current document to the heading an `#anchor` names.
    private func scrollToAnchor(_ anchor: String) {
        guard currentDocument.kind == .markdown,
              let range = MarkdownHighlighter.headingRange(forAnchor: anchor,
                                                           in: textView.string as NSString) else {
            NSSound.beep(); return
        }
        scrollToLocation(range.location)
    }

    @discardableResult
    func open(url: URL, forceNewTab: Bool = false) -> Bool {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path) else {
            let alert = NSAlert(); alert.messageText = "Could not open \(url.lastPathComponent)"
            alert.informativeText = "The file may have moved or is no longer accessible.\n\(url.path)"
            alert.runModal(); return false
        }
        let kind = FileKind.classify(url)
        if kind == .folder {
            restoreWorkspace(root: url, collapsed: false, width: sidebarWidth)
            app?.addRecentFile(url)
            return true
        }
        if forceNewTab {
            if focus(url: url) { return true }
        } else if let app, app.focusExisting(url: url) { return true }
        if kind != .markdown {
            app?.addRecentFile(url)
            place(Document(url: url), replacingPlaceholder: !forceNewTab)
            return true
        }
        // If any window already has it, focus that tab instead.
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            NSSound.beep()
            return false
        }
        app?.addRecentFile(url)
        let doc = markdownDocument(url: url, content: content)
        // Reuse the current tab when it's an untouched untitled note or home page.
        place(doc, replacingPlaceholder: !forceNewTab)
        return true
    }

    /// A surviving draft means edits never reached the file (crash before
    /// the debounce fired, or a failed write): prefer the draft.
    private func markdownDocument(url: URL, content: String) -> Document {
        if let draft = RecoveryStore.draft(forPath: url.path) {
            if draft.content != content {
                let doc = Document(url: url, content: draft.content)
                doc.recoveryID = draft.id
                doc.edited = true
                return doc
            }
            RecoveryStore.remove(id: draft.id)
        }
        return Document(url: url, content: content)
    }

    /// Sidebar navigation reuses the most recently active tab within its root.
    /// Unrelated files and untitled buffers keep their tabs. If no associated
    /// tab remains, create one; an already-open destination always takes priority.
    func openInCurrentTab(_ url: URL) {
        let url = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path) else {
            NSSound.beep(); return
        }
        if FileKind.classify(url) == .folder { browse(url); return }
        if let index = documents.firstIndex(where: { $0.url?.standardizedFileURL.path == url.path }) {
            switchTab(to: index); return
        }
        let doc: Document
        if FileKind.classify(url) == .markdown {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { NSSound.beep(); return }
            doc = markdownDocument(url: url, content: content)
        } else {
            doc = Document(url: url)
        }
        commitTitleIfEditing()
        app?.addRecentFile(url)
        // Untitled notes stay open (they aren't associated with the folder),
        // but an idle home page gives way to the first thing opened.
        if currentDocument.wiki?.style == .home, currentDocument.isPlaceholder {
            place(doc, replacingPlaceholder: true)
        } else if let index = mostRecentSidebarTab {
            if index != current { switchTab(to: index) }
            flushAutosave()
            documents[index] = doc
            switchTab(to: index)
        } else {
            documents.append(doc)
            switchTab(to: documents.count - 1)
        }
    }

    func restoreTab(url: URL) {
        // Folders no longer open as tabs; older sessions may list them.
        guard FileKind.classify(url) != .folder else { return }
        open(url: url)
    }

    /// Reopens a draft left behind by a crashed or quit session as a tab.
    func adoptRecoveredDraft(_ entry: RecoveryStore.Entry) {
        let doc = Document(content: entry.content)
        doc.customTitle = entry.title
        doc.recoveryID = entry.id
        doc.edited = true
        place(doc, replacingPlaceholder: true)
    }

    /// Restores a Wikipedia tab from the saved session.
    func restoreWikiTab(title: String) {
        let page = WikiPage(style: .wikipedia)
        if !title.isEmpty { page.open(title) }
        place(Document(wiki: page), replacingPlaceholder: true)
    }

    /// Shows `doc` in the current tab when that tab is a placeholder (an
    /// untouched untitled note or home page), otherwise in a new tab.
    private func place(_ doc: Document, replacingPlaceholder: Bool) {
        if replacingPlaceholder, currentDocument.isPlaceholder {
            retire(currentDocument)
            documents[current] = doc
            switchTab(to: current)
        } else {
            documents.append(doc)
            switchTab(to: documents.count - 1)
        }
    }

    /// Quit-time flush: named documents save to their files, untitled buffers
    /// land in the recovery store to be restored next launch. Returns false
    /// when a draft could not be persisted (caller should fall back to the
    /// save/discard prompt).
    func persistAllDrafts() -> Bool {
        commitTitleIfEditing()
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        var ok = true
        for doc in documents where doc.edited && doc.kind == .markdown {
            if let url = doc.url,
               (try? doc.storage.string.write(to: url, atomically: true, encoding: .utf8)) != nil {
                doc.edited = false
                RecoveryStore.remove(doc)
            } else if doc.storage.length > 0 || doc.url != nil {
                ok = RecoveryStore.write(doc) && ok
            } else {
                RecoveryStore.remove(doc)  // emptied untitled buffer: nothing to keep
            }
        }
        return ok
    }

    func focus(url: URL) -> Bool {
        guard let index = documents.firstIndex(where: { $0.url == url }) else { return false }
        switchTab(to: index)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    @objc func saveDocument(_ sender: Any?) {
        guard currentDocument.kind == .markdown else { return }
        if currentDocument.url == nil {
            promptForSaveURL()
        }
        if saveCurrentDocument() { flashSaved() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard currentDocument.kind == .markdown else { return }
        promptForSaveURL()
        if saveCurrentDocument() { flashSaved() }
    }

    /// Briefly appends "saved" to the status line after a manual save.
    private func flashSaved() {
        statusLabel.stringValue = "\(currentDocument.name) · saved"
        statusLabel.textColor = Theme.code.withAlphaComponent(0.9)
        savedFlashTimer?.invalidate()
        savedFlashTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            statusLabel.textColor = Theme.secondary
            updateStatus()
        }
    }

    private func promptForSaveURL() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = currentDocument.url?.lastPathComponent
            ?? currentDocument.customTitle.map { $0 + ".md" }
            ?? "untitled.md"
        if panel.runModal() == .OK, let url = panel.url {
            currentDocument.url = url
            app?.addRecentFile(url)
            refreshChrome()
        }
    }

    @discardableResult
    private func saveCurrentDocument() -> Bool {
        let doc = currentDocument
        guard doc.kind == .markdown, let url = doc.url else { return false }
        do {
            try doc.storage.string.write(to: url, atomically: true, encoding: .utf8)
            doc.edited = false
            RecoveryStore.remove(doc)
            window?.isDocumentEdited = false
            // Saving clears only the edited mark; a new URL refreshed already.
            updateTabs()
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Returns true when it is safe to discard the document at `index`.
    private func resolveUnsavedChanges(at index: Int) -> Bool {
        flushAutosave()
        let doc = documents[index]
        guard doc.url == nil, doc.edited, doc.storage.length > 0 else { return true }
        if index != current { switchTab(to: index) }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to \(doc.displayTitle)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            promptForSaveURL()
            guard currentDocument.url != nil else { return false }
            saveCurrentDocument()
            return true
        case .alertSecondButtonReturn:
            RecoveryStore.remove(doc)
            return true
        default:
            return false
        }
    }

    func resolveAllUnsavedChanges() -> Bool {
        for index in documents.indices {
            if !resolveUnsavedChanges(at: index) { return false }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitTitleIfEditing()
        return resolveAllUnsavedChanges()
    }

    // MARK: - Pages

    /// Shows the current tab's hosting view if it is a Wikipedia page,
    /// installing it in this window on first use (or after a detach).
    private func showWikiHost(for doc: Document) {
        for other in documents where other !== doc { other.wiki?.hostView?.isHidden = true }
        guard let page = doc.wiki else { return }
        let host: PageHostingView<WikiTabView>
        if let existing = page.hostView as? PageHostingView<WikiTabView> {
            host = existing
        } else {
            host = PageHostingView(rootView: WikiTabView(page: page))
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            page.hostView = host
        }
        if host.superview !== container {
            configure(page)
            container.addSubview(host, positioned: .below, relativeTo: pageGlass)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        host.isHidden = false
    }

    /// Binds a page's callbacks to this window.
    private func configure(_ page: WikiPage) {
        page.onChange = { [weak self] in self?.refreshChrome() }
        page.onChromeChange = { [weak self, weak page] in
            guard let self, self.currentDocument.wiki === page else { return }
            self.updatePageGlass()
        }
        page.homeActions = HomeActions(
            newNote: { [weak self, weak page] in
                guard let self, let index = self.documents.firstIndex(where: { $0.wiki === page }) else { return }
                self.retire(self.documents[index])
                self.documents[index] = Document()
                self.switchTab(to: index)
            },
            openFolder: { [weak self] in self?.openFolder(nil) },
            openFile: { [weak self] in self?.openDocument(nil) },
            openRecent: { [weak self] url in self?.open(url: url) },
            recentFiles: { [weak self] in self?.app?.recentFileURLs ?? [] })
    }

    /// Tears down a closing tab's page view (it retains its page).
    private func retire(_ doc: Document) {
        guard let page = doc.wiki, let host = page.hostView else { return }
        host.removeFromSuperview()
        page.hostView = nil
    }

    /// The glass behind the tabs and bar shows while content is beneath
    /// them; the bar's controls follow the page on screen.
    private func updatePageGlass() {
        let doc = currentDocument
        let viewing = doc.wiki?.viewer != nil
        let scrolled: Bool
        switch doc.kind {
        case .markdown: scrolled = scrollView.contentView.bounds.origin.y > 4
        case .wiki: scrolled = doc.wiki?.showsTitle == true && !viewing
        default: scrolled = false
        }
        pageGlass.setShowing(scrolled)
        // The home page has nothing to list or share.
        let hasActions = doc.kind == .markdown || doc.kind == .image || doc.wiki?.route != nil
        pageActions.isHidden = !hasActions || viewing
        statusPill.isHidden = !(doc.kind == .markdown || doc.wiki?.article != nil) || viewing
        updateChatDock()
        backButton.isHidden = doc.wiki?.canGoBack != true || viewing
    }

    /// Contents and Share for the page on screen.
    private func updatePageActions() {
        let doc = currentDocument
        switch doc.kind {
        case .markdown:
            let text = doc.storage.string
            chrome.hasOutline = true
            let outline = MarkdownHighlighter.outline(of: text as NSString).map {
                OutlineEntry(id: String($0.location), title: $0.title, level: $0.level)
            }
            if chrome.outline != outline { chrome.outline = outline }
            if let url = doc.url {
                let images = MarkdownHighlighter.embeddedImages(in: text, from: url) { [weak self] target in
                    self?.resolveWikiLink(target)
                }
                chrome.share = .note(url, images: images)
            } else {
                chrome.share = text.isEmpty ? .none : .text(text)
            }
        case .image:
            chrome.hasOutline = false
            chrome.outline = []
            chrome.share = doc.url.map { .url($0) } ?? .none
        case .wiki:
            let article = doc.wiki?.article
            let outline = article?.sections.map { OutlineEntry(id: $0.id, title: $0.title, level: $0.level) } ?? []
            chrome.hasOutline = !outline.isEmpty
            if chrome.outline != outline { chrome.outline = outline }
            chrome.share = article.map { .url($0.url) } ?? .none
        default:
            break
        }
        chrome.jump = { [weak self] entry in
            guard let self else { return }
            if let page = self.currentDocument.wiki {
                page.scrollTarget = entry?.id ?? "top"
                return
            }
            guard let entry, let location = Int(entry.id) else { self.scrollToLocation(0); return }
            self.scrollToLocation(location)
        }
        pageActions.invalidateIntrinsicContentSize()
    }

    /// Scrolls a note so `location`'s line sits just below the glass bar.
    private func scrollToLocation(_ location: Int) {
        guard currentDocument.kind == .markdown, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let location = min(location, length)
        layoutManager.ensureLayout(for: textContainer)
        let y: CGFloat
        if location == 0 {
            y = 0
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, length - 1)))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            y = line.minY + textView.textContainerOrigin.y - PageMetrics.contentTop
        }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = max(0, y)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        window?.makeFirstResponder(textView)
    }

    /// Scripting: scrolls the current note to a vertical offset (or a
    /// Wikipedia page to that block).
    func scrollPage(to offset: CGFloat) {
        if let page = currentDocument.wiki { page.scrollTarget = "block-\(Int(offset))"; return }
        guard currentDocument.kind == .markdown else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = offset
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Opens a Wikipedia article: in the current Wikipedia tab, else a new one.
    func openArticle(_ title: String) {
        if let page = currentDocument.wiki {
            page.open(title)
        } else {
            let page = WikiPage(style: .wikipedia)
            page.open(title)
            documents.append(Document(wiki: page))
            switchTab(to: documents.count - 1)
        }
    }

    @objc func wikiBack(_ sender: Any?) {
        if browsing { browser.goBack() } else { currentDocument.wiki?.goBack() }
    }

    @objc func searchWikipedia(_ sender: Any?) {
        if let page = currentDocument.wiki { page.goHome() } else { newWikiTab(sender) }
    }

    @objc func randomArticle(_ sender: Any?) {
        if currentDocument.wiki == nil { newWikiTab(sender) }
        currentDocument.wiki?.openRandom()
    }

    // MARK: - Assistant

    private func configureAgent() {
        chrome.toggleChat = { [weak self] in self?.toggleAgent(nil) }
        agent.contextProvider = { [weak self] in
            self?.agentContext(includingText: true)
                ?? AgentContext(kind: .other, title: "", workingDirectory: AgentSession.defaultDirectory)
        }
        agent.openFile = { [weak self] url in
            guard let self else { return }
            if FileKind.classify(url) == .folder { self.browse(url) } else { self.open(url: url, forceNewTab: true) }
        }
        agent.openArticle = { [weak self] title in self?.openArticle(title) }
        agent.prepareToSend = { [weak self] in self?.saveNotesForAgent() }
    }

    @objc func toggleAgent(_ sender: Any?) {
        setAgentOpen(!agentOpen)
    }

    func setAgentOpen(_ open: Bool, width: CGFloat? = nil, docked: Bool? = nil) {
        if let width { agentWidth = max(280, min(width, 720)) }
        if let docked { agentPrefersDocked = docked }
        setChatMode(open ? (agentPrefersDocked ? .docked : .floating) : .closed)
    }

    private func setChatMode(_ mode: WindowChrome.ChatMode, animated: Bool = true) {
        guard mode != chrome.chatMode else { return }
        if mode != .closed { agentPrefersDocked = mode == .docked }
        chrome.chatMorphAnimated = animated
        chrome.chatMode = mode
        agent.activeStyle = mode == .docked ? .docked : mode == .floating ? .floating : nil
        updateAgentPanel()
        updateChatDock()
        switch mode {
        case .docked:
            SidebarTransition.fadeIn([agentHost])
            window?.makeFirstResponder(agentHost)
        case .floating:
            window?.makeFirstResponder(chatHost)
        case .closed:
            focusCurrentPage()
        }
        if mode != .closed {
            AgentAccounts.shared.refresh()
            agent.requestFocus()
        }
        app?.sessionChanged()
    }

    private func updateAgentPanel() {
        let available = window?.contentView?.bounds.width ?? 900
        let docked = chrome.chatMode == .docked
        agentWidthConstraint.constant = docked ? min(agentWidth, max(260, available - sidebarWidthConstraint.constant - 320)) : 0
        agentContainer.isHidden = !docked
        agentDivider.isHidden = !docked
    }

    /// The button shows on pages with a bar while the assistant is closed;
    /// the floating panel shows over any page.
    private func updateChatDock() {
        let doc = currentDocument
        let hasBar = doc.kind == .markdown || doc.kind == .image || doc.kind == .wiki
        let showsButton = hasBar && doc.wiki?.viewer == nil && chrome.chatMode == .closed
        chatHost.isHidden = !(showsButton || chrome.chatFloating)
    }

    /// The floating panel's resting offsets: its bottom-right corner is the
    /// button's, above the status pill.
    private var chatRest: (trailing: CGFloat, bottom: CGFloat) {
        (-ChatDock.margin, -(ChatDock.clearance - ChatDock.size))
    }

    private func agentActions(docked: Bool) -> AgentPanel.Actions {
        AgentPanel.Actions(
            close: { [weak self] in self?.setAgentOpen(false) },
            toggleDocked: { [weak self] in
                guard let self else { return }
                self.setChatMode(self.chrome.chatMode == .docked ? .floating : .docked)
            },
            dragChanged: { [weak self] in self?.chatDragChanged(fromDock: docked) },
            dragEnded: { [weak self] in self?.chatDragEnded(fromDock: docked) })
    }

    private var mouseInContainer: NSPoint? {
        guard let window else { return nil }
        return container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Dragging the floating panel moves it, offering to dock at the
    /// window's right edge. Dragging the sidebar's header out into the
    /// page previews the floating panel under the pointer.
    private func chatDragChanged(fromDock: Bool) {
        guard let mouse = mouseInContainer else { return }
        if fromDock {
            let out = mouse.x < agentContainer.frame.minX - 40
            if out != chrome.chatPreview {
                chrome.chatMorphAnimated = false
                chrome.chatPreview = out
                updateChatDock()
                container.layoutSubtreeIfNeeded()
            }
            guard out else { return }
            // Hold the panel by its header, just right of the title's start.
            let size = chatHost.frame.size
            chatTrailing.constant = mouse.x - 60 + size.width - contentGuide.frame.maxX
            chatBottom.constant = -(mouse.y + 24 - size.height)
        } else {
            if chatDragStart == nil { chatDragStart = (mouse, chatTrailing.constant, chatBottom.constant) }
            guard let start = chatDragStart else { return }
            chatTrailing.constant = start.trailing + mouse.x - start.mouse.x
            chatBottom.constant = start.bottom - (mouse.y - start.mouse.y)
            dockHint.setShowing(mouse.x > container.bounds.maxX - 72)
        }
    }

    private func chatDragEnded(fromDock: Bool) {
        chatDragStart = nil
        if fromDock {
            guard chrome.chatPreview else { return }
            chrome.chatPreview = false
            setChatMode(.floating, animated: false)
            settleChatDock()
        } else if dockHint.isShowing {
            dockHint.setShowing(false)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                chatHost.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.chrome.chatMorphAnimated = false
                self.setChatMode(.docked)
                (self.chatTrailing.constant, self.chatBottom.constant) = self.chatRest
                self.chatHost.alphaValue = 1
            })
        } else {
            settleChatDock()
        }
    }

    /// Springs the floating panel back to its corner.
    private func settleChatDock() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            chatTrailing.animator().constant = chatRest.trailing
            chatBottom.animator().constant = chatRest.bottom
            container.layoutSubtreeIfNeeded()
        }
    }

    /// What the assistant sees: the open tab and the working directory —
    /// the open folder, else ~/Documents.
    private func agentContext(includingText: Bool) -> AgentContext {
        let doc = currentDocument
        let directory = workspace?.root ?? AgentSession.defaultDirectory
        switch doc.kind {
        case .wiki:
            if let page = doc.wiki, let article = page.article {
                return AgentContext(kind: .article, title: article.title, articleURL: article.url,
                                    text: includingText ? article.plainText : nil, workingDirectory: directory)
            }
            return AgentContext(kind: .home, title: doc.name, workingDirectory: directory)
        case .markdown:
            return AgentContext(kind: .note, title: doc.displayTitle, fileURL: doc.url,
                                text: includingText ? doc.storage.string : nil, workingDirectory: directory)
        case .image:
            return AgentContext(kind: .image, title: doc.name, fileURL: doc.url, workingDirectory: directory)
        case .unsupported, .folder:
            return AgentContext(kind: .other, title: doc.name, fileURL: doc.url, workingDirectory: directory)
        }
    }

    private func updateAgentContext() {
        let context = agentContext(includingText: false)
        if agent.contextLabel != context.label { agent.contextLabel = context.label }
        if agent.contextKind != context.kind { agent.contextKind = context.kind }
        if agent.workingDirectory != context.workingDirectory { agent.workingDirectory = context.workingDirectory }
    }

    // MARK: - Live reload

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The assistant is about to write a file: save unsaved edits to it
    /// first, so its edit builds on what the user sees.
    @objc private func agentWillModifyFile(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        for doc in documents where doc.kind == .markdown && doc.edited {
            guard let docURL = doc.url, Self.samePath(docURL, url) else { continue }
            if doc === currentDocument {
                flushAutosave()
            } else if (try? doc.storage.string.write(to: docURL, atomically: true, encoding: .utf8)) != nil {
                doc.edited = false
                RecoveryStore.remove(doc)
            }
        }
    }

    /// Before a message goes out, unsaved edits to named notes reach disk,
    /// so Claude Code or Codex reads exactly what the user sees.
    private func saveNotesForAgent() {
        commitTitleIfEditing()
        flushAutosave()
        for doc in documents where doc.kind == .markdown && doc.edited {
            guard let url = doc.url, (try? doc.storage.string.write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
            doc.edited = false
            RecoveryStore.remove(doc)
        }
        window?.isDocumentEdited = currentDocument.edited
        updateTabs()
    }

    /// The assistant changed files: follow moves, reload open notes, and
    /// refresh the sidebar, so changes appear without reopening anything.
    @objc private func agentDidModifyFiles(_ notification: Notification) {
        let urls = notification.userInfo?["urls"] as? [URL] ?? []
        if let from = notification.userInfo?["from"] as? URL, let to = notification.userInfo?["to"] as? URL {
            let fromPath = from.standardizedFileURL.path
            for doc in documents {
                guard let path = doc.url?.standardizedFileURL.path else { continue }
                if path == fromPath {
                    doc.url = to.standardizedFileURL
                } else if path.hasPrefix(fromPath + "/") {
                    doc.url = URL(fileURLWithPath: to.standardizedFileURL.path + path.dropFirst(fromPath.count))
                }
            }
        }
        var changedCurrent = false
        // No URLs: a CLI changed files on its own, so recheck every open note.
        let everything = urls.isEmpty
        for doc in documents {
            guard let docURL = doc.url, everything || urls.contains(where: { Self.samePath($0, docURL) }) else { continue }
            if everything, doc.kind == .markdown,
               (try? String(contentsOf: docURL, encoding: .utf8)) == doc.storage.string { continue }
            if doc.kind == .markdown { reloadFromDisk(doc) }
            if doc === currentDocument { changedCurrent = true }
        }
        sidebar.refresh()
        refreshChrome()
        if changedCurrent { flashStatus("updated by assistant") }
    }

    /// Replaces a note's text with its file's, keeping it undoable when the
    /// note is on screen. Notes with unsaved edits are left alone.
    private func reloadFromDisk(_ doc: Document) {
        guard doc.kind == .markdown, !doc.edited, let url = doc.url,
              let text = try? String(contentsOf: url, encoding: .utf8), text != doc.storage.string else { return }
        let full = NSRange(location: 0, length: doc.storage.length)
        if doc === currentDocument {
            let selection = textView.selectedRange()
            reloadingFromDisk = true
            if textView.shouldChangeText(in: full, replacementString: text) {
                doc.storage.replaceCharacters(in: full, with: text)
                textView.didChangeText()
            }
            reloadingFromDisk = false
            textView.rehighlight()
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            window?.isDocumentEdited = false
        } else {
            doc.storage.replaceCharacters(in: full, with: text)
            let length = (text as NSString).length
            doc.selection = NSRange(location: min(doc.selection.location, length), length: 0)
        }
        doc.edited = false
        RecoveryStore.remove(doc)
    }

    private func flashStatus(_ message: String) {
        guard currentDocument.kind == .markdown else { return }
        statusLabel.stringValue = "\(currentDocument.name) · \(message)"
        statusLabel.textColor = Theme.code.withAlphaComponent(0.9)
        savedFlashTimer?.invalidate()
        savedFlashTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            statusLabel.textColor = Theme.secondary
            updateStatus()
        }
    }

    // MARK: - Debug

    func dumpLineFragments(to path: String) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let ns = currentDocument.storage.string as NSString
        var out = "inset=\(textView.textContainerInset) viewWidth=\(textView.bounds.width) maxTextWidth=\(Theme.maxTextWidth)\n"
        let used = lm.usedRect(for: tc)
        out += "viewHeight=\(textView.frame.height) usedHeight=\(used.height) required=\(used.height + 2 * textView.textContainerInset.height)\n"
        var glyphIndex = 0
        var prevMaxY: CGFloat = 0
        while glyphIndex < lm.numberOfGlyphs {
            var effRange = NSRange()
            let rect = lm.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effRange)
            let charRange = lm.characterRange(forGlyphRange: effRange, actualGlyphRange: nil)
            var text = ns.substring(with: charRange).replacingOccurrences(of: "\n", with: "\\n")
            if text.count > 40 { text = String(text.prefix(40)) }
            out += String(format: "y=%6.1f h=%5.1f gap=%5.1f  %@\n", rect.minY, rect.height, rect.minY - prevMaxY, text)
            prevMaxY = rect.maxY
            glyphIndex = NSMaxRange(effRange)
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

extension EditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(wikiBack(_:)):
            return browsing ? browser.canGoBack : currentDocument.wiki?.canGoBack == true
        case #selector(toggleAgent(_:)):
            item.title = agentOpen ? "Hide Assistant" : "Show Assistant"
            return true
        case #selector(closeFolder(_:)):
            return workspace != nil
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return currentDocument.kind == .markdown
        case #selector(moveTabToNewWindow(_:)):
            return documents.count > 1
        default:
            return true
        }
    }
}

/// The status line's pill. Given a link (a Wikipedia tab's article), it
/// opens it in the default browser; its text brightens on hover.
final class StatusPill: NSView {
    private let label: NSTextField
    private var hovered = false {
        didSet { if hovered != oldValue { label.textColor = hovered ? Theme.foreground : Theme.secondary } }
    }

    var link: URL? {
        didSet {
            guard link != oldValue else { return }
            hovered = false
            toolTip = link == nil ? nil : "Open in Browser"
            setAccessibilityElement(link != nil)
            setAccessibilityRole(link == nil ? nil : .link)
            setAccessibilityLabel(link.map { "Open \($0.absoluteString) in browser" })
            window?.invalidateCursorRects(for: self)
        }
    }

    init(label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { link == nil }

    /// Clicks on the label land on the pill.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit == nil || link == nil ? hit : self
    }

    override func resetCursorRects() {
        if link != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = link != nil }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        if link == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let link else { return super.mouseUp(with: event) }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { NSWorkspace.shared.open(link) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let link else { return false }
        return NSWorkspace.shared.open(link)
    }
}
