import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Finder's "as Icons" view of one folder. It grows out of the sidebar
/// across the window: the grid keeps its final layout throughout, and only
/// a mask, its edge and the toggle travel.
final class FileBrowser: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, ThemeRefreshing {
    static let symbol = "square.grid.2x2"
    static let collapseSymbol = "arrow.down.right.and.arrow.up.left"
    /// The toggle's distance from the right edge, here and in the sidebar.
    static let toggleInset: CGFloat = 12
    static let duration: TimeInterval = 0.3
    /// Icon sizes the slider offers. Larger than Finder's 64 by default:
    /// here the pictures are the point.
    static let iconSizes: ClosedRange<CGFloat> = 48...256
    private static let defaultIconSize: CGFloat = 128
    /// Room around an icon: its selection inset, and two lines of name.
    static let tileChrome = NSSize(width: 32, height: 58)
    private static let tileSpacing: CGFloat = 4

    var onOpen: ((URL, NSRect) -> Void)?
    var onToggle: (() -> Void)?
    /// Whether a `Workspace` watches this tree; ~/Documents re-lists on activation instead.
    var isWatched = true
    private(set) var directory: URL?
    private var history: [URL] = []
    private(set) var entries: [FileNode] = []
    private(set) var isExpanded = false
    /// The sidebar's width: where the reveal starts and ends.
    private var collapsedWidth: CGFloat = 0
    private(set) var iconSize: CGFloat = {
        let stored = CGFloat(AppState.defaults.double(forKey: "browserIconSize"))
        return FileBrowser.iconSizes.contains(stored) ? stored : FileBrowser.defaultIconSize
    }()

    let toggle = BrowserToggle()
    /// Carries the toggle along the edge: a plain view's frame animates in
    /// Core Animation, in step with the reveal, where a button's would not.
    private let toggleHost = NSView()
    private let content = NSView()
    private let title = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No items")
    private let back = PageHostingView(rootView: WikiBackButton(action: {}))
    private let zoom = NSSlider()
    private let smaller = NSImageView()
    private let larger = NSImageView()
    private let scroll = NSScrollView()
    let grid = BrowserCollectionView()
    private let edge = NSView()
    private let reveal = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        reveal.anchorPoint = .zero
        reveal.backgroundColor = NSColor.black.cgColor
        layer?.mask = reveal
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: iconSize + Self.tileChrome.width, height: iconSize + Self.tileChrome.height)
        layout.minimumInteritemSpacing = Self.tileSpacing
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 2, left: 14, bottom: 24, right: 14)
        grid.collectionViewLayout = layout
        grid.backgroundColors = [.clear]
        grid.isSelectable = true
        grid.dataSource = self; grid.delegate = self
        grid.register(BrowserItem.self, forItemWithIdentifier: BrowserItem.identifier)
        grid.onOpen = { [weak self] path in self?.open(path) }
        grid.onCancel = { [weak self] in self?.onToggle?() }
        grid.onFocus = { [weak self] in self?.refreshEmphasis() }
        scroll.documentView = grid
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        back.sizingOptions = [.intrinsicContentSize]
        back.rootView = WikiBackButton { [weak self] in self?.goBack() }
        title.lineBreakMode = .byTruncatingMiddle
        empty.alignment = .center
        zoom.minValue = Self.iconSizes.lowerBound
        zoom.maxValue = Self.iconSizes.upperBound
        zoom.doubleValue = iconSize
        zoom.controlSize = .small
        zoom.isContinuous = true
        zoom.target = self; zoom.action = #selector(zoomed)
        zoom.toolTip = "Icon Size"
        zoom.setAccessibilityLabel("Icon Size")
        for (glyph, size) in [(smaller, 9.0), (larger, 13.0)] {
            glyph.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            glyph.symbolConfiguration = .init(pointSize: size, weight: .regular)
        }
        [scroll, empty, back, title, smaller, zoom, larger].forEach(content.addSubview)
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        edge.wantsLayer = true
        toggle.configure(symbol: Self.symbol, label: "Show as Icons", target: self, action: #selector(toggled))
        toggleHost.wantsLayer = true
        toggleHost.addSubview(toggle)
        [content, edge, toggleHost].forEach(addSubview)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(workspaceChanged(_:)), name: Workspace.didChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Escape from anywhere in the browser (the grid handles its own).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onToggle?() } else { super.keyDown(with: event) }
    }

    func applyTheme() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = Theme.palette.sidebarFill.cgColor
        edge.layer?.backgroundColor = Theme.wash.withAlphaComponent(0.07).cgColor
        CATransaction.commit()
        toggle.contentTintColor = Theme.secondary
        smaller.contentTintColor = Theme.secondary
        larger.contentTintColor = Theme.secondary
        title.font = NSFontManager.shared.convert(Theme.interfaceFont(size: 13.5), toHaveTrait: .boldFontMask)
        title.textColor = Theme.heading ?? Theme.foreground
        empty.font = Theme.interfaceFont(size: 13)
        empty.textColor = Theme.secondary
        scroll.verticalScroller?.knobStyle = Theme.palette.isDark ? .light : .dark
        needsLayout = true
    }

    // MARK: Layout

    private var revealWidth: CGFloat { isExpanded ? bounds.width : collapsedWidth }
    private func toggleX(_ width: CGFloat) -> CGFloat { width - Self.toggleInset - 30 }

    override func layout() {
        super.layout()
        content.frame = bounds
        let rowY = bounds.height - TabBarView.cornerPadding - 31
        let backSize = back.fittingSize
        back.frame = NSRect(x: PageMetrics.inset, y: rowY + 15.5 - backSize.height / 2, width: backSize.width, height: backSize.height)
        let centerY = rowY + 15.5
        // The size slider sits left of the toggle, between small and large glyphs.
        larger.frame = NSRect(x: toggleX(bounds.width) - 10 - 16, y: centerY - 8, width: 16, height: 16)
        zoom.frame = NSRect(x: larger.frame.minX - 4 - 110, y: centerY - 10, width: 110, height: 20)
        smaller.frame = NSRect(x: zoom.frame.minX - 4 - 12, y: centerY - 6, width: 12, height: 12)
        let titleX = back.isHidden ? 20 : back.frame.maxX + 10
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: titleX, y: centerY - titleHeight / 2,
                             width: max(0, smaller.frame.minX - 16 - titleX), height: titleHeight)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, rowY - 8))
        empty.frame = NSRect(x: 20, y: scroll.frame.midY - 10, width: max(0, bounds.width - 40), height: 20)
        // Only an unanimated reveal follows the bounds; animations own it otherwise.
        if reveal.animation(forKey: "reveal") == nil { placeReveal(revealWidth) }
        fitTiles()
    }
    private func placeReveal(_ width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reveal.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        edge.frame = NSRect(x: width - 1, y: 0, width: 1, height: bounds.height)
        toggleHost.frame = NSRect(x: toggleX(width), y: bounds.height - TabBarView.cornerPadding - 31, width: 30, height: 31)
        toggle.frame = toggleHost.bounds
    }
    /// Widens tiles so each row fills the grid exactly; flow layout would
    /// otherwise pour the leftover width into the gaps between columns.
    private func fitTiles() {
        guard let layout = grid.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let available = scroll.contentSize.width - layout.sectionInset.left - layout.sectionInset.right
        guard available > 0 else { return }
        let spacing = Self.tileSpacing
        let columns = max(1, ((available + spacing) / (iconSize + Self.tileChrome.width + spacing)).rounded(.down))
        let size = NSSize(width: ((available - (columns - 1) * spacing) / columns).rounded(.down),
                          height: iconSize + Self.tileChrome.height)
        guard layout.itemSize != size else { return }
        layout.itemSize = size
        layout.invalidateLayout()
    }

    // MARK: Expanding

    /// Grows from (or shrinks back to) the sidebar's `width`. Reduce Motion
    /// cross-fades the whole browser in place instead.
    func setExpanded(_ expanded: Bool, from width: CGFloat, animated: Bool, completion: @escaping () -> Void) {
        let interrupted = reveal.animation(forKey: "reveal") != nil ? reveal.presentation()?.bounds.width : nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fading: NSView = reduceMotion ? self : content
        let fadingOpacity = fading.layer?.animation(forKey: "reveal") != nil ? fading.layer?.presentation()?.opacity : nil
        isExpanded = expanded
        collapsedWidth = width
        if expanded { reload(navigating: true) }
        toggle.setSymbol(expanded ? Self.collapseSymbol : Self.symbol, label: expanded ? "Close Icons" : "Show as Icons", animated: animated)
        layoutSubtreeIfNeeded()
        // An interrupted reveal turns around from where it is on screen.
        let from = interrupted ?? (expanded ? width : bounds.width)
        let to = reduceMotion ? bounds.width : revealWidth
        [reveal, layer, content.layer].forEach { $0?.removeAnimation(forKey: "reveal") }
        placeReveal(to)
        guard animated else {
            alphaValue = 1; content.alphaValue = 1
            completion(); return
        }
        // Fade the grid in with the reveal (or, reducing motion, the whole browser).
        (reduceMotion ? content : self).alphaValue = 1
        let fadeFrom = fadingOpacity.map { CGFloat($0) } ?? (expanded ? 0 : 1)
        fading.alphaValue = expanded ? 1 : 0
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        func animate(_ layer: CALayer?, keyPath: String, from: CGFloat, to: CGFloat) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = Self.duration
            animation.timingFunction = timing
            layer?.add(animation, forKey: "reveal")
        }
        if !reduceMotion {
            animate(reveal, keyPath: "bounds.size.width", from: from, to: to)
            // AppKit owns these views' layers; move them through their frames.
            edge.setFrameOrigin(NSPoint(x: from - 1, y: 0))
            toggleHost.setFrameOrigin(NSPoint(x: toggleX(from), y: toggleHost.frame.minY))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = timing
                edge.animator().setFrameOrigin(NSPoint(x: to - 1, y: 0))
                toggleHost.animator().setFrameOrigin(NSPoint(x: toggleX(to), y: toggleHost.frame.minY))
            }
        }
        animate(fading.layer, keyPath: "opacity", from: fadeFrom, to: expanded ? 1 : 0)
        CATransaction.commit()
    }

    // MARK: Navigation

    /// Browses `url`, with Back leading up through its folders within `root`.
    func show(_ url: URL, within root: URL?) {
        let url = url.standardizedFileURL
        var trail: [URL] = []
        if let root = root?.standardizedFileURL, url.path.hasPrefix(root.path + "/") {
            var parent = url.deletingLastPathComponent()
            while parent.path.count >= root.path.count {
                trail.insert(parent, at: 0)
                parent = parent.deletingLastPathComponent()
            }
        }
        history = trail
        directory = url
        if isExpanded { reload(navigating: true) }
        updateHeader()
    }
    func setRoot(_ url: URL) { show(url, within: nil) }
    var canGoBack: Bool { !history.isEmpty }
    func goBack() {
        guard let previous = history.popLast() else { return }
        let left = directory
        directory = previous
        reload(selecting: left, navigating: true)
        updateHeader()
    }
    private func navigate(to url: URL) {
        if let directory { history.append(directory) }
        directory = url
        reload(navigating: true)
        updateHeader()
    }
    private func updateHeader() {
        title.stringValue = directory.map { $0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent } ?? ""
        title.toolTip = directory?.path
        back.isHidden = history.isEmpty
        needsLayout = true
    }
    private func open(_ path: IndexPath) {
        guard entries.indices.contains(path.item) else { return }
        let node = entries[path.item]
        if node.isDirectory { navigate(to: node.url); return }
        let icon = (grid.item(at: path) as? BrowserItem)?.iconFrame(in: nil) ?? .zero
        onOpen?(node.url, icon)
    }
    @objc private func toggled() { onToggle?() }
    @objc private func zoomed() {
        iconSize = zoom.doubleValue.rounded()
        AppState.defaults.set(Double(iconSize), forKey: "browserIconSize")
        fitTiles()
        grid.layoutSubtreeIfNeeded()
        // Fetch sharper pictures only when the size crosses a pixel bucket.
        for item in grid.visibleItems() { (item as? BrowserItem)?.load(side: iconSize, scale: window?.backingScaleFactor ?? 2) }
    }

    // MARK: Listing

    /// Re-lists the folder in place, keeping the selection; after
    /// navigating, selects `selecting` (or nothing) and scrolls to it.
    private func reload(selecting: URL? = nil, navigating: Bool = false) {
        guard let directory else { return }
        let selected = navigating ? selecting
            : grid.selectionIndexPaths.first.flatMap { entries.indices.contains($0.item) ? entries[$0.item].url : nil }
        let listed = FileNode(directory).children
        let changed = listed.map(\.url) != entries.map(\.url) || listed.map(\.modified) != entries.map(\.modified)
        empty.isHidden = !listed.isEmpty
        guard changed || navigating else { return }
        let before = entries
        entries = listed
        if navigating {
            grid.reloadData()
        } else {
            // Animate entries in and out, so tiles that stay keep their pictures.
            let steps = listed.map(\.url).difference(from: before.map(\.url))
            func paths(_ changes: [CollectionDifference<URL>.Change]) -> Set<IndexPath> {
                Set(changes.map { change in
                    switch change { case .insert(let offset, _, _), .remove(let offset, _, _): IndexPath(item: offset, section: 0) }
                })
            }
            grid.animator().performBatchUpdates {
                grid.deleteItems(at: paths(steps.removals))
                grid.insertItems(at: paths(steps.insertions))
            }
            let previous = Dictionary(before.map { ($0.url, $0.modified) }, uniquingKeysWith: { first, _ in first })
            let edited = listed.indices.filter { index in
                previous[listed[index].url].map { $0 != listed[index].modified } ?? false
            }
            if !edited.isEmpty { grid.reloadItems(at: Set(edited.map { IndexPath(item: $0, section: 0) })) }
        }
        let index = selected.flatMap { url in entries.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL } }
        let paths: Set<IndexPath> = index.map { [IndexPath(item: $0, section: 0)] } ?? []
        grid.selectionIndexPaths = paths
        if navigating {
            grid.layoutSubtreeIfNeeded()
            if paths.isEmpty { grid.scroll(.zero) } else { grid.scrollToItems(at: paths, scrollPosition: .centeredVertically) }
        }
    }
    /// Unwatched trees (~/Documents) re-list when the window activates.
    func refresh() {
        guard !isWatched, isExpanded else { return }
        reload()
    }
    @objc private func workspaceChanged(_ notification: Notification) {
        guard isExpanded, let directory, let change = notification.userInfo?["change"] as? Workspace.Change,
              change.affects(path: Workspace.canonicalPath(directory)) else { return }
        reload()
    }

    // MARK: Grid

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard isExpanded else { return }
        for item in grid.visibleItems() { (item as? BrowserItem)?.load(side: iconSize, scale: window?.backingScaleFactor ?? 2) }
    }

    private var emphasized: Bool { window?.firstResponder === grid }
    private func refreshEmphasis() {
        for item in grid.visibleItems() { (item as? BrowserItem)?.emphasized = emphasized }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: BrowserItem.identifier, for: indexPath) as! BrowserItem
        item.configure(entries[indexPath.item], emphasized: emphasized)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? BrowserItem)?.load(side: iconSize, scale: window?.backingScaleFactor ?? 2)
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        (item as? BrowserItem)?.stopLoading()
    }
}

/// The browser's toggle: drawn like `SidebarIconButton`, but its symbol
/// can dissolve into another.
final class BrowserToggle: NSButton {
    private let glyph = NSImageView()
    override var contentTintColor: NSColor? { didSet { glyph.contentTintColor = contentTintColor } }
    func configure(symbol: String, label: String, target: AnyObject, action: Selector) {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target; self.action = action
        glyph.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        setSymbol(symbol, label: label, animated: false)
    }
    func setSymbol(_ symbol: String, label: String, animated: Bool) {
        toolTip = label
        setAccessibilityLabel(label)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return }
        if animated, glyph.image != nil { glyph.setSymbolImage(image, contentTransition: .replace) } else { glyph.image = image }
    }
    override func layout() {
        super.layout()
        glyph.frame = bounds
    }
    override func draw(_ dirtyRect: NSRect) {}
}

/// Present already-decoded pixels directly. NSImageView's intrinsic-size and
/// alignment invalidations otherwise propagate through the window on every
/// asynchronous thumbnail replacement, even though the tile size is fixed.
final class ThumbnailView: NSView {
    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Keep the grid off AppKit's concurrent (responsive) scrolling path: its
/// per-event main-thread synchronizer re-runs a full window Auto Layout pass
/// for every gesture tick, which scales with the number of visible tiles.
/// The opt-out must live on the document view class.
final class BrowserCollectionView: NSCollectionView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
    var onOpen: ((IndexPath) -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: if let path = selectionIndexPaths.first { onOpen?(path) }
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { onOpen?(path) }
    }
    override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }
        return super.resignFirstResponder()
    }
}

/// Fixed-size tiles keep thumbnail arrivals out of the window's layout.
private final class BrowserTile: NSView, ThemeRefreshing {
    let icon = ThumbnailView()
    private let iconBackground = NSView()
    private let capsule = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    var name = "" { didSet { label.stringValue = name; icon.setAccessibilityLabel(name); needsLayout = true } }
    var isSelected = false { didSet { applyTheme() } }
    var emphasized = false { didSet { if emphasized != oldValue { applyTheme() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [iconBackground, capsule] {
            view.wantsLayer = true
            view.layer?.cornerCurve = .continuous
        }
        iconBackground.layer?.cornerRadius = 7
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        [iconBackground, icon, capsule, label].forEach(addSubview)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    func applyTheme() {
        label.font = Theme.interfaceFont(size: 12)
        let accent = isSelected && emphasized
        label.textColor = accent ? .white : Theme.foreground.withAlphaComponent(0.85)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconBackground.layer?.backgroundColor = isSelected ? Theme.wash.withAlphaComponent(0.1).cgColor : nil
        capsule.layer?.backgroundColor = isSelected ? (accent ? NSColor.controlAccentColor : Theme.sidebarSelection).cgColor : nil
        CATransaction.commit()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let side = max(0, bounds.height - FileBrowser.tileChrome.height)
        icon.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: bounds.height - 8 - side, width: side, height: side)
        iconBackground.frame = icon.frame.insetBy(dx: -6, dy: -6)
        let width = bounds.width - 12
        let font = label.font ?? Theme.interfaceFont(size: 12)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let fitted = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: lineHeight * 2)) ?? .zero
        let size = NSSize(width: min(width, ceil(fitted.width)), height: min(lineHeight * 2, ceil(fitted.height)))
        label.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: iconBackground.frame.minY - 4 - size.height,
                             width: size.width, height: size.height)
        capsule.frame = label.frame.insetBy(dx: -5, dy: -1)
        capsule.layer?.cornerRadius = size.height > lineHeight ? 5 : capsule.frame.height / 2
    }
}

private final class BrowserItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("browser")
    private var node: FileNode?
    private var imageRequest: ImageRequest?
    private var iconRequest: QLThumbnailGenerator.Request?
    private var generation = 0
    private var loadedPixels = 0
    private var tile: BrowserTile { view as! BrowserTile }
    override func loadView() { view = BrowserTile() }
    override var isSelected: Bool { didSet { tile.isSelected = isSelected } }
    var emphasized: Bool {
        get { tile.emphasized }
        set { tile.emphasized = newValue }
    }
    func iconFrame(in view: NSView?) -> NSRect { tile.icon.convert(tile.icon.bounds, to: view) }

    func configure(_ node: FileNode, emphasized: Bool) {
        stopLoading()
        self.node = node
        tile.name = node.url.lastPathComponent
        tile.emphasized = emphasized
        tile.isSelected = isSelected
        // Tiles waiting for reuse missed any theme change.
        tile.applyTheme()
    }
    /// Requests a picture for icons of `side` points. Shrinking keeps the
    /// sharper one already shown; growing past its pixel bucket refetches.
    func load(side: CGFloat, scale: CGFloat) {
        guard let node else { return }
        let pixels = ImageLoader.thumbnailPixels(points: side, scale: scale)
        guard pixels > loadedPixels else { return }
        cancelRequests()
        loadedPixels = pixels
        generation += 1
        let token = generation
        if tile.icon.image == nil { tile.icon.image = FileIcons.placeholder(for: node, pixels: pixels) }
        let deliver: (CGImage?) -> Void = { [weak self] image in
            guard let self, self.generation == token, let image else { return }
            self.tile.icon.image = image
        }
        if FileIcons.isImage(node) {
            imageRequest = ImageLoader.shared.thumbnail(node.url, pixels: pixels, completion: deliver)
        } else {
            iconRequest = FileIcons.icon(for: node, pixels: pixels, completion: deliver)
        }
    }
    private func cancelRequests() {
        imageRequest?.cancel(); imageRequest = nil
        if let iconRequest { QLThumbnailGenerator.shared.cancel(iconRequest) }
        iconRequest = nil
    }
    func stopLoading() {
        cancelRequests()
        generation += 1
        loadedPixels = 0
        tile.icon.image = nil
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        stopLoading()
        node = nil
    }
}

/// Finder's pictures of files that aren't images: Quick Look thumbnails (a
/// page of a note, a PDF's cover) or else the file's icon, cached by
/// version. Type icons stand in while they load.
enum FileIcons {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static var imageTypes: [String: Bool] = [:]

    static func isImage(_ node: FileNode) -> Bool {
        guard !node.isDirectory else { return false }
        let ext = node.url.pathExtension.lowercased()
        if let known = imageTypes[ext] { return known }
        let image = UTType(filenameExtension: ext)?.conforms(to: .image) == true
        imageTypes[ext] = image
        return image
    }

    static func placeholder(for node: FileNode, pixels: Int) -> CGImage? {
        let type = node.isDirectory ? UTType.folder : (UTType(filenameExtension: node.url.pathExtension) ?? .data)
        let key = "type|\(type.identifier)|\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let image = NSWorkspace.shared.icon(for: type).cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Delivers on the main queue; nil when the cache already answered.
    static func icon(for node: FileNode, pixels: Int, completion: @escaping (CGImage?) -> Void) -> QLThumbnailGenerator.Request? {
        let key = "\(node.url.path)|\(node.modified?.timeIntervalSince1970 ?? 0)|\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { completion(cached); return nil }
        let request = QLThumbnailGenerator.Request(fileAt: node.url, size: CGSize(width: pixels, height: pixels),
                                                   scale: 1, representationTypes: .all)
        // Finder's decoration: page edges and shadow, not a bare square.
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.cgImage
            DispatchQueue.main.async {
                if let image { cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
                completion(image)
            }
        }
        return request
    }
}
