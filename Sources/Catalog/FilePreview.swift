import AppKit

/// A tab's non-text file: an image, shown whole, or a note that the file
/// cannot be rendered.
final class FilePreview: NSView, ThemeRefreshing {
    private let imageView = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private var shownURL: URL?
    private var originalRequest: ImageRequest?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        message.font = Theme.interfaceFont(size: 14); message.alignment = .center
        applyTheme()
        [imageView, message].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTheme() { message.textColor = Theme.secondary }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        imageView.frame = imageFrame
        message.frame = NSRect(x: 20, y: bounds.midY - 30, width: max(0, bounds.width - 40), height: 60)
    }
    private var imageFrame: NSRect {
        NSRect(x: 24, y: 24, width: max(0, bounds.width - 48), height: max(0, bounds.height - 48))
    }
    func suspend() {
        originalRequest?.cancel(); originalRequest = nil
        imageView.image = nil
        shownURL = nil
    }
    /// Shows `doc`; an image grows from `origin` (window coordinates), the
    /// icon it was opened from.
    func show(_ doc: Document, from origin: NSRect? = nil) {
        // Chrome refreshes re-show the current file constantly.
        guard doc.url == nil || doc.url != shownURL else { return }
        suspend()
        shownURL = doc.url
        imageView.isHidden = doc.kind != .image
        guard let url = doc.url, doc.kind == .image else {
            message.stringValue = "Rendering not yet supported"
            message.isHidden = false
            return
        }
        message.stringValue = "Loading image…"; message.isHidden = false
        originalRequest = ImageLoader.shared.original(url) { [weak self] image in
            guard let self else { return }
            self.originalRequest = nil
            self.imageView.image = image
            self.message.stringValue = "This image could not be loaded"
            self.message.isHidden = image != nil
            if let origin, image != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.imageView.frame = self.convert(origin, from: nil)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.imageView.animator().frame = self.imageFrame
                }
            }
        }
    }
}
