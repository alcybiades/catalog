import AppKit

/// Minimal terminal-styled tab strip with hover-close and drag-to-detach.
final class TabBarView: NSView, ThemeRefreshing {

    /// Equal gap from the window's top-left corner to the first tab, both axes.
    static let cornerPadding: CGFloat = 15
    static let pillRadius: CGFloat = 11

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The [+] was clicked; the view anchors the new-tab menu beneath it.
    var onNewTab: ((NSView) -> Void)?
    /// Fired when a tab is dragged out of the bar; point is in screen coords.
    var onDetach: ((Int, NSPoint) -> Void)?

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
        NSLayoutConstraint.activate([
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

    func applyTheme() { toggle.contentTintColor = Theme.secondary }

    @objc private func toggleSidebar() { onToggleSidebar?() }

    func update(tabs: [(name: String, edited: Bool)], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in tabs.enumerated() {
            let item = TabItemView(
                title: tab.edited ? "\(tab.name) •" : tab.name,
                active: index == selected
            )
            item.onHoverChange = { [weak self] in self?.refreshHover() }
            item.onClick = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            item.onDetach = { [weak self] screenPoint in self?.onDetach?(index, screenPoint) }
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
        layer?.backgroundColor = Theme.wash.withAlphaComponent(value ? 0.06 : 0).cgColor
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
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDetach: ((NSPoint) -> Void)?

    private let title: String
    private let label: NSTextField
    private let closeButton = HoverCloseButton()

    // Normally the text fills the tab edge-to-edge; on hover the × overlays
    // the trailing end and the label truncates into the remaining space.
    private var labelTrailingNormal: NSLayoutConstraint!
    private var labelTrailingHover: NSLayoutConstraint!
    private var frozenWidth: NSLayoutConstraint?

    private var ghost: NSWindow?

    init(title: String, active: Bool) {
        self.title = title
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TabBarView.pillRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = active
            ? Theme.wash.withAlphaComponent(0.08).cgColor
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

    // MARK: - Click / drag-to-detach

    // Selecting the tab rebuilds the tab bar, which removes this view from
    // the hierarchy mid-gesture — so ordinary mouseDragged/mouseUp dispatch
    // never reaches it. Track the drag with a synchronous event loop
    // instead, which keeps working after the rebuild.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // The tab bar strip in window coordinates, before self is rebuilt.
        let barOnScreen: NSRect
        if let bar = enclosingTabBar() {
            barOnScreen = window.convertToScreen(bar.convert(bar.bounds, to: nil))
        } else {
            barOnScreen = .zero
        }

        onClick?()

        let origin = event.locationInWindow
        var detachPoint: NSPoint?
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let point = next.locationInWindow
            if next.type == .leftMouseUp {
                if ghost != nil {
                    let screenPoint = window.convertPoint(toScreen: point)
                    if !barOnScreen.insetBy(dx: -24, dy: -24).contains(screenPoint) {
                        detachPoint = screenPoint
                    }
                }
                break
            }
            if ghost == nil, hypot(point.x - origin.x, point.y - origin.y) > 12 {
                makeGhost()
            }
            if let ghost {
                let screenPoint = window.convertPoint(toScreen: point)
                ghost.setFrameOrigin(NSPoint(x: screenPoint.x - ghost.frame.width / 2,
                                             y: screenPoint.y - ghost.frame.height / 2))
            }
        }
        ghost?.close()
        ghost = nil
        if let detachPoint { onDetach?(detachPoint) }
    }

    private func enclosingTabBar() -> NSView? {
        var view: NSView? = superview
        while view != nil, !(view is TabBarView) { view = view?.superview }
        return view
    }

    /// A floating pill following the cursor while dragging, like browsers.
    private func makeGhost() {
        let ghostLabel = NSTextField(labelWithString: title)
        ghostLabel.font = Theme.interfaceFont(size: 13.5)
        ghostLabel.textColor = Theme.foreground
        let size = ghostLabel.intrinsicContentSize
        let frame = NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 10)

        let panel = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.85).cgColor
        content.layer?.cornerRadius = 6
        ghostLabel.frame = NSRect(x: 12, y: 5, width: size.width, height: size.height)
        content.addSubview(ghostLabel)
        panel.contentView = content
        panel.orderFront(nil)
        ghost = panel
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
