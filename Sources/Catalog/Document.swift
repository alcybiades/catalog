import AppKit

/// One open tab. A file tab owns its text storage, undo stack, and
/// selection; a Wikipedia (or home) tab owns its page instead.
final class Document {
    var url: URL?
    let kind: FileKind
    let wiki: WikiPage?
    let storage: NSTextStorage
    let undoManager = UndoManager()
    var selection = NSRange(location: 0, length: 0)
    /// Where the note was scrolled as it left for another window.
    var scrollOrigin: NSPoint?
    var edited = false
    /// The file's text as last read or written here: the base for telling
    /// an outside change (the assistant's) from unsaved edits.
    var diskText: String?
    /// Text an outside change put into this note while its tab was in the
    /// background, highlighted when the tab is next shown.
    var pendingHighlight: [NSRange] = []
    /// Title chosen before the document has a file (used as the save name).
    var customTitle: String?
    /// Names this buffer's crash-recovery draft across launches.
    var recoveryID = UUID()
    /// The tab a ⌘-clicked link opened this one from.
    weak var opener: Document?

    init(url: URL? = nil, content: String = "") {
        self.url = url
        kind = url.map(FileKind.classify) ?? .markdown
        wiki = nil
        storage = NSTextStorage(string: content, attributes: Theme.baseAttributes)
        if url != nil { diskText = content }
    }

    @MainActor init(wiki page: WikiPage) {
        url = nil
        kind = .wiki
        wiki = page
        storage = NSTextStorage(string: "", attributes: Theme.baseAttributes)
    }

    @MainActor var name: String { wiki?.title ?? url?.lastPathComponent ?? customTitle ?? "untitled" }

    /// An untouched untitled note or an idle home page: opening something
    /// replaces it instead of adding a tab.
    @MainActor var isPlaceholder: Bool {
        if let wiki { return wiki.style == .home && wiki.path.isEmpty }
        return url == nil && !edited && storage.length == 0
    }

    /// The filename without extension — what the inline title shows.
    var displayTitle: String {
        if let url { return url.deletingPathExtension().lastPathComponent }
        return customTitle ?? "untitled"
    }
}
