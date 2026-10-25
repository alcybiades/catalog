import AppKit

/// Notion-style floating formatting bar that appears above the selection:
/// bold, italic, and the accent-color palette, in the app's terminal styling.
final class SelectionToolbar {

    private weak var textView: EditorTextView?
    private let panel: NSPanel
    private var pending: DispatchWorkItem?

    init(textView: EditorTextView) {
        self.textView = textView
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        buildContent()
    }

    private func buildContent() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.background.withAlphaComponent(0.94).cgColor
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        var views: [NSView] = []
        views.append(ToolbarIconButton(symbolName: "bold", fallback: "B", toolTip: "Bold") { [weak self] in
            self?.textView?.toggleBoldMD(nil)
        })
        views.append(ToolbarIconButton(symbolName: "italic", fallback: "I", toolTip: "Italic") { [weak self] in
            self?.textView?.toggleItalicMD(nil)
        })
        views.append(ToolbarIconButton(symbolName: "chevron.left.forwardslash.chevron.right",
                                       fallback: "<>", toolTip: "Code") { [weak self] in
            self?.textView?.toggleCodeMD(nil)
        })
        views.append(ToolbarIconButton(symbolName: "curlybraces",
                                       fallback: "{}", toolTip: "Code Block") { [weak self] in
            self?.textView?.toggleCodeBlockMD(nil)
        })

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
        views.append(divider)

        for (name, hex) in Theme.accentColors {
            guard let color = NSColor(hexString: hex) else { continue }
            views.append(ColorDotButton(color: color, toolTip: name) { [weak self] in
                self?.textView?.applyColor(hex: hex)
            })
        }
        views.append(ColorDotButton(color: Theme.halfOpacityText, toolTip: "50% Opacity") { [weak self] in
            self?.textView?.applyHalfOpacity()
        })

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - Visibility

    /// Debounced: waits for the mouse to be released so the bar doesn't
    /// chase an in-progress drag selection.
    func noteSelectionChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func evaluate() {
        guard let textView, let window = textView.window else { hide(); return }
        let sel = textView.selectedRange()
        guard sel.length > 0, window.isKeyWindow, window.firstResponder === textView else {
            hide()
            return
        }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            noteSelectionChanged()
            return
        }
        let rect = textView.firstRect(forCharacterRange: sel, actualRange: nil)
        guard rect.width > 0 || rect.height > 0 else { hide(); return }

        let size = panel.frame.size
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 8)
        if let screen = window.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y + size.height > visible.maxY {
                origin.y = rect.minY - size.height - 8
            }
        }
        panel.setFrameOrigin(origin)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        pending?.cancel()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func teardown() {
        hide()
        panel.close()
    }
}

/// Icon button (SF Symbol with text fallback): dim, brightens on hover.
private final class ToolbarIconButton: NSView {

    private let action: () -> Void
    private let imageView = NSImageView()
    private let fallbackLabel = NSTextField(labelWithString: "")
    private var hovered = false { didSet { applyTint() } }

    init(symbolName: String, fallback: String, toolTip: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true

        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            imageView.image = symbol.withSymbolConfiguration(config)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            fallbackLabel.stringValue = fallback
            fallbackLabel.font = Theme.interfaceFont(size: 14)
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(fallbackLabel)
            NSLayoutConstraint.activate([
                fallbackLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                fallbackLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTint() {
        let color = hovered ? Theme.foreground : Theme.secondary
        imageView.contentTintColor = color
        fallbackLabel.textColor = color
    }

    override var mouseDownCanMoveWindow: Bool { false }

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

    override func mouseDown(with event: NSEvent) {
        action()
    }
}

/// A solid color circle; a soft ring appears on hover.
private final class ColorDotButton: NSView {

    private let action: () -> Void
    private let color: NSColor
    private var hovered = false { didSet { needsDisplay = true } }

    init(color: NSColor, toolTip: String, action: @escaping () -> Void) {
        self.color = color
        self.action = action
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

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

    override func mouseDown(with event: NSEvent) {
        action()
    }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 3, dy: 3)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        if hovered {
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}
