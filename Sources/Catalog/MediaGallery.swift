import AppKit
import UniformTypeIdentifiers

struct MediaSection {
    let directory: URL
    let images: [URL]
}

enum MediaGallery {
    /// Keep each image in its actual containing directory, even when browsing
    /// an ancestor. Never traverse symlinks back into this tree or outside it.
    static func sections(in root: URL, cancelled: () -> Bool = { false }) throws -> [MediaSection] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              FileManager.default.isReadableFile(atPath: root.path) else { throw CocoaError(.fileReadNoPermission) }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var grouped: [String: (URL, [URL])] = [:]
        var imageExtensions: [String: Bool] = [:]
        while let url = enumerator?.nextObject() as? URL {
            if cancelled() { return [] }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
            guard values?.isDirectory != true else { continue }
            let ext = url.pathExtension.lowercased()
            let isImage = imageExtensions[ext] ?? (UTType(filenameExtension: ext)?.conforms(to: .image) == true)
            imageExtensions[ext] = isImage
            guard isImage else { continue }
            let directory = url.deletingLastPathComponent().standardizedFileURL
            if grouped[directory.path] == nil { grouped[directory.path] = (directory, []) }
            grouped[directory.path]?.1.append(url)
        }
        return grouped.values.sorted {
            FileReference.relativePath(to: $0.0, from: root).localizedStandardCompare(FileReference.relativePath(to: $1.0, from: root)) == .orderedAscending
        }.map { directory, images in
            MediaSection(directory: directory, images: images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }

    static func breadcrumbs(to url: URL, root: URL?) -> [URL] {
        let url = url.standardizedFileURL
        let root = root?.standardizedFileURL
        let base = root.flatMap { candidate in
            url.path == candidate.path || url.path.hasPrefix(candidate.path + "/") ? candidate : nil
        } ?? url.deletingLastPathComponent()
        var result = [url]
        var parent = url
        while parent.path != base.path, parent.path != "/" {
            parent = parent.deletingLastPathComponent()
            result.insert(parent, at: 0)
        }
        return result
    }
}

/// Compact clickable path, horizontally scrollable for deeply nested folders.
final class BreadcrumbBar: NSView {
    var onNavigate: ((URL) -> Void)?
    private let scroll = NSScrollView()
    private let content = NSView()
    private var contentWidth: CGFloat = 0
    private var paths: [URL] = []
    private var revealEnd = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(url: URL, root: URL?, isImage: Bool = false) {
        paths = MediaGallery.breadcrumbs(to: url, root: root)
        content.subviews.forEach { $0.removeFromSuperview() }
        contentWidth = 0
        func append(_ view: NSView, size: NSSize) {
            view.frame = NSRect(x: contentWidth, y: (28 - size.height) / 2, width: size.width, height: size.height)
            content.addSubview(view)
            contentWidth += size.width + 7
        }
        for (index, path) in paths.enumerated() {
            if index > 0 {
                let separator = NSImageView()
                separator.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
                separator.contentTintColor = Theme.secondary
                append(separator, size: NSSize(width: 5, height: 9))
            }
            let name = path.lastPathComponent.isEmpty ? "/" : path.lastPathComponent
            if isImage && index == paths.count - 1 {
                let label = NSTextField(labelWithString: name)
                label.font = Theme.interfaceFont(size: 12.5); label.textColor = Theme.heading ?? Theme.foreground
                append(label, size: label.fittingSize)
            } else {
                let button = NSButton(title: name, target: self, action: #selector(navigate(_:)))
                button.isBordered = false; button.bezelStyle = .inline
                button.font = Theme.interfaceFont(size: 12.5); button.contentTintColor = Theme.secondary
                // Keep scrolling headers out of AppKit's tooltip manager.
                button.tag = index
                button.setAccessibilityLabel("Open gallery: " + name)
                append(button, size: button.fittingSize)
            }
        }
        contentWidth = max(0, contentWidth - 7)
        revealEnd = true
        needsLayout = true
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        content.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        for view in content.subviews {
            var frame = view.frame
            frame.origin.y = (bounds.height - frame.height) / 2
            if view.frame != frame { view.frame = frame }
        }
        if revealEnd, let last = content.subviews.last {
            last.scrollToVisible(last.bounds)
            revealEnd = false
        }
    }
    @objc private func navigate(_ sender: NSButton) {
        guard paths.indices.contains(sender.tag) else { return }
        onNavigate?(paths[sender.tag])
    }
}

final class GalleryHeader: NSView, NSCollectionViewElement {
    let breadcrumbs = BreadcrumbBar()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(breadcrumbs)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        breadcrumbs.frame = NSRect(x: 24, y: 0, width: max(0, bounds.width - 48), height: bounds.height)
    }
}
