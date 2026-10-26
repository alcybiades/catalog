import AppKit

/// A nonactivating child panel leaves typing and undo in the editor.
final class ReferencePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private var candidates: [(URL, String)] = []
    var onChoose: ((URL) -> Void)?
    var isVisible: Bool { panel.isVisible }
    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true; panel.backgroundColor = Theme.background
        panel.level = .popUpMenu
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference")))
        table.headerView = nil; table.rowHeight = 32; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(choose)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        scroll.documentView = table
        panel.contentView?.addSubview(scroll)
    }
    func show(_ candidates: [(URL, String)], below rect: NSRect, parent: NSWindow) {
        self.candidates = candidates
        table.reloadData()
        if !candidates.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let height = CGFloat(min(max(candidates.count, 1), 7)) * 32 + 8
        let screen = parent.screen?.visibleFrame ?? parent.frame
        let width = min(400, screen.width)
        let y = rect.minY - height < screen.minY ? rect.maxY : rect.minY - height
        panel.setFrame(NSRect(x: min(max(rect.minX, screen.minX), screen.maxX - width), y: y, width: width, height: height), display: true)
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func dismiss() { panel.orderOut(nil); panel.parent?.removeChildWindow(panel) }
    func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        let row = max(0, min(candidates.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc func choose() {
        guard candidates.indices.contains(table.selectedRow) else { return }
        let url = candidates[table.selectedRow].0
        dismiss(); onChoose?(url)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { max(1, candidates.count) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: candidates.isEmpty ? "No matching files" : candidates[row].1)
        label.font = Theme.interfaceFont(size: 12); label.textColor = candidates.isEmpty ? Theme.secondary : Theme.foreground
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
