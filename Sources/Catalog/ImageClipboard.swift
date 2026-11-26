import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Copying images out of Catalog. Notes, previews and articles draw their
/// images rather than holding them as selectable content, so their menus
/// put the picture itself on the pasteboard: PNG and TIFF, which every app
/// pastes, plus the file's URL when it is local (so Finder pastes the file).
enum ImageClipboard {

    /// Writes image `data` (any format ImageIO reads). Returns false when it
    /// isn't an image.
    @discardableResult
    static func write(data: Data, fileURL: URL? = nil, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = isPNG ? data : rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Copies a local image file, read whole (not the on-screen thumbnail).
    @discardableResult
    static func copy(file url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return write(data: data, fileURL: url, to: pasteboard)
    }

    /// Downloads a web image and copies it; beeps if that fails.
    static func copy(remote url: URL, session: URLSession = .shared) {
        Task {
            let data = try? await session.data(from: url).0
            await MainActor.run {
                if data.map({ write(data: $0) }) != true { NSSound.beep() }
            }
        }
    }

    /// Copy Image (for images), Copy as Embedded Quote and Reveal in Finder
    /// for a local media file; none for anything else.
    static func menuItems(for url: URL) -> [NSMenuItem] {
        guard url.isFileURL, EmbeddedQuote.isMedia(url) else { return [] }
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = MediaActions.shared
            item.representedObject = url
            items.append(item)
        }
        if FileKind.classify(url) == .image { add("Copy Image", #selector(MediaActions.copyImage(_:))) }
        add("Copy as Embedded Quote", #selector(MediaActions.copyQuote(_:)))
        add("Reveal in Finder", #selector(MediaActions.reveal(_:)))
        return items
    }

    /// The image's address, as a URL and as text.
    static func copyAddress(_ url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.URL, .string], owner: nil)
        pasteboard.setString(url.absoluteString, forType: .URL)
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}

/// Targets for media menu items, which carry their file as the item's
/// represented object.
final class MediaActions: NSObject {
    static let shared = MediaActions()

    @objc func copyImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, ImageClipboard.copy(file: url) else { NSSound.beep(); return }
    }

    @objc func copyQuote(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        EmbeddedQuote.write(EmbeddedQuote.mediaQuote(file: url), to: .general)
    }

    @objc func reveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
