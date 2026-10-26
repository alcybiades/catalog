import AppKit

/// Minimal terminal-styled tab strip with hover-close, drag-to-reorder,
/// and dragging tabs out into new windows or into another window's strip.
final class TabBarView: NSView {

    /// Equal gap from the window's top-left corner to the first tab, both axes.
    static let cornerPadding: CGFloat = 15
    static let pillRadius: CGFloat = 11

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The [+] was clicked; the view anchors the new-tab menu beneath it.
    var onNewTab: ((NSView) -> Void)?
    /// A tab was dragged to a new position in this strip.
    var onMove: ((Int, Int) -> Void)?
    /// Another window's strip under a screen point, if one is there.
    var dropTarget: ((NSPoint) -> TabBarView?)?
    /// A tab was dropped on another window's strip, at an index there.
    var onTransfer: ((Int, TabBarView, Int) -> Void)?
    /// A tab was dropped clear of every strip: the cursor (screen
    /// coordinates) and where it held the tab, from the tab's top-left.
    var onDetach: ((Int, NSPoint, NSPoint) -> Void)?
    /// The page as shown, for the preview under a tab dragged clear.
    var dragPreview: (() -> NSImage?)?

    private var tabCount = 0
    /// Opens where another window's tab would drop.
    private let dropGap = NSView()
    private var dropGapWidth: NSLayoutConstraint!

    var onToggleSidebar: (() -> Void)?
    private let controls = NSView()
    private let toggle = SidebarIconButton()
    private var controlsWidth: NSLayoutConstraint!
    private let stack = NSStackView()
    private let tabScroll = TabScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.cornerPadding)
        tabScroll.drawsBackground = false
        // This custom header owns its geometry; the native toolbar only
        // selects the window outline and must not inset the tab viewport.
        tabScroll.automaticallyAdjustsContentInsets = false
        // Scrolling is handled directly so no system preference or gesture
        // can make an overlay indicator appear over the tabs.
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.documentView = stack
        tabScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHover),
                                               name: NSView.boundsDidChangeNotification, object: tabScroll.contentView)
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        addSubview(tabScroll)
        // Expanded sidebars host their own controls; this standalone chevron
        // only appears when the sidebar is collapsed.
        SidebarIconButton.configure(toggle, symbol: "sidebar.left", label: "Expand sidebar",
                                    target: self, action: #selector(toggleSidebar))
        toggle.chevronName = "chevron.right"
        controls.addSubview(toggle)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        controlsWidth = controls.widthAnchor.constraint(equalToConstant: 0)
        dropGap.translatesAutoresizingMaskIntoConstraints = false
        dropGapWidth = dropGap.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            dropGapWidth, dropGap.heightAnchor.constraint(equalToConstant: 31),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor), controls.topAnchor.constraint(equalTo: topAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor), controlsWidth,
            tabScroll.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: Self.cornerPadding),
            tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabScroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.cornerPadding),
            tabScroll.heightAnchor.constraint(equalToConstant: 31),
            toggle.widthAnchor.constraint(equalToConstant: 30), toggle.heightAnchor.constraint(equalToConstant: 31),
            toggle.centerYAnchor.constraint(equalTo: tabScroll.centerYAnchor),
            toggle.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: Self.cornerPadding),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // This spacer overlaps the expanded sidebar's header. Let clicks
        // reach its buttons below, while keeping our collapsed toggle active.
        return hit === controls ? nil : hit
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshHover() {
        guard let window else { return }
        updateHover(at: window.mouseLocationOutsideOfEventStream)
    }

    /// Resolve against current geometry, including the clip view, instead of
    /// trusting enter/exit events for tracking areas moving under the mouse.
    func updateHover(at windowPoint: NSPoint) {
        let inside = !isHiddenOrHasHiddenAncestor && tabScroll.bounds.contains(tabScroll.convert(windowPoint, from: nil))
        for view in stack.arrangedSubviews {
            let hovered = inside && view.bounds.contains(view.convert(windowPoint, from: nil))
            (view as? TabItemView)?.setHovered(hovered)
            (view as? NewTabButton)?.setHovered(hovered)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHover()
    }

    func configureSidebar(visible: Bool, collapsed: Bool, width: CGFloat) {
        controlsWidth.constant = visible ? (collapsed ? 45 : width) : 0
        controls.isHidden = !visible
        toggle.isHidden = !collapsed
        toggle.contentTintColor = Theme.secondary
        toggle.needsDisplay = true
    }
    func fadeInTabs() { SidebarTransition.fadeIn([tabScroll]) }

    @objc private func toggleSidebar() { onToggleSidebar?() }

    func update(tabs: [(name: String, edited: Bool)], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabCount = tabs.count
        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(
                title: tab.edited ? "\(tab.name) •" : tab.name,
                active: index == selected
            )
            item.onHoverChange = { [weak self] in self?.refreshHover() }
            item.onPress = { [weak self] event in self?.trackPress(on: index, event: event) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            stack.addArrangedSubview(item)
        }
        let plus = NewTabButton()
        plus.onHoverChange = { [weak self] in self?.refreshHover() }
        plus.onClick = { [weak self, weak plus] in
            guard let plus else { return }
            self?.onNewTab?(plus)
        }
        stack.addArrangedSubview(plus)
        stack.setFrameSize(NSSize(width: stack.fittingSize.width, height: 31))
        layoutSubtreeIfNeeded()
        if stack.arrangedSubviews.indices.contains(selected) {
            let selectedTab = stack.arrangedSubviews[selected]
            selectedTab.scrollToVisible(selectedTab.bounds)
        }
        refreshHover()
    }

    // MARK: - Dragging tabs

    private var tabItems: [TabItemView] { stack.arrangedSubviews.compactMap { $0 as? TabItemView } }

    /// The row the tabs ride in, in screen coordinates.
    private var rowOnScreen: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(tabScroll.convert(tabScroll.bounds, to: nil))
    }

    /// Whether a tab dragged to `screenPoint` is over this strip (with a
    /// little slack above and below).
    func stripContains(_ screenPoint: NSPoint) -> Bool {
        !isHiddenOrHasHiddenAncestor && rowOnScreen.insetBy(dx: 0, dy: -12).contains(screenPoint)
    }

    /// Where tab `index` sits, from the window's top-left corner (y down).
    func tabOffset(at index: Int) -> NSPoint {
        let items = tabItems
        guard let window, items.indices.contains(index) else { return NSPoint(x: Self.cornerPadding, y: Self.cornerPadding) }
        let frame = items[index].convert(items[index].bounds, to: nil)
        return NSPoint(x: frame.minX, y: window.frame.height - frame.maxY)
    }

    /// Where a tab centered at `screenX` would drop among this strip's
    /// tabs, measured as if no gap were open.
    func dropIndex(at screenX: CGFloat) -> Int {
        guard let window else { return tabCount }
        let x = stack.convert(window.convertPoint(fromScreen: NSPoint(x: screenX, y: 0)), from: nil).x
        var edge = stack.edgeInsets.left
        var index = 0
        for item in tabItems where !item.isHidden {
            if edge + item.frame.width / 2 < x { index += 1 }
            edge += item.frame.width + stack.spacing
        }
        return index
    }

    /// Opens a tab-wide gap before tab `index`, where a dragged tab would drop.
    func showDropGap(at index: Int, width: CGFloat) {
        let arranged = dropGap.superview != nil
        if arranged, stack.arrangedSubviews.firstIndex(of: dropGap) == index, dropGapWidth.constant == width { return }
        animateLayout {
            if arranged { stack.removeArrangedSubview(dropGap); dropGap.removeFromSuperview() }
            dropGapWidth.constant = width
            stack.insertArrangedSubview(dropGap, at: min(index, tabItems.count))
        }
    }

    func clearDropGap() {
        guard dropGap.superview != nil else { return }
        animateLayout { stack.removeArrangedSubview(dropGap); dropGap.removeFromSuperview() }
    }

    /// Lets the tabs slide into place around a change.
    private func animateLayout(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            context.allowsImplicitAnimation = true
            changes()
            stack.setFrameSize(NSSize(width: stack.fittingSize.width, height: 31))
            stack.layoutSubtreeIfNeeded()
        }
    }

    /// A press on tab `index` selects it, then follows the drag (with a
    /// synchronous event loop, since selecting rebuilds the strip). In the
    /// strip the tab slides past its neighbors; pulled clear, it carries a
    /// preview of its page and drops as a new window, or into another
    /// window's strip. The only tab moves its window instead.
    private func trackPress(on index: Int, event: NSEvent) {
        guard let window else { return }
        onSelect?(index)
        guard tabCount > 1 else { window.performDrag(with: event); return }
        let items = tabItems
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let size = item.bounds.size
        let start = window.convertPoint(toScreen: event.locationInWindow)
        // Where the cursor holds the tab, from its bottom-left.
        let held = item.convert(event.locationInWindow, from: nil)
        let grab = NSPoint(x: held.x, y: item.isFlipped ? size.height - held.y : held.y)
        var ghost: TabDragGhost?
        var target: TabBarView?
        var origin = NSPoint.zero
        var cursor = start
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            cursor = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .leftMouseUp { break }
            if ghost == nil {
                guard hypot(cursor.x - start.x, cursor.y - start.y) > 4 else { continue }
                ghost = TabDragGhost(title: item.title, size: size, page: dragPreview?())
                item.alphaValue = 0
                ghost?.show()
            }
            guard let ghost else { continue }
            origin = NSPoint(x: cursor.x - grab.x, y: cursor.y - grab.y)
            let home = stripContains(cursor)
            let over = home ? nil : dropTarget?(cursor)
            if over !== target { target?.clearDropGap(); target = over }
            if home {
                let row = rowOnScreen
                origin.y = row.midY - size.height / 2
                origin.x = min(max(origin.x, row.minX), row.maxX - size.width)
                slide(item, toMinX: origin.x, maxX: origin.x + size.width)
            } else {
                if !item.isHidden { animateLayout { item.isHidden = true } }
                if let target {
                    origin.y = target.rowOnScreen.midY - size.height / 2
                    target.showDropGap(at: target.dropIndex(at: origin.x + size.width / 2), width: size.width)
                }
            }
            ghost.showPreview(!home && target == nil)
            ghost.move(to: origin)
        }
        guard let ghost else { return }
        let fromTop = NSPoint(x: grab.x, y: size.height - grab.y)
        if !item.isHidden {
            // Settle into the slot, then commit the new order.
            let slot = tabItems.firstIndex(of: item) ?? index
            let frame = window.convertToScreen(item.convert(item.bounds, to: nil))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                ghost.tab.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                ghost.close()
                item.alphaValue = 1
                if slot != index { self?.onMove?(index, slot) }
            })
            return
        }
        ghost.close()
        item.alphaValue = 1
        if let target {
            let destination = target.dropIndex(at: origin.x + size.width / 2)
            target.clearDropGap()
            onTransfer?(index, target, destination)
        } else {
            onDetach?(index, cursor, fromTop)
        }
    }

    /// Moves the dragged tab's (empty) slot to follow the ghost: past a
    /// neighbor once the ghost covers half of it.
    private func slide(_ item: TabItemView, toMinX screenMinX: CGFloat, maxX screenMaxX: CGFloat) {
        guard let window else { return }
        let minX = stack.convert(window.convertPoint(fromScreen: NSPoint(x: screenMinX, y: 0)), from: nil).x
        let maxX = stack.convert(window.convertPoint(fromScreen: NSPoint(x: screenMaxX, y: 0)), from: nil).x
        if item.isHidden {
            // Back from outside: reopen where the ghost is.
            let slot = tabItems.filter { $0 !== item && !$0.isHidden && $0.frame.midX < (minX + maxX) / 2 }.count
            animateLayout {
                stack.insertArrangedSubview(item, at: slot)
                item.isHidden = false
            }
            return
        }
        let items = tabItems
        guard let slot = items.firstIndex(of: item) else { return }
        if slot + 1 < items.count, maxX > items[slot + 1].frame.midX {
            animateLayout { stack.insertArrangedSubview(item, at: slot + 1) }
        } else if slot > 0, minX < items[slot - 1].frame.midX {
            animateLayout { stack.insertArrangedSubview(item, at: slot - 1) }
        }
    }
}

/// An indicator-free strip that still accepts trackpad and mouse-wheel input.
private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        var proposed = contentView.bounds
        proposed.origin.x -= delta * scale
        let constrained = contentView.constrainBoundsRect(proposed)
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }
}

/// The [+] at the end of the tab strip.
private final class NewTabButton: NSView {

    var onHoverChange: (() -> Void)?
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabBarView.pillRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 31),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?() }
    override func mouseExited(with event: NSEvent) { onHoverChange?() }

    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        layer?.backgroundColor = NSColor.white.withAlphaComponent(value ? 0.06 : 0).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        drawGlyphCentered("+", size: 22, color: hovered ? Theme.foreground : Theme.secondary, in: bounds)
    }
}

/// Draws a glyph so its actual ink (not its layout box, which includes
/// ascent/descent whitespace) is centered in `rect`. The ink bounds come
/// from the font's glyph metrics, relative to the baseline; draw(at:) puts
/// the line box origin (baseline minus descent) at the given point.
private func drawGlyphCentered(_ string: String, size: CGFloat, color: NSColor, in rect: NSRect) {
    let font = Theme.interfaceFont(size: size)
    let text = NSAttributedString(string: string, attributes: [
        .font: font,
        .foregroundColor: color,
    ])
    var chars = Array(string.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) else {
        text.draw(at: NSPoint(x: rect.midX - text.size().width / 2,
                              y: rect.midY - text.size().height / 2))
        return
    }
    let ink = CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, nil, glyphs.count)
    text.draw(at: NSPoint(
        x: rect.midX - ink.midX,
        y: rect.midY - ink.midY + font.descender
    ))
}

private final class TabItemView: NSView {

    var onHoverChange: (() -> Void)?
    private var hovered = false
    var onPress: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?

    let title: String
    private let label: NSTextField
    private let closeButton = HoverCloseButton()

    // Normally the text fills the tab edge-to-edge; on hover the × overlays
    // the trailing end and the label truncates into the remaining space.
    private var labelTrailingNormal: NSLayoutConstraint!
    private var labelTrailingHover: NSLayoutConstraint!
    private var frozenWidth: NSLayoutConstraint?

    init(title: String, active: Bool) {
        self.title = title
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabBarView.pillRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = active
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor

        label.font = Theme.interfaceFont(size: 13.5)
        label.textColor = active ? Theme.foreground : Theme.secondary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.isHidden = true
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        labelTrailingNormal = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13)
        labelTrailingHover = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 31),
            labelTrailingNormal,
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Route every click to the tab itself (the label subview would
    /// otherwise claim hits and let the window-move machinery take the
    /// drag, since non-opaque views default mouseDownCanMoveWindow=true).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?() }
    override func mouseExited(with event: NSEvent) { onHoverChange?() }

    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        if value {
            // Only one frozen-width constraint may exist, even if AppKit
            // delivers repeated enter events while the strip is scrolling.
            let freeze = widthAnchor.constraint(equalToConstant: bounds.width)
            freeze.isActive = true
            frozenWidth = freeze
            labelTrailingNormal.isActive = false
            labelTrailingHover.isActive = true
            closeButton.isHidden = false
        } else {
            closeButton.isHidden = true
            labelTrailingHover.isActive = false
            labelTrailingNormal.isActive = true
            frozenWidth?.isActive = false
            frozenWidth = nil
        }
    }

    // Selecting the tab rebuilds the strip, so the bar tracks the drag.
    override func mouseDown(with event: NSEvent) { onPress?(event) }
}

/// A borderless, click-through window that follows the cursor.
private func floatingWindow(_ content: NSView) -> NSWindow {
    let window = NSWindow(contentRect: content.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.level = .floating
    window.ignoresMouseEvents = true
    window.hasShadow = true
    window.isReleasedWhenClosed = false
    window.contentView = content
    return window
}

/// What follows the cursor while a tab is dragged: the tab itself and,
/// once it is clear of every strip, a small preview of its page hanging
/// beneath it, as the window it will become.
private final class TabDragGhost {
    let tab: NSWindow
    private let preview: NSWindow?

    init(title: String, size: NSSize, page: NSImage?) {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.96).cgColor
        content.layer?.cornerRadius = TabBarView.pillRadius
        content.layer?.cornerCurve = .continuous
        let item = TabItemView(title: title, active: true)
        item.frame = content.bounds
        item.translatesAutoresizingMaskIntoConstraints = true
        item.autoresizingMask = [.width, .height]
        content.addSubview(item)
        tab = floatingWindow(content)

        if let page, page.size.width > 0 {
            let width: CGFloat = 260
            let height = min(width * page.size.height / page.size.width, 320)
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            imageView.image = page
            imageView.imageScaling = .scaleAxesIndependently
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 12
            imageView.layer?.cornerCurve = .continuous
            imageView.layer?.masksToBounds = true
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            preview = floatingWindow(imageView)
            preview?.alphaValue = 0
        } else {
            preview = nil
        }
    }

    func show() {
        preview?.orderFront(nil)
        tab.orderFront(nil)
    }

    func move(to origin: NSPoint) {
        tab.setFrameOrigin(origin)
        preview?.setFrameTopLeftPoint(NSPoint(x: origin.x, y: origin.y - 6))
    }

    func showPreview(_ showing: Bool) {
        guard let preview, (preview.alphaValue > 0) != showing else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            preview.animator().alphaValue = showing ? 0.94 : 0
        }
    }

    func close() {
        preview?.close()
        tab.close()
    }
}

/// A small "×" that swallows its own clicks so they don't select the tab.
/// Also the settings panel's close affordance; its native titlebar controls
/// are hidden to match the editor.
final class HoverCloseButton: NSView {

    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        drawGlyphCentered("×", size: 22, color: hovered ? Theme.foreground : Theme.secondary, in: bounds)
    }
}

/// Draw symbols directly, like the other tab controls, without AppKit's bezel.
final class SidebarIconButton: NSButton {
    var symbolImage: NSImage?
    var chevronName: String?
    static func configure(_ button: SidebarIconButton, symbol: String, label: String,
                          target: AnyObject, action: Selector) {
        button.symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.title = ""
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = target; button.action = action
        button.wantsLayer = true; button.layer?.cornerRadius = 7
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(.init(paletteColors: [contentTintColor ?? Theme.secondary]))
        let image = symbolImage.withSymbolConfiguration(configuration) ?? symbolImage
        let scale = min(16 / image.size.width, 16 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        if let chevronName, let chevron = NSImage(systemSymbolName: chevronName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            chevron.draw(in: NSRect(x: bounds.midX + 1, y: bounds.midY - 3, width: 3, height: 6))
        }
    }
}
