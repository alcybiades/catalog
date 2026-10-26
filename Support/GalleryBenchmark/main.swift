import AppKit
precondition(AppState.isTesting, "Compile with -D CATALOG_TESTING before running the gallery benchmark")
_ = NSApplication.shared
NSApp.setActivationPolicy(.regular)
guard CommandLine.arguments.count == 2, !CommandLine.arguments[1].isEmpty else {
    print("Usage: make benchmark-gallery GALLERY=/path/to/folder")
    exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let controller = EditorWindowController(app: nil)
controller.window!.setFrame(NSRect(x: 100, y: 100, width: 1400, height: 920), display: true)
controller.showWindow(nil)
NSApp.activate(ignoringOtherApps: true)
controller.open(url: root)
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
let preview = controller.window!.contentView!.subviews.first { $0 is FilePreview } as! FilePreview
let scroll = preview.subviews.first { $0 is NSScrollView } as! NSScrollView
let collection = scroll.documentView as! NSCollectionView
// Read-only gallery traversal in a real AppKit event loop; no document edits.
let deadline = Date().addingTimeInterval(10)
while preview.sections.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
guard !preview.sections.isEmpty else {
    print("No gallery images found, or scanning did not finish in 10 seconds.")
    exit(1)
}
RunLoop.current.run(until: Date().addingTimeInterval(1))
print("sections \(preview.sections.count), images \(preview.sections.reduce(0) { $0 + $1.images.count }), height \(collection.bounds.height)")
fflush(stdout)
var intervals: [Double] = []
var work: [Double] = []
var frame = 0
var last = CACurrentMediaTime()
let maxY = max(0, collection.bounds.height - scroll.contentView.bounds.height)
let timer = Timer(timeInterval: 1.0/120, repeats: true) { timer in
    let start = CACurrentMediaTime()
    intervals.append(start-last); last = start
    let progress = CGFloat(frame % 240) / 239
    let y = (frame / 240) % 2 == 0 ? progress * maxY : (1-progress) * maxY
    scroll.contentView.scroll(to: NSPoint(x: 0,y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    controller.window!.displayIfNeeded()
    work.append(CACurrentMediaTime()-start)
    frame += 1
    if frame == 2400 {
        timer.invalidate()
        report("Main-thread timer interval (not display FPS)", intervals)
        report("Synchronous scroll/layout/display work", work)
        controller.window?.orderOut(nil)
        exit(0)
    }
}
RunLoop.current.add(timer, forMode: .common)

func report(_ name: String, _ values: [Double]) {
    let sorted = values.sorted()
    print(String(format:"%@: mean %.2fms p95 %.2fms p99 %.2fms max %.2fms >16.7ms %d/%d",name, values.reduce(0,+)/Double(values.count)*1000, sorted[Int(Double(sorted.count)*0.95)]*1000,sorted[Int(Double(sorted.count)*0.99)]*1000,sorted.last!*1000,values.filter{$0>1.0/60}.count,values.count))
}
NSApp.run()
