import AppKit
import QuartzCore

final class FolderSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onRefresh: (() -> Void)?
    var onOpen: ((URL, Bool) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onMediaMode: ((Bool) -> Void)?
    private let outline = SidebarOutlineView()
    private let scroll = SidebarScrollView()
    private let toggle = SidebarIconButton()
    private let filesButton = SidebarIconButton()
    private let mediaButton = SidebarIconButton()
    private var root: FileNode?
    var mediaMode = false { didSet { if let url = root?.url { setRoot(url) }; refreshControls() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // The sidebar reaches the window's top edge and owns its controls,
        // laid out on the tab row's centerline (cornerPadding + 31pt row).
        for (button, symbol, label, action) in [
            (toggle, "sidebar.left", "Collapse sidebar", #selector(collapse)),
            (filesButton, "doc", "Files", #selector(selectFiles)),
            (mediaButton, "photo", "Media", #selector(selectMedia)),
        ] {
            SidebarIconButton.configure(button, symbol: symbol, label: label, target: self, action: action)
            addSubview(button)
        }
        toggle.chevronName = "chevron.left"
        refreshControls()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 25
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = 13
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
        outline.contextMenu = { [weak self] in self?.contextMenu() }
        scroll.contextMenu = { [weak self] in self?.contextMenu() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let rowY = bounds.height - TabBarView.cornerPadding - 31
        toggle.frame = NSRect(x: TabBarView.cornerPadding, y: rowY, width: 30, height: 31)
        filesButton.frame = NSRect(x: 55, y: rowY, width: 30, height: 31)
        mediaButton.frame = NSRect(x: 93, y: rowY, width: 30, height: 31)
        let controlsHeight = TabBarView.cornerPadding + 31 + 8
        // Extra trailing inset keeps rows clear of the resize divider.
        scroll.frame = bounds.width < 16 ? .zero : NSRect(x: 6, y: 8, width: bounds.width - 16, height: max(0, bounds.height - controlsHeight - 8))
    }
    func fadeInContents() {
        SidebarTransition.fadeIn([filesButton, mediaButton, scroll])
    }
    private func refreshControls() {
        toggle.contentTintColor = Theme.secondary
        filesButton.contentTintColor = mediaMode ? Theme.secondary : Theme.foreground
        mediaButton.contentTintColor = mediaMode ? Theme.foreground : Theme.secondary
        filesButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(mediaMode ? 0 : 0.08).cgColor
        mediaButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(mediaMode ? 0.08 : 0).cgColor
        [toggle, filesButton, mediaButton].forEach { $0.needsDisplay = true }
    }
    @objc private func collapse() { onToggleSidebar?() }
    @objc private func selectFiles() { onMediaMode?(false) }
    @objc private func selectMedia() { onMediaMode?(true) }
    func setRoot(_ url: URL) {
        let expanded = Set((0..<outline.numberOfRows).compactMap { row -> String? in
            guard let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) else { return nil }
            return node.url.path
        })
        let sameRoot = root?.url.standardizedFileURL == url.standardizedFileURL
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        root = FileNode(url)
        outline.reloadData()
        if !sameRoot, let root { outline.expandItem(root) }
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, expanded.contains(node.url.path) { outline.expandItem(node) }
            row += 1
        }
        if sameRoot, let selected { select(selected) }
        updateRootActions()
    }
    @objc func refresh() { if let url = root?.url { setRoot(url); onRefresh?() } }
    func refreshFont() {
        outline.reloadData()
        updateRootActions()
    }
    var creationDirectory: URL? {
        guard let root else { return nil }
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return root.url }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if !mediaMode, let directory = creationDirectory {
            for (title, action) in [("New Folder…", #selector(newFolder(_:))), ("New File…", #selector(newFile(_:)))] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = directory
            }
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Refresh Folder", action: #selector(refresh), keyEquivalent: "").target = self
        return menu
    }
    @objc private func newFolder(_ sender: Any?) { promptForItem(.folder, sender: sender) }
    @objc private func newFile(_ sender: Any?) { promptForItem(.file, sender: sender) }
    @objc private func newMarkdown(_ sender: Any?) { promptForItem(.markdown, sender: sender) }

    private func promptForItem(_ kind: WorkspaceItemKind, sender: Any?) {
        guard !mediaMode, let window,
              let directory = (sender as? NSMenuItem)?.representedObject as? URL ?? creationDirectory else { return }
        let alert = NSAlert()
        alert.messageText = kind == .folder ? "New Folder" : (kind == .markdown ? "New Markdown" : "New File")
        alert.informativeText = "Create in \(directory.lastPathComponent)"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: kind == .folder ? "Untitled Folder" : "Untitled.md")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let url = try kind.create(named: field.stringValue, in: directory)
                self.refresh()
                self.reveal(url)
                if kind != .folder { self.onOpen?(url, false) }
            } catch {
                let errorAlert = NSAlert(error: error)
                errorAlert.beginSheetModal(for: window)
            }
        }
        field.selectText(nil)
        if kind != .folder, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).deletingPathExtension.utf16.count)
        }
    }

    private func select(_ url: URL) {
        for row in 0..<outline.numberOfRows {
            if (outline.item(atRow: row) as? FileNode)?.url.standardizedFileURL == url.standardizedFileURL {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }
    private func reveal(_ url: URL) {
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, node.isDirectory,
               url.standardizedFileURL.path.hasPrefix(node.url.standardizedFileURL.path + "/") || url.standardizedFileURL == node.url.standardizedFileURL {
                outline.expandItem(node)
            }
            row += 1
        }
        select(url)
        outline.scrollRowToVisible(outline.selectedRow)
    }
    private func updateRootActions() {
        guard let root, let cell = outline.view(atColumn: 0, row: outline.row(forItem: root), makeIfNecessary: false) as? SidebarFileCell else { return }
        cell.showsActions = !mediaMode && outline.isItemExpanded(root)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { updateRootActions() }
    func outlineViewItemDidCollapse(_ notification: Notification) { updateRootActions() }
    private func children(_ item: Any?) -> [FileNode] {
        guard let node = item as? FileNode else { return root.map { [$0] } ?? [] }
        return node.children.filter { !mediaMode || $0.isDirectory }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = SidebarFileCell()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : (FileKind.classify(node.url) == .image ? "photo" : "doc"), accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? (Theme.heading ?? Theme.foreground) : Theme.secondary
        let label = NSTextField(labelWithString: node.url.lastPathComponent)
        label.font = Theme.interfaceFont(size: 13.5)
        label.textColor = Theme.foreground.withAlphaComponent(0.85)
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(icon); cell.addSubview(label)
        icon.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = label; cell.imageView = icon; cell.toolTip = node.url.path
        cell.labelTrailing = label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        cell.labelTrailing?.isActive = true
        if node === root {
            cell.addActions(target: self, folderAction: #selector(newFolder(_:)), markdownAction: #selector(newMarkdown(_:)))
            cell.showsActions = !mediaMode && outline.isItemExpanded(node)
        }
        return cell
    }
    @objc private func clicked() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory && !mediaMode {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else { onOpen?(node.url, node.isDirectory) }
    }
}

/// Only this backdrop changes width. All interactive views use their final layout.
final class SidebarBackdrop: NSView {
    private let fill = CALayer()
    private let boundary = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.anchorPoint = .zero
        fill.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor
        boundary.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        fill.addSublayer(boundary)
        layer?.addSublayer(fill)
        autoresizingMask = [.height]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(expanded: Bool, width: CGFloat, height: CGFloat, animated: Bool) {
        let interruptedWidth = fill.animation(forKey: "reveal") != nil ? fill.presentation()?.frame.maxX : nil
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        let minimumWidth = width * 0.2
        let destination = expanded ? width : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Slide a full-width fill through the clip view. Its child boundary
        // travels with it, keeping a constant one-point stroke at the edge.
        fill.bounds = NSRect(x: 0, y: 0, width: width, height: height)
        fill.position = NSPoint(x: destination - width, y: 0)
        boundary.frame = NSRect(x: width - 1, y: 0, width: 1, height: height)
        CATransaction.commit()
        fill.removeAnimation(forKey: "reveal")
        isHidden = !expanded && !animated
        if animated {
            let reveal = CABasicAnimation(keyPath: "position.x")
            reveal.fromValue = (interruptedWidth ?? (expanded ? minimumWidth : width)) - width
            reveal.toValue = destination - width
            reveal.duration = SidebarTransition.duration
            reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(reveal, forKey: "reveal")
        }
    }
}

enum SidebarTransition {
    static let duration: TimeInterval = 0.13
    static func fadeIn(_ views: [NSView]) {
        for view in views where !view.isHidden {
            view.wantsLayer = true
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(fade, forKey: "sidebarFade")
        }
    }
}

private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        // Keep the same translucent tint when focus moves into the editor.
        Theme.sidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

private final class SidebarOutlineView: NSOutlineView {
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return contextMenu?()
    }
}

private final class SidebarScrollView: NSScrollView {
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
}

private final class SidebarFileCell: NSTableCellView {
    var labelTrailing: NSLayoutConstraint?
    private var actions: [SidebarIconButton] = []
    var showsActions = false {
        didSet {
            actions.forEach { $0.isHidden = !showsActions }
            labelTrailing?.constant = showsActions ? -54 : -4
        }
    }
    func addActions(target: AnyObject, folderAction: Selector, markdownAction: Selector) {
        for (symbol, label, action) in [("folder.badge.plus", "New Folder", folderAction), ("doc.badge.plus", "New Markdown", markdownAction)] {
            let button = SidebarIconButton()
            SidebarIconButton.configure(button, symbol: symbol, label: label, target: target, action: action)
            button.contentTintColor = Theme.secondary
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            actions.append(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 25), button.heightAnchor.constraint(equalToConstant: 25),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: actions.count == 1 ? -27 : -2),
            ])
        }
    }
}

final class SidebarDivider: NSView {
    var onResize: ((CGFloat) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    // This view is only the resize hit target; the backdrop owns the visible line.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onResize?(next.locationInWindow.x)
        }
    }
}
