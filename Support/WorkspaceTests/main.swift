import AppKit

precondition(AppState.isTesting, "Compile with -D WRITE_TESTING before running workspace tests")
setbuf(stdout, nil)
_ = NSApplication.shared
var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("write-workspace-\(UUID().uuidString)")
let root = fixture.appendingPathComponent("Studio")
try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes/Nested"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: root.appendingPathComponent("Media"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixture) }
let source = root.appendingPathComponent("Notes/Start.md")
let target = root.appendingPathComponent("Notes/Nested/Design [v2] #1 (final).md")
let imageURL = root.appendingPathComponent("Media/Landscape.png")
let unknown = root.appendingPathComponent("archive.bin")
try "# Start\n\nOpen @ references to connect your notes.\n".write(to: source, atomically: true, encoding: .utf8)
try "# Design\n".write(to: target, atomically: true, encoding: .utf8)
try Data([0, 255, 20, 19]).write(to: unknown)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 320, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 640, height: 320).fill()
NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: NSRect(x: 120, y: 60, width: 240, height: 240)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
for n in 1...8 { try FileManager.default.copyItem(at: imageURL, to: root.appendingPathComponent("Media/Study \(n).png")) }

let characters = root.appendingPathComponent("Media/Characters")
let concepts = root.appendingPathComponent("Media/Characters/Concepts")
try FileManager.default.createDirectory(at: concepts, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: imageURL, to: characters.appendingPathComponent("Portrait.png"))
try FileManager.default.copyItem(at: imageURL, to: concepts.appendingPathComponent("Sketch.png"))
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Media/Loop"), withDestinationURL: root)
let groups = try MediaGallery.sections(in: root)
check("parent galleries include descendant images", groups.reduce(0) { $0 + $1.images.count } == 11)
check("gallery groups are sorted by containing directory", groups.map { FileReference.relativePath(to: $0.directory, from: root) } == ["Media", "Media/Characters", "Media/Characters/Concepts"])
check("breadcrumb ancestors reach workspace root", MediaGallery.breadcrumbs(to: concepts.appendingPathComponent("Sketch.png"), root: root).map(\.lastPathComponent) == ["Studio", "Media", "Characters", "Concepts", "Sketch.png"])
check("outside-workspace images use their actual parent", MediaGallery.breadcrumbs(to: source, root: characters).map(\.lastPathComponent) == ["Notes", "Start.md"])

let markdown = FileReference.markdown(to: target, from: source)
check("tag uses portable escaped Markdown", markdown == "[@Design \\[v2\\] #1 (final).md](Nested/Design%20%5Bv2%5D%20%231%20%28final%29.md)")
let match = MarkdownHighlighter.linkText.firstMatch(in: markdown, range: NSRange(location: 0, length: (markdown as NSString).length))!
let destination = (markdown as NSString).substring(with: match.range(at: 2))
check("encoded path round trips", FileReference.resolve(destination, from: source) == target)
check("sibling reference traverses parent", FileReference.markdown(to: imageURL, from: source) == "[@Landscape.png](../Media/Landscape.png)")
let movedSource = URL(fileURLWithPath: "/relocated/project/Notes/Start.md")
check("whole project relocation preserves target", FileReference.resolve(destination, from: movedSource)?.path == "/relocated/project/Notes/Nested/Design [v2] #1 (final).md")
check("no remote destinations opened as files", FileReference.resolve("https://example.com", from: source) == nil)
check("binary files unsupported", FileKind.classify(unknown) == .unsupported)
check("images classified", FileKind.classify(imageURL) == .image)
let storage = NSTextStorage(string: markdown)
MarkdownHighlighter().highlight(storage)
check("tag has clickable destination", storage.attribute(.fileReference, at: 2, effectiveRange: nil) as? String == destination)
check("tag is royal blue", (storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)?.isEqual(NSColor(hex: 0x4169E1)) == true)

let headingTag = NSTextStorage(string: "# " + markdown)
MarkdownHighlighter().highlight(headingTag)
check("tags in headings remain navigable", headingTag.attribute(.fileReference, at: 4, effectiveRange: nil) != nil)
let codeTag = NSTextStorage(string: "`" + markdown + "`")
MarkdownHighlighter().highlight(codeTag)
check("tag examples inside code stay literal", codeTag.attribute(.fileReference, at: 3, effectiveRange: nil) == nil)

// MARK: - Document links

let guide = root.appendingPathComponent("Notes/Field Guide.md")
try """
# Field Guide

Intro.

## Second Section

Body.
""".write(to: guide, atomically: true, encoding: .utf8)
try "# Shared\n".write(to: root.appendingPathComponent("Notes/Nested/Shared.md"), atomically: true, encoding: .utf8)
try "# Shared\n".write(to: root.appendingPathComponent("Media/Shared.md"), atomically: true, encoding: .utf8)
let links = root.appendingPathComponent("Notes/Links.md")
try """
# Links

[Guide](Field%20Guide.md), [[Field Guide]] and [[Field Guide|the guide]].
See [section](Field%20Guide.md#second-section) and [[Field Guide#Second Section]].
Jump to [top](#links), <https://example.com/a>, or https://example.com/b.
[[Nowhere]] is broken.
""".write(to: links, atomically: true, encoding: .utf8)

func linkedFile(_ destination: String, from origin: URL) -> (url: URL, anchor: String?)? {
    if case .file(let url, let anchor) = FileReference.target(destination, from: origin) { return (url, anchor) }
    return nil
}
check("relative Markdown destinations resolve against the linking file",
      linkedFile("Field%20Guide.md", from: links)?.url.path == guide.path)
check("unencoded spaces still resolve", linkedFile("Field Guide.md", from: links)?.url.path == guide.path)
check("parent-relative destinations resolve",
      linkedFile("../Media/Landscape.png", from: links)?.url.path == imageURL.path)
check("heading fragments are separated from the path",
      linkedFile("Field%20Guide.md#second-section", from: links)?.anchor == "second-section")
check("CommonMark titles are not part of the path",
      linkedFile("Field%20Guide.md \"The Guide\"", from: links)?.url.path == guide.path)
if case .anchor(let fragment) = FileReference.target("#links", from: links) {
    check("bare fragments stay in the current document", fragment == "links")
} else { check("bare fragments stay in the current document", false) }
if case .external(let web) = FileReference.target("https://example.com/a", from: links) {
    check("web destinations are external", web.absoluteString == "https://example.com/a")
} else { check("web destinations are external", false) }
if case .external = FileReference.target("mailto:someone@example.com", from: links) {
    check("mail destinations are external", true)
} else { check("mail destinations are external", false) }

let guideText = try String(contentsOf: guide, encoding: .utf8) as NSString
let slugAnchor = MarkdownHighlighter.headingRange(forAnchor: "second-section", in: guideText)
let textAnchor = MarkdownHighlighter.headingRange(forAnchor: "Second Section", in: guideText)
check("GitHub and Obsidian heading anchors find the same line",
      slugAnchor != nil && slugAnchor == textAnchor
      && guideText.substring(with: slugAnchor!).contains("## Second Section"))
check("unknown headings stay unresolved",
      MarkdownHighlighter.headingRange(forAnchor: "missing", in: guideText) == nil)

let indexed = Workspace(root: root)
let indexDeadline = Date().addingTimeInterval(5)
while indexed.files.isEmpty, Date() < indexDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
let nestedShared = root.appendingPathComponent("Notes/Nested/Shared.md")
// The workspace index reports enumerated URLs, which macOS resolves through
// /var → /private/var for temporary fixtures; compare the real files.
func sameFile(_ resolved: URL?, _ expected: URL) -> Bool {
    resolved?.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
}
check("wiki links resolve by note name", sameFile(indexed.resolveWikiLink("Field Guide", from: links), guide))
check("wiki links resolve case-insensitively", sameFile(indexed.resolveWikiLink("field guide", from: links), guide))
check("wiki links accept an explicit extension", sameFile(indexed.resolveWikiLink("Field Guide.md", from: links), guide))
check("wiki links accept relative paths", sameFile(indexed.resolveWikiLink("Nested/Shared", from: links), nestedShared))
check("ambiguous names prefer the note nearest the source",
      sameFile(indexed.resolveWikiLink("Shared", from: links), nestedShared))
check("heading fragments do not affect wiki resolution",
      sameFile(indexed.resolveWikiLink("Field Guide#Second Section", from: links), guide))
check("unknown notes stay unresolved", indexed.resolveWikiLink("Nowhere", from: links) == nil)
check("wiki links reach assets", sameFile(indexed.resolveWikiLink("Landscape.png", from: links), imageURL))
check("a unique note gets a bare wiki name", indexed.wikiName(for: guide) == "Field Guide")
check("an ambiguous note gets a workspace path",
      indexed.wikiName(for: root.appendingPathComponent("Media/Shared.md")) == "Media/Shared")
check("assets keep their extension in wiki names", indexed.wikiName(for: imageURL) == "Landscape.png")
check("wiki links work without a workspace",
      FileReference.resolveWikiSibling("Field Guide", from: links)?.path == guide.path)

let linkStorage = NSTextStorage(string: try String(contentsOf: links, encoding: .utf8))
let linkHighlighter = MarkdownHighlighter()
linkHighlighter.baseDirectory = links.deletingLastPathComponent()
linkHighlighter.resolveWikiLink = { indexed.resolveWikiLink($0, from: links) }
linkHighlighter.highlight(linkStorage)
func linkAttributes(_ key: NSAttributedString.Key) -> [String] {
    var values: [String] = []
    linkStorage.enumerateAttribute(key, in: NSRange(location: 0, length: linkStorage.length)) { value, _, _ in
        if let value = value as? String { values.append(value) }
    }
    return values
}
let destinations = linkAttributes(.fileReference)
check("plain Markdown links are clickable", destinations.contains("Field%20Guide.md"))
check("fragment links are clickable", destinations.contains("#links"))
check("angle-bracketed URLs are clickable", destinations.contains("https://example.com/a"))
check("bare URLs are clickable", destinations.contains("https://example.com/b"))
let wikiTargets = linkAttributes(.wikiReference)
check("wiki links are clickable", wikiTargets.contains("Field Guide"))
check("wiki fragments reach the click handler", wikiTargets.contains("Field Guide#Second Section"))
check("wiki links that name nothing are not clickable", !wikiTargets.contains("Nowhere"))
let aliasBar = (linkStorage.string as NSString).range(of: "|")
check("wiki aliases conceal their target",
      linkStorage.attribute(.mdMarker, at: aliasBar.location, effectiveRange: nil) != nil
      && linkStorage.attribute(.wikiReference, at: aliasBar.location + 1, effectiveRange: nil) as? String == "Field Guide")
let wikiInCode = NSTextStorage(string: "`[[Field Guide]]`")
MarkdownHighlighter().highlight(wikiInCode)
check("wiki examples inside code stay literal", wikiInCode.attribute(.wikiReference, at: 4, effectiveRange: nil) == nil)
let embed = NSTextStorage(string: "![[Landscape.png]]")
MarkdownHighlighter().highlight(embed)
check("image embeds are not treated as wiki links", embed.attribute(.wikiReference, at: 5, effectiveRange: nil) == nil)

let controller = EditorWindowController(app: nil)
controller.window?.setFrame(NSRect(x: 100, y: 100, width: 960, height: 720), display: true)
controller.showWindow(nil)
check("single-file starts without sidebar", controller.workspace == nil)
check("window uses the native frame with full-size content", controller.window!.styleMask.contains([.titled, .fullSizeContentView]))
check("backdrop has no competing rounded clip", controller.window!.contentView!.layer?.cornerRadius == 0)
if #available(macOS 26.0, *) {
    check("Tahoe uses the larger unified-toolbar window outline", controller.window!.toolbarStyle == .unified && controller.window!.toolbar?.isVisible == true)
}
check("native titlebar buttons stay hidden", [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].allSatisfy { controller.window!.standardWindowButton($0)?.isHidden == true })
check("open markdown", controller.open(url: source))
let count = controller.documents.count
check("open folder", controller.open(url: root))
check("folder appends tab and keeps existing file", controller.documents.count == count + 1 && controller.documents[0].url == source)
check("folder sets root", controller.workspace?.root.path == root.path)
check("folder tab is gallery", controller.currentDocument.kind == .folder)
check("open image", controller.open(url: imageURL, forceNewTab: true))
check("image is read only", !controller.textView.isEditable)
let bytes = try Data(contentsOf: imageURL)
controller.saveDocument(nil); controller.saveDocumentAs(nil)
check("save cannot overwrite image", try Data(contentsOf: imageURL) == bytes)
check("open unknown", controller.open(url: unknown, forceNewTab: true))
check("unsupported is read only", controller.currentDocument.kind == .unsupported && !controller.textView.isEditable)
controller.saveDocument(nil)
check("save cannot overwrite binary", try Data(contentsOf: unknown) == Data([0, 255, 20, 19]))
check("replace root", controller.open(url: root.appendingPathComponent("Media")))
check("one active workspace replaced", controller.workspace?.root == root.appendingPathComponent("Media"))
check("old folder tab survives", controller.documents.contains { $0.url?.path == root.path })
controller.switchTab(to: 0)
check("markdown editor restored", controller.textView.isEditable && controller.textView.string.contains("# Start"))
controller.textView.insertText("extra", replacementRange: NSRange(location: controller.textView.string.utf16.count, length: 0))
controller.open(url: imageURL, forceNewTab: true)
check("markdown flushes before image tab", try String(contentsOf: source, encoding: .utf8).hasSuffix("extra"))

func snapshot(_ name: String) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    guard let view = controller.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/write-\(name).png"))
}
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
controller.open(url: root.appendingPathComponent("Media"))
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
snapshot("gallery")
let preview = controller.window!.contentView!.subviews.first { $0 is FilePreview } as! FilePreview
check("gallery loads multiple collection sections", preview.sections.count == 3)
let galleryScroll = preview.subviews.first { $0 is NSScrollView } as! NSScrollView
let groupedCollection = galleryScroll.documentView as! NSCollectionView
groupedCollection.scrollToItems(at: Set([IndexPath(item: 0, section: 1)]), scrollPosition: .top)
snapshot("gallery-grouped")
// Vertical wheel events over a path header must keep scrolling the gallery.
let headerScroll = galleryDescendants(groupedCollection).compactMap { $0 as? NSScrollView }.first!
func galleryDescendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + galleryDescendants($0) } }
galleryScroll.contentView.scroll(to: .zero)
let headerWheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -80, wheel2: 0, wheel3: 0)!
headerScroll.scrollWheel(with: NSEvent(cgEvent: headerWheel)!)
// The gallery scrolls on the legacy (non-responsive) path, where wheel deltas
// apply via NSScrollingAnimator on a later display-link tick, not synchronously.
let wheelDeadline = Date().addingTimeInterval(1)
while galleryScroll.contentView.bounds.minY <= 0, Date() < wheelDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
check("wheel over breadcrumbs scrolls parent gallery", galleryScroll.contentView.bounds.minY > 0)
var galleryPosition = galleryScroll.contentView.bounds.origin
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
let bar = controller.window!.contentView!.subviews.first { $0 is TabBarView }!
let strip = bar.subviews.first { $0 is NSScrollView } as! NSScrollView
let sidebarPane = controller.window!.contentView!.subviews.first { $0 is FolderSidebar }!
let control = descendants(sidebarPane).compactMap { $0 as? NSButton }.first { $0.toolTip == "Collapse sidebar" }!
func headerButtonReceivesClicks(_ button: NSButton) -> Bool {
    let frameView = controller.window!.contentView!.superview!
    let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView)
    let hit = frameView.hitTest(center)
    return hit === button || hit?.isDescendant(of: button) == true
}
for label in ["Collapse sidebar", "Files", "Media"] {
    let button = descendants(sidebarPane).compactMap { $0 as? NSButton }.first { $0.toolTip == label }!
    check("\(label) receives window hit tests", headerButtonReceivesClicks(button))
}
let tab = descendants(strip).first { String(describing: type(of: $0)) == "TabItemView" }!
check("sidebar controls align to tab centers", abs(control.convert(control.bounds, to: bar).midY - tab.convert(tab.bounds, to: bar).midY) < 0.5)
check("tab viewport reaches window edge", abs(strip.frame.maxX - bar.bounds.width) < 0.5)
controller.window?.setContentSize(NSSize(width: 640, height: 720))
controller.window?.contentView?.layoutSubtreeIfNeeded()
controller.switchTab(to: controller.current)
check("tabs overflow in a scrollable document", strip.documentView!.frame.width > strip.contentView.bounds.width)
let lastTab = descendants(strip).filter { String(describing: type(of: $0)) == "TabItemView" }.last!
check("selected last tab remains fully visible", strip.documentVisibleRect.contains(lastTab.frame))
// Wheel scrolling must remain available without an AppKit scroller to flash.
check("tab strip never creates scroll indicators", !strip.hasHorizontalScroller && !strip.hasVerticalScroller && strip.horizontalScroller == nil && strip.verticalScroller == nil)
strip.contentView.scroll(to: .zero)
let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -80, wheel3: 0)!
strip.scrollWheel(with: NSEvent(cgEvent: wheel)!)
check("horizontal wheel input scrolls tabs without indicators", strip.contentView.bounds.minX > 0)
strip.contentView.scroll(to: .zero)
let verticalWheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!
strip.scrollWheel(with: NSEvent(cgEvent: verticalWheel)!)
check("ordinary mouse wheel can scroll tab strip", strip.contentView.bounds.minX > 0)

let tabBar = bar as! TabBarView
let tabItems = descendants(strip).filter { String(describing: type(of: $0)) == "TabItemView" }
let pointer = strip.convert(NSPoint(x: 40, y: strip.bounds.midY), to: nil)
let outside = NSPoint(x: -1000, y: -1000)
var hoverTracksScroll = true
let maxOffset = max(0, strip.documentView!.frame.width - strip.contentView.bounds.width)
for offset in stride(from: CGFloat(0), through: maxOffset, by: 12) {
    strip.contentView.scroll(to: NSPoint(x: offset, y: 0))
    // Repeated geometry updates model a stationary pointer during scrolling.
    for _ in 0..<3 { tabBar.updateHover(at: pointer) }
    for item in tabItems {
        let expected = item.bounds.contains(item.convert(pointer, from: nil))
        let close = item.subviews.first { $0 is HoverCloseButton }!
        let frozenWidths = item.constraints.filter { $0.isActive && $0.firstAttribute == .width && $0.relation == .equal }
        hoverTracksScroll = hoverTracksScroll && (close.isHidden == !expected) && frozenWidths.count == (expected ? 1 : 0)
    }
}
check("scrolling beneath pointer leaves only current tab hovered", hoverTracksScroll)
tabBar.updateHover(at: outside)
check("leaving strip clears every close button and frozen width", tabItems.allSatisfy { item in
    item.subviews.filter { $0 is HoverCloseButton }.allSatisfy(\.isHidden) &&
    !item.constraints.contains { $0.isActive && $0.firstAttribute == .width && $0.relation == .equal }
})
lastTab.scrollToVisible(lastTab.bounds)
snapshot("tabs-overflow")
controller.window?.setContentSize(NSSize(width: 960, height: 720))
controller.window?.contentView?.layoutSubtreeIfNeeded()

galleryPosition = galleryScroll.contentView.bounds.origin
controller.open(url: imageURL, forceNewTab: true)
snapshot("image")
let imageCrumbs = preview.subviews.first { $0 is BreadcrumbBar } as! BreadcrumbBar
check("media images show breadcrumbs", !imageCrumbs.isHidden)
let mediaCrumb = descendants(imageCrumbs).compactMap { $0 as? NSButton }.first { $0.title == "Media" }!
let beforeBack = controller.documents.count
mediaCrumb.performClick(nil)
check("breadcrumb returns to existing gallery tab", controller.currentDocument.kind == .folder && controller.currentDocument.url?.path == root.appendingPathComponent("Media").path && controller.documents.count == beforeBack)
check("breadcrumb navigation preserves workspace", controller.workspace?.root.path == root.path)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
check("back to gallery restores scroll position", abs(galleryScroll.contentView.bounds.origin.y - galleryPosition.y) < 1)
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
controller.open(url: imageURL, forceNewTab: true)
check("Files image view has no heading or breadcrumb", imageCrumbs.isHidden)
snapshot("image-files")

controller.restoreWorkspace(root: root, collapsed: true, width: 220, media: false)
controller.switchTab(to: 0)
snapshot("collapsed")
check("collapsed body uses full width", abs(controller.textView.enclosingScrollView!.frame.minX) < 0.5)
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
controller.window?.contentView?.layoutSubtreeIfNeeded()
let sidebarView = controller.window!.contentView!.subviews.first { $0 is FolderSidebar }!
check("expanded sidebar has saved width", sidebarView.frame.width == 220)
let deadline = Date().addingTimeInterval(3)
while controller.workspace?.files.isEmpty == true && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
check("workspace indexes nested and arbitrary files", controller.workspace?.files.contains { $0.standardizedFileURL.path == target.standardizedFileURL.path } == true && controller.workspace?.files.contains { $0.standardizedFileURL.path == unknown.standardizedFileURL.path } == true)
controller.textView.setSelectedRange(NSRange(location: controller.textView.string.utf16.count, length: 0))
controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
controller.textView.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
func key(_ text: String, _ code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: controller.window!.windowNumber, context: nil,
                                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    controller.textView.keyDown(with: event)
}
key("Design", 0)
key("\r", 36)
check("@ picker inserts chosen relative Markdown", controller.textView.string.hasSuffix(markdown))
snapshot("references")
let referenceIndex = (controller.textView.string as NSString).range(of: "@Design").location
if referenceIndex != NSNotFound, let lm = controller.textView.layoutManager, let tc = controller.textView.textContainer {
    lm.ensureLayout(for: tc)
    let glyph = lm.glyphIndexForCharacter(at: referenceIndex)
    let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
    let origin = controller.textView.textContainerOrigin
    let point = controller.textView.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    controller.textView.mouseDown(with: click)
    check("clicking tag opens its target tab", controller.currentDocument.url == target)
}
controller.closeFolder(nil)
check("close folder keeps tabs and disables sidebar", controller.workspace == nil && controller.documents.count > 1 && !controller.textView.referencesEnabled)
let restored = EditorWindowController(app: nil)
restored.restoreTab(url: root)
restored.restoreTab(url: imageURL)
restored.restoreWorkspace(root: root.appendingPathComponent("Media"), collapsed: true, width: 270, media: true)
check("restored folder tabs don't replace root", restored.workspace?.root == root.appendingPathComponent("Media") && restored.documents.count == 2)
check("sidebar preferences restore", restored.sidebarCollapsed && restored.sidebarWidth == 270 && restored.mediaMode)
check("persist preview tabs safely", restored.persistAllDrafts())
// A large folder should create work for the viewport, not for every image.
let manyImages = fixture.appendingPathComponent("Many images")
try FileManager.default.createDirectory(at: manyImages, withIntermediateDirectories: true)
for index in 0..<500 {
    try FileManager.default.copyItem(at: imageURL, to: manyImages.appendingPathComponent("Image \(index).png"))
}
let beforeDecodes = ImageLoader.shared.statistics.thumbnailDecodes
let beforeGallery = Date()
controller.open(url: manyImages)
let galleryDeadline = Date().addingTimeInterval(10)
while preview.sections.first?.images.count != 500 && Date() < galleryDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
let visible = groupedCollection.visibleItems()
let newDecodes = ImageLoader.shared.statistics.thumbnailDecodes - beforeDecodes
let visibleThumbnails = visible.flatMap { galleryDescendants($0.view).compactMap { $0 as? GalleryThumbnailView } }
check("visible thumbnails have composited pixels", !visibleThumbnails.isEmpty && visibleThumbnails.allSatisfy { $0.image != nil && $0.layer?.contents != nil })
check("thumbnail presentation preserves aspect ratio", visibleThumbnails.allSatisfy { $0.layer?.contentsGravity == .resizeAspect })
check("thumbnail filenames remain accessible", visibleThumbnails.allSatisfy { $0.accessibilityLabel()?.hasPrefix("Image ") == true })
check("large gallery indexes all images", preview.sections.first?.images.count == 500)
check("large gallery only decodes visible cells", !visible.isEmpty && visible.count < 40 && newDecodes <= visible.count + 4)
check("large gallery pending work is bounded by viewport", ImageLoader.shared.pendingThumbnailCount <= visible.count)
print(String(format: "GALLERY: 500 files, %d visible cells, %d thumbnail decodes, %.3fs including 0.3s settle", visible.count, newDecodes, Date().timeIntervalSince(beforeGallery)))
groupedCollection.scrollToItems(at: Set([IndexPath(item: 499, section: 0)]), scrollPosition: .bottom)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
let nowVisible = groupedCollection.visibleItems()
check("offscreen gallery cells release decoded pixels", visible.filter { old in !nowVisible.contains { $0 === old } }.allSatisfy { old in
    galleryDescendants(old.view).compactMap { $0 as? GalleryThumbnailView }.allSatisfy { $0.image == nil && $0.layer?.contents == nil }
})
controller.open(url: imageURL, forceNewTab: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.15))
let originalImageView = preview.subviews.first { $0 is NSImageView } as! NSImageView
check("full viewer loads original separately", originalImageView.image != nil)
controller.switchTab(to: 0)
check("leaving viewer releases original pixels", originalImageView.image == nil && preview.sections.isEmpty)
check("leaving gallery cancels pending thumbnails", ImageLoader.shared.pendingThumbnailCount == 0)
// Sidebar clicks navigate in a tab belonging to the displayed workspace.
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
let freshA = root.appendingPathComponent("Notes/FreshA.md")
let freshB = root.appendingPathComponent("Notes/FreshB.md")
try "# A\n".write(to: freshA, atomically: true, encoding: .utf8)
try "# B\n".write(to: freshB, atomically: true, encoding: .utf8)
let tabsBefore = controller.documents.count
controller.openInCurrentTab(imageURL)
check("sidebar open focuses an existing tab", controller.documents.count == tabsBefore && controller.currentDocument.url == imageURL.standardizedFileURL)
controller.switchTab(to: controller.documents.firstIndex { $0.url == source }!)
controller.textView.insertText("draft in progress ", replacementRange: NSRange(location: 0, length: 0))
controller.openInCurrentTab(freshA)
let flushedSource = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
check("sidebar open replaces the current tab and flushes its edits",
      controller.documents.count == tabsBefore && controller.currentDocument.url == freshA
      && !controller.documents.contains { $0.url == source } && flushedSource.hasPrefix("draft in progress"))
controller.newTab(nil)
controller.textView.insertText("scratch", replacementRange: NSRange(location: 0, length: 0))
let untitledTabs = controller.documents.count
controller.openInCurrentTab(freshB)
check("sidebar open keeps untitled buffers in their tab",
      controller.documents.count == untitledTabs && controller.currentDocument.url == freshB
      && controller.documents.contains { $0.url == nil && $0.storage.string == "scratch" })

// Activation order, rather than tab position, determines which workspace tab
// to reuse while an unrelated document is selected.
let outsideRoot = fixture.appendingPathComponent("Studio-Archive")
try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
let outsideURL = outsideRoot.appendingPathComponent("Outside.md")
try "Outside note".write(to: outsideURL, atomically: true, encoding: .utf8)
let outsideDocument = Document(url: outsideURL, content: "Outside note")
let navigation = EditorWindowController(documents: [outsideDocument,
    Document(url: freshA, content: "# A\n"), Document(url: freshB, content: "# B\n")], app: nil)
navigation.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
navigation.switchTab(to: 2)
navigation.switchTab(to: 1)
navigation.switchTab(to: 0)
navigation.textView.insertText("Edited ", replacementRange: NSRange(location: 0, length: 0))
navigation.openInCurrentTab(target)
check("sidebar reuses most recently active associated tab, not last tab",
      navigation.current == 1 && navigation.documents.count == 3
      && navigation.currentDocument.url == target && navigation.documents[2].url == freshB)
check("sidebar preserves unrelated file and saves its pending edits",
      navigation.documents[0] === outsideDocument && outsideDocument.storage.string == "Edited Outside note"
      && (try? String(contentsOf: outsideURL, encoding: .utf8)) == "Edited Outside note")
navigation.switchTab(to: 0)
navigation.openInCurrentTab(freshB)
check("already open destination takes priority over most recent workspace tab",
      navigation.current == 2 && navigation.documents.count == 3 && navigation.documents[1].url == target)
navigation.switchTab(to: 0)
navigation.closeTab(at: 2)
navigation.openInCurrentTab(freshA)
check("closed most recent tab falls back to previous associated tab",
      navigation.current == 1 && navigation.documents.count == 2 && navigation.currentDocument.url == freshA)
_ = navigation.removeDocument(at: 1)
navigation.openInCurrentTab(freshB)
check("no associated tab creates one without replacing similarly named sibling folder file",
      navigation.documents.count == 2 && navigation.documents[0] === outsideDocument
      && navigation.currentDocument.url == freshB)
navigation.newTab(nil)
let blankDocument = navigation.currentDocument
navigation.openInCurrentTab(imageURL)
check("blank unrelated tab stays open while associated tab shows an image",
      navigation.documents.count == 3 && navigation.documents[2] === blankDocument
      && navigation.current == 1 && navigation.currentDocument.kind == .image)
navigation.restoreWorkspace(root: root, collapsed: false, width: 220, media: true)
navigation.switchTab(to: 0)
navigation.openInCurrentTab(root)
check("media folder navigation reuses associated tab and preserves sidebar root",
      navigation.current == 1 && navigation.currentDocument.url?.path == root.path
      && navigation.documents[0] === outsideDocument && navigation.workspace?.root.path == root.path)
navigation.restoreWorkspace(root: outsideRoot, collapsed: false, width: 220, media: false)
navigation.openInCurrentTab(outsideURL)
navigation.switchTab(to: 1)
let anotherOutside = outsideRoot.appendingPathComponent("Another.md")
try "Another note".write(to: anotherOutside, atomically: true, encoding: .utf8)
navigation.openInCurrentTab(anotherOutside)
check("changing sidebar root re-evaluates which tabs belong to it",
      navigation.current == 0 && navigation.currentDocument.url == anotherOutside
      && navigation.documents[1].url?.path == root.path)
navigation.window?.orderOut(nil)

// Creation controls follow the selected directory and survive tree refreshes.
controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
controller.window?.contentView?.layoutSubtreeIfNeeded()
let creationSidebar = sidebarPane as! FolderSidebar
let tree = descendants(creationSidebar).compactMap { $0 as? NSOutlineView }.first!
func treeNode(_ url: URL) -> FileNode? {
    (0..<tree.numberOfRows).compactMap { tree.item(atRow: $0) as? FileNode }.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }
}
func rootActions() -> [NSButton] {
    guard let cell = tree.view(atColumn: 0, row: 0, makeIfNecessary: true) else { return [] }
    return descendants(cell).compactMap { $0 as? NSButton }
}
check("expanded Files root has two creation icons", rootActions().count == 2 && rootActions().allSatisfy { !$0.isHidden })
tree.collapseItem(tree.item(atRow: 0))
check("collapsed root hides creation icons", rootActions().allSatisfy(\.isHidden))
creationSidebar.refresh()
check("refresh preserves collapsed root", !tree.isItemExpanded(tree.item(atRow: 0)))
tree.expandItem(tree.item(atRow: 0))
let notes = root.appendingPathComponent("Notes")
tree.expandItem(treeNode(notes))
tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: treeNode(notes))), byExtendingSelection: false)
check("selected folder is creation destination", creationSidebar.creationDirectory?.standardizedFileURL.path == notes.standardizedFileURL.path)
creationSidebar.refresh()
check("refresh preserves selected directory", creationSidebar.creationDirectory?.standardizedFileURL.path == notes.standardizedFileURL.path)
func settleSheet() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
func createFromButton(_ label: String, name: String, cancel: Bool = false) {
    rootActions().first { $0.toolTip == label }!.performClick(nil)
    guard let sheet = controller.window?.attachedSheet,
          let field = descendants(sheet.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else {
        check("creation presents naming sheet", false); return
    }
    field.stringValue = name
    controller.window?.endSheet(sheet, returnCode: cancel ? .alertSecondButtonReturn : .alertFirstButtonReturn)
    settleSheet()
}
createFromButton("New Folder", name: "Created Folder")
let createdFolder = notes.appendingPathComponent("Created Folder")
check("folder icon creates inside selected folder and selects result", FileKind.classify(createdFolder) == .folder && creationSidebar.creationDirectory?.standardizedFileURL.path == createdFolder.standardizedFileURL.path)
createFromButton("New Markdown", name: "First note")
let createdNote = createdFolder.appendingPathComponent("First note.md")
check("markdown icon adds extension and opens new file", FileManager.default.fileExists(atPath: createdNote.path) && controller.currentDocument.url?.standardizedFileURL.path == createdNote.standardizedFileURL.path)
check("selected file targets its parent", creationSidebar.creationDirectory?.standardizedFileURL.path == createdFolder.standardizedFileURL.path)
createFromButton("New Markdown", name: "Cancelled", cancel: true)
check("cancel creates nothing", !FileManager.default.fileExists(atPath: createdFolder.appendingPathComponent("Cancelled.md").path))
let contextPoint = tree.convert(NSPoint(x: 60, y: tree.rect(ofRow: tree.row(forItem: treeNode(notes))).midY), to: nil)
let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: contextPoint, modifierFlags: [], timestamp: 0,
    windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
let creationMenu = tree.menu(for: contextEvent)!
check("right click targets clicked directory", creationSidebar.creationDirectory?.standardizedFileURL.path == notes.standardizedFileURL.path && (creationMenu.items.first?.representedObject as? URL)?.standardizedFileURL.path == notes.standardizedFileURL.path)
check("Files context menu offers file and folder creation", creationMenu.items.contains { $0.title == "New File…" } && creationMenu.items.contains { $0.title == "New Folder…" })
creationSidebar.mediaMode = true
check("Media mode hides creation actions", rootActions().allSatisfy(\.isHidden) && tree.menu(for: contextEvent)?.items.count == 1)
creationSidebar.mediaMode = false
tree.collapseItem(tree.item(atRow: 0))
tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
let rootContextPoint = tree.convert(NSPoint(x: 60, y: tree.rect(ofRow: 0).midY), to: nil)
let rootContextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: rootContextPoint, modifierFlags: [], timestamp: 0,
    windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
let rootMenu = tree.menu(for: rootContextEvent)!
let newFileItem = rootMenu.items.first { $0.title == "New File…" }!
NSApp.sendAction(newFileItem.action!, to: newFileItem.target, from: newFileItem)
if let sheet = controller.window?.attachedSheet,
   let field = descendants(sheet.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
    field.stringValue = "From context.md"
    controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    settleSheet()
}
check("context creation expands a collapsed root and reveals the file", tree.isItemExpanded(tree.item(atRow: 0)) && (tree.item(atRow: tree.selectedRow) as? FileNode)?.url.lastPathComponent == "From context.md")
let arbitrary = try WorkspaceItemKind.file.create(named: "data.json", in: createdFolder)
check("new file preserves arbitrary extension", arbitrary.lastPathComponent == "data.json")
try "keep me".write(to: arbitrary, atomically: true, encoding: .utf8)
do { _ = try WorkspaceItemKind.file.create(named: "data.json", in: createdFolder); check("duplicate file rejected", false) }
catch { check("duplicate file preserves contents", try String(contentsOf: arbitrary, encoding: .utf8) == "keep me") }
do { _ = try WorkspaceItemKind.folder.create(named: "Created Folder", in: notes); check("duplicate folder rejected", false) }
catch { check("duplicate folder preserves contents", FileManager.default.fileExists(atPath: createdNote.path)) }
for invalid in ["", " ", ".", "..", "../escape", "a/b", "a:b", ".hidden"] {
    do { _ = try WorkspaceItemKind.markdown.create(named: invalid, in: notes); check("invalid name rejected: \(invalid)", false) }
    catch { }
}
snapshot("sidebar-creation")
let expandedWidth = creationSidebar.frame.width
control.performClick(nil)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    let backdrop = controller.window!.contentView!.subviews.first { $0 is SidebarBackdrop }!
    let presentedWidth = backdrop.layer?.sublayers?.first?.presentation()?.frame.maxX ?? 0
    check("only backdrop width passes through intermediate frames", presentedWidth > 0 && presentedWidth < expandedWidth)
    check("editor is already at collapsed destination", abs(controller.textView.enclosingScrollView!.frame.minX) < 0.5)
    check("toggle never fades", descendants(bar).compactMap { $0 as? NSButton }.first { $0.toolTip == "Expand sidebar" }?.layer?.animation(forKey: "sidebarFade") == nil)
}
settleSheet()
check("animated collapse hides sidebar and releases editor width", creationSidebar.isHidden && abs(controller.textView.enclosingScrollView!.frame.minX) < 0.5)
let expandControl = descendants(bar).compactMap { $0 as? NSButton }.first { $0.toolTip == "Expand sidebar" }!
check("collapsed sidebar toggle receives window hit tests", headerButtonReceivesClicks(expandControl))
expandControl.performClick(nil)
check("expansion places sidebar at its final width immediately", abs(creationSidebar.frame.width - expandedWidth) < 0.5)
settleSheet()
check("animated expansion restores sidebar width", !creationSidebar.isHidden && abs(creationSidebar.frame.width - expandedWidth) < 0.5)
for label in ["Files", "Media"] {
    let button = descendants(creationSidebar).compactMap { $0 as? NSButton }.first { $0.toolTip == label }!
    check("\(label) receives clicks after expanding", headerButtonReceivesClicks(button))
    button.performClick(nil)
    check("\(label) switches sidebar mode", controller.mediaMode == (label == "Media"))
}
control.performClick(nil)
expandControl.performClick(nil)
settleSheet()
check("rapid sidebar toggles settle expanded", !controller.sidebarCollapsed && !creationSidebar.isHidden && abs(creationSidebar.frame.width - expandedWidth) < 0.5)

// MARK: - Following links from the editor

controller.restoreWorkspace(root: root, collapsed: false, width: 220, media: false)
check("open the link fixture", controller.open(url: links, forceNewTab: true))
let editor: EditorTextView = controller.textView
editor.layoutManager?.ensureLayout(for: editor.textContainer!)
func clickPoint(for range: NSRange) -> NSPoint {
    let layout = editor.layoutManager!, container = editor.textContainer!
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    rect.origin.x += editor.textContainerOrigin.x
    rect.origin.y += editor.textContainerOrigin.y
    return editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
}
func click(_ needle: String, modifiers: NSEvent.ModifierFlags = []) {
    let range = (editor.string as NSString).range(of: needle)
    guard range.location != NSNotFound,
          let event = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint(for: range),
                                         modifierFlags: modifiers, timestamp: 0,
                                         windowNumber: controller.window!.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1) else { return }
    editor.mouseDown(with: event)
}
click("the guide")
check("clicking a wiki alias opens its note", sameFile(controller.currentDocument.url, guide))
controller.open(url: links, forceNewTab: true)
click("Guide")
check("clicking a Markdown link opens the file", sameFile(controller.currentDocument.url, guide))
controller.open(url: links, forceNewTab: true)
click("section")
let sectionHeading = (controller.textView.string as NSString).range(of: "## Second Section")
check("a link fragment scrolls the opened note to its heading",
      sameFile(controller.currentDocument.url, guide)
      && controller.textView.selectedRange().location == sectionHeading.location)
controller.open(url: links, forceNewTab: true)
editor.setSelectedRange(NSRange(location: 0, length: 0))
click("top")
check("a bare fragment scrolls within the current document",
      sameFile(controller.currentDocument.url, links)
      && editor.selectedRange().location == (editor.string as NSString).range(of: "# Links").location)
// Option-click falls through to NSTextView's own drag tracking, which blocks
// on a real mouse-up — assert the guard rather than entering that loop.
let optionEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: .option,
                                     timestamp: 0, windowNumber: controller.window!.windowNumber,
                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
check("option-click is excluded from link following", optionEvent.modifierFlags.contains(.option))
// Typing "[[" opens the same picker as "@"; choosing inserts wiki syntax.
controller.open(url: links, forceNewTab: true)
let namesDeadline = Date().addingTimeInterval(5)
while controller.workspace?.files.isEmpty != false, Date() < namesDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
let end = NSRange(location: (editor.string as NSString).length, length: 0)
editor.setSelectedRange(end)
editor.insertText("\n", replacementRange: end)
editor.insertText("[", replacementRange: editor.selectedRange())
editor.insertText("[", replacementRange: editor.selectedRange())
check("typing [[ leaves the source untouched", editor.string.hasSuffix("\n[["))
editor.onInsertReference?(guide, NSRange(location: (editor.string as NSString).length - 2, length: 2), .wiki)
check("choosing a file inserts the shortest unambiguous wiki name",
      editor.string.hasSuffix("[[Field Guide]]"))
editor.onInsertReference?(imageURL, NSRange(location: (editor.string as NSString).length, length: 0), .wiki)
check("wiki links to assets keep their extension", editor.string.hasSuffix("[[Landscape.png]]"))

let brokenRange = (editor.string as NSString).range(of: "Nowhere")
check("broken wiki links carry no click target",
      editor.textStorage?.attribute(.wikiReference, at: brokenRange.location, effectiveRange: nil) == nil)

// Leave an unsaved buffer behind, as a crash would. It must stay in test state.
let scratch = controller.documents.first { $0.url == nil && $0.storage.string == "scratch" }!
check("test draft persists", RecoveryStore.write(scratch))
check("test draft can be recovered in its own profile", RecoveryStore.loadAll().contains { $0.id == scratch.recoveryID })
let realRecovery = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Write/Recovery")
check("test recovery directory is isolated", RecoveryStore.directory != realRecovery)
check("test draft never reaches user recovery", !FileManager.default.fileExists(atPath:
    realRecovery.appendingPathComponent(scratch.recoveryID.uuidString + ".json").path))
let realRecents = UserDefaults.standard.stringArray(forKey: "recentFiles")
let realSession = UserDefaults.standard.array(forKey: "sessionWindows") as NSArray?
check("test profile starts without recents or session", AppState.defaults.object(forKey: "recentFiles") == nil
      && AppState.defaults.object(forKey: "sessionWindows") == nil)
MainActor.assumeIsolated {
    let testApp = AppDelegate()
    testApp.addRecentFile(source)
    testApp.sessionChanged()
}
check("test recents are recorded in test profile", AppState.defaults.stringArray(forKey: "recentFiles") == [source.path])
check("test session is recorded in test profile", AppState.defaults.array(forKey: "sessionWindows") != nil)
check("test recents leave user preferences intact", UserDefaults.standard.stringArray(forKey: "recentFiles") == realRecents)
check("test session leaves user preferences intact", UserDefaults.standard.array(forKey: "sessionWindows") as NSArray? == realSession)
// Pages: home placeholder, Wikipedia tabs, note outline, and the assistant's
// file tools with live reload of open notes.
func awaitTask<T>(_ work: @escaping () async -> T) -> T {
    var result: T?
    Task { @MainActor in result = await work() }
    let deadline = Date().addingTimeInterval(5)
    while result == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return result!
}
MainActor.assumeIsolated {
    let agentRoot = fixture.appendingPathComponent("AgentRoot")
    try? FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: true)
    let note = agentRoot.appendingPathComponent("Note.md")
    try? "# Title\n\nalpha beta\n\n## Second\n".write(to: note, atomically: true, encoding: .utf8)

    let pages = EditorWindowController(documents: [Document(wiki: WikiPage(style: .home))], app: nil)
    check("home tab is a placeholder", pages.currentDocument.kind == .wiki && pages.currentDocument.isPlaceholder)
    pages.open(url: note)
    check("opening a file replaces the home tab", pages.documents.count == 1 && pages.currentDocument.url?.standardizedFileURL == note.standardizedFileURL)
    pages.newWikiTab(nil)
    check("new Wikipedia tab", pages.documents.count == 2 && pages.currentDocument.kind == .wiki && pages.currentDocument.name == "Wikipedia")
    check("Wikipedia tab is not a placeholder", !pages.currentDocument.isPlaceholder)
    pages.switchTab(to: 0)

    let outline = MarkdownHighlighter.outline(of: "# One **bold**\n```\n# not\n```\n### [Three](x.md)\n" as NSString)
    check("note outline lists headings outside code", outline.map(\.title) == ["One bold", "Three"] && outline.map(\.level) == [1, 3])

    var opened: [URL] = []
    let tools = AgentTools(root: agentRoot, openFile: nil) { opened.append($0) }
    check("agent paths stay inside the working directory", (try? tools.resolve("../Studio/Guide.md")) == nil && (try? tools.resolve("/etc/hosts")) == nil)
    check("agent paths resolve relative to the working directory", (try? tools.resolve("Sub/New.md"))?.path == agentRoot.appendingPathComponent("Sub/New.md").path)

    let created = awaitTask { await tools.run("write_file", input: ["path": "Sub/New.md", "content": "hello"]) }
    check("agent creates nested files", !created.isError && (try? String(contentsOf: agentRoot.appendingPathComponent("Sub/New.md"), encoding: .utf8)) == "hello")

    pages.textView.setSelectedRange(NSRange(location: 0, length: 0))
    pages.textView.insertText("Draft ", replacementRange: NSRange(location: 0, length: 0))
    let edited = awaitTask { await tools.run("edit_file", input: ["path": "Note.md", "old_text": "alpha", "new_text": "gamma"]) }
    check("agent edit succeeds", !edited.isError)
    check("unsaved edits are saved before the agent edits", (try? String(contentsOf: note, encoding: .utf8))?.hasPrefix("Draft # Title") == true)
    check("open note reloads with the agent's edit", pages.currentDocument.storage.string.contains("gamma beta") && !pages.currentDocument.edited)
    pages.currentDocument.undoManager.undo()
    check("agent edit is undoable in the editor", pages.currentDocument.storage.string.contains("alpha beta"))

    let ambiguous = awaitTask { await tools.run("edit_file", input: ["path": "Note.md", "old_text": "#", "new_text": "*"]) }
    check("ambiguous agent edit is refused", ambiguous.isError)
    let missing = awaitTask { await tools.run("edit_file", input: ["path": "Note.md", "old_text": "zzz", "new_text": "y"]) }
    check("agent edit of missing text is refused", missing.isError)
    let moved = awaitTask { await tools.run("move_file", input: ["from": "Note.md", "to": "Renamed.md"]) }
    check("open tab follows an agent move", !moved.isError && pages.documents[0].url?.lastPathComponent == "Renamed.md")
    _ = awaitTask { await tools.run("open_file", input: ["path": "Sub/New.md"]) }
    check("agent can open files in tabs", opened.last?.lastPathComponent == "New.md")
    pages.window?.orderOut(nil)
}
controller.window?.orderOut(nil); restored.window?.orderOut(nil)
print(failures == 0 ? "ALL WORKSPACE TESTS PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
