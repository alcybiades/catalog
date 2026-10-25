import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var openRecentMenu: NSMenu!
    private(set) var controllers: [EditorWindowController] = []
    private var settings: SettingsWindowController?

    /// The controller of the key window, else the frontmost one.
    var keyController: EditorWindowController? {
        if let key = NSApp.keyWindow, let c = controllers.first(where: { $0.window === key }) {
            return c
        }
        return controllers.first
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture before any window exists: refreshChrome() overwrites the
        // stored session as windows come up.
        let savedWindows = AppState.defaults.array(forKey: "sessionWindows") as? [[String: Any]] ?? []
        // Scripting: `--assistant-model codex:<model>` (or claude-code:opus, claude-api, apple).
        if let index = CommandLine.arguments.firstIndex(of: "--assistant-model"), CommandLine.arguments.indices.contains(index + 1),
           let backend = AgentBackend(storageValue: CommandLine.arguments[index + 1]) {
            AgentBackend.preferred = backend
        }
        buildMainMenu()

        let args = Array(CommandLine.arguments.dropFirst())
        var cliFiles: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if Self.valueFlags.contains(arg) { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            cliFiles.append(arg)
        }

        if !cliFiles.isEmpty {
            let controller = makeWindow()
            for path in cliFiles { controller.open(url: URL(fileURLWithPath: path)) }
        } else {
            restoreSession(savedWindows)
            restoreRecoveredDrafts()
            if controllers.isEmpty { makeWindow() }
        }

        NSApp.activate(ignoringOtherApps: true)

        // Debug: select line N fully and bold it, to reproduce artifacts.
        if let flagIndex = args.firstIndex(of: "--boldline"), args.indices.contains(flagIndex + 1),
           let lineNumber = Int(args[flagIndex + 1]), let tv = keyController?.textView {
            let ns = tv.string as NSString
            var lineStart = 0
            for _ in 0..<lineNumber {
                lineStart = NSMaxRange(ns.lineRange(for: NSRange(location: lineStart, length: 0)))
            }
            tv.setSelectedRange(ns.lineRange(for: NSRange(location: lineStart, length: 0)))
            tv.toggleBoldMD(nil)
        }

        if args.contains("--settings") { openSettings(nil) }
        // Scripting: `--wiki "Title"` opens an article, `--assistant` shows
        // the assistant, and `--ask "Question"` sends it a question.
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        if let title = value(after: "--wiki") { keyController?.openArticle(title) }
        if args.contains("--assistant") || value(after: "--ask") != nil { keyController?.setAgentOpen(true) }
        if let offset = value(after: "--scroll").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in keyController?.scrollPage(to: CGFloat(offset)) }
        }
        if let question = value(after: "--ask") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in keyController?.agent.send(question) }
        }
        if let outPath = value(after: "--snapshot") {
            let delay = Double(value(after: "--snapshot-delay") ?? "") ?? 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                let targetWindow = args.contains("--settings") ? settings?.window : keyController?.window
                guard let window = targetWindow else { return }
                // The window server's composite, so Liquid Glass and the
                // background blur appear as on screen (an app may always
                // capture its own windows).
                if let image = Self.windowImage(window) {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: outPath))
                } else if let view = window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: outPath))
                }
                keyController?.dumpLineFragments(to: outPath + ".layout.txt")
            }
        }
    }

    private typealias CreateWindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateWindowImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3; kCGWindowImageBoundsIgnoreFraming = 1 << 0
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Flags whose next argument is a value, not a file to open.
    static let valueFlags: Set<String> = ["--snapshot", "--snapshot-delay", "--wiki", "--ask", "--scroll", "--assistant-model"]

    /// AppKit also delivers path-like launch arguments here, including flag
    /// values such as the --snapshot output path (which doesn't exist yet).
    private static let flagValues: Set<String> = {
        let args = CommandLine.arguments
        return Set(args.indices.dropLast().filter { valueFlags.contains(args[$0]) }.map { args[$0 + 1] })
    }()

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if Self.flagValues.contains(filename) { return true }
        let controller = keyController ?? makeWindow()
        return controller.open(url: URL(fileURLWithPath: filename))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit never prompts: named documents flush to their files, untitled
        // buffers persist as recovery drafts and reappear next launch. Only
        // if a draft cannot be written do we fall back to save/discard.
        for controller in controllers where !controller.persistAllDrafts() {
            guard controller.resolveAllUnsavedChanges() else { return .terminateCancel }
        }
        if !controllers.isEmpty { sessionChanged() }
        return .terminateNow
    }

    // MARK: - Windows

    private var cascadePoint = NSPoint.zero

    @discardableResult
    func makeWindow(documents: [Document] = [], frame frameString: String? = nil) -> EditorWindowController {
        // A new window opens on the home page: Wikipedia, a folder, a file,
        // or a blank note. Opening anything replaces it.
        let documents = documents.isEmpty ? [Document(wiki: WikiPage(style: .home))] : documents
        let controller = EditorWindowController(documents: documents, app: self)
        if let frameString, let window = controller.window {
            var frame = NSRectFromString(frameString)
            if frame.width > 100 {
                if let screen = NSScreen.main {
                    frame = window.constrainFrameRect(frame, to: screen)
                }
                window.setFrame(frame, display: false)
            }
        } else if let window = controller.window {
            // TextEdit-style cascade; AppKit keeps the result on screen.
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controllers.append(controller)
        controller.showWindow(nil)
        sessionChanged()
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    func windowClosed(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
        // Keep the stored session when the last window goes (the app is
        // quitting) so the next launch restores it.
        if !controllers.isEmpty { sessionChanged() }
    }

    /// Detach a tab into its own window at the drop point.
    func detachTab(from source: EditorWindowController, index: Int, to screenPoint: NSPoint) {
        guard let doc = source.removeDocument(at: index) else { return }
        let controller = makeWindow(documents: [doc])
        if let window = controller.window, let sourceFrame = source.window?.frame {
            window.setFrame(sourceFrame, display: false)
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 60, y: screenPoint.y + 18))
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
            }
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Focuses the tab holding `url` in any window, if it is already open.
    func focusExisting(url: URL) -> Bool {
        for controller in controllers where controller.focus(url: url) {
            addRecentFile(url)
            return true
        }
        return false
    }

    // MARK: - Fallbacks when no editor window is key (e.g. settings panel)

    @objc func newTab(_ sender: Any?) {
        if let keyController { keyController.newTab(sender) } else { makeWindow() }
    }

    @objc func newWikiTab(_ sender: Any?) {
        if let keyController { keyController.newWikiTab(sender) } else { makeWindow().newWikiTab(sender) }
    }

    @objc func toggleAgent(_ sender: Any?) {
        (keyController ?? makeWindow()).toggleAgent(sender)
    }

    @objc func closeTab(_ sender: Any?) {
        if let settingsWindow = settings?.window, NSApp.keyWindow === settingsWindow {
            settingsWindow.close()
            return
        }
        keyController?.closeTab(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        (keyController ?? makeWindow()).openDocument(sender)
    }

    @objc func openFolder(_ sender: Any?) {
        (keyController ?? makeWindow()).openFolder(sender)
    }

    // MARK: - Recent files

    private var recentFiles: [String] {
        get { AppState.defaults.stringArray(forKey: "recentFiles") ?? [] }
        set { AppState.defaults.set(Array(newValue.prefix(12)), forKey: "recentFiles") }
    }

    var recentFileURLs: [URL] {
        recentFiles.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func addRecentFile(_ url: URL) {
        var list = recentFiles.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentFiles = list
    }

    func recentFileRenamed(from oldURL: URL, to newURL: URL) {
        recentFiles = recentFiles.filter { $0 != oldURL.path }
        addRecentFile(newURL)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
        menu.removeAllItems()
        let files = recentFiles.filter { FileManager.default.fileExists(atPath: $0) }
        for path in files {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent,
                                  action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            menu.addItem(item)
        }
        if files.isEmpty {
            let empty = menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
    }

    @objc private func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        (keyController ?? makeWindow()).open(url: URL(fileURLWithPath: path))
    }

    @objc func clearRecentFiles(_ sender: Any?) {
        recentFiles = []
    }

    // MARK: - Session

    func sessionChanged() {
        let entries: [[String: Any]] = controllers.compactMap { controller in
            let files = controller.documents.compactMap { $0.url?.path }
            // Every tab in order: files by path, Wikipedia pages by article.
            let tabs: [[String: String]] = controller.documents.compactMap { doc in
                if let path = doc.url?.path { return ["file": path] }
                if let page = doc.wiki, !doc.isPlaceholder {
                    return ["wiki": page.article?.title ?? page.route.map { $0.isRandom ? "" : $0.query } ?? ""]
                }
                return nil
            }
            guard !tabs.isEmpty || controller.workspace != nil, let window = controller.window else { return nil }
            let currentTab: [String: String] = {
                let doc = controller.currentDocument
                if let path = doc.url?.path { return ["file": path] }
                if let page = doc.wiki { return ["wiki": page.article?.title ?? page.route?.query ?? ""] }
                return [:]
            }()
            return [
                "files": files,
                "tabs": tabs,
                "currentTab": currentTab,
                "agentOpen": controller.agentOpen,
                "agentWidth": Double(controller.agentWidth),
                "current": controller.currentDocument.url?.path ?? "",
                "frame": NSStringFromRect(window.frame),
                "workspace": controller.workspace?.root.path ?? "",
                "sidebarCollapsed": controller.sidebarCollapsed,
                "sidebarWidth": Double(controller.sidebarWidth),
                "mediaMode": controller.mediaMode,
            ]
        }
        AppState.defaults.set(entries, forKey: "sessionWindows")
    }

    private func restoreSession(_ savedWindows: [[String: Any]]) {
        for entry in savedWindows {
            let files = (entry["files"] as? [String] ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
            // Older sessions list only files.
            let tabs = (entry["tabs"] as? [[String: String]] ?? files.map { ["file": $0] }).filter { tab in
                if let path = tab["file"] { return FileManager.default.fileExists(atPath: path) }
                return tab["wiki"] != nil
            }
            guard !tabs.isEmpty || !(entry["workspace"] as? String ?? "").isEmpty else { continue }
            let controller = makeWindow(frame: entry["frame"] as? String)
            for tab in tabs {
                if let path = tab["file"] { controller.restoreTab(url: URL(fileURLWithPath: path)) }
                else if let title = tab["wiki"] { controller.restoreWikiTab(title: title) }
            }
            if let root = entry["workspace"] as? String, !root.isEmpty,
               FileManager.default.fileExists(atPath: root) {
                controller.restoreWorkspace(root: URL(fileURLWithPath: root), collapsed: entry["sidebarCollapsed"] as? Bool ?? false,
                                            width: CGFloat(entry["sidebarWidth"] as? Double ?? 220), media: entry["mediaMode"] as? Bool ?? false)
            }
            if let currentTab = entry["currentTab"] as? [String: String], let title = currentTab["wiki"],
               let index = controller.documents.firstIndex(where: { doc in
                   guard let page = doc.wiki else { return false }
                   return page.article?.title == title || page.route?.query == title
               }) {
                controller.switchTab(to: index)
            } else if let currentPath = entry["current"] as? String,
               let index = controller.documents.firstIndex(where: { $0.url?.path == currentPath }) {
                controller.switchTab(to: index)
            }
            if entry["agentOpen"] as? Bool == true {
                controller.setAgentOpen(true, width: CGFloat(entry["agentWidth"] as? Double ?? 380))
            }
        }
        // Legacy single-window session from earlier builds.
        if controllers.isEmpty {
            let paths = (AppState.defaults.stringArray(forKey: "sessionFiles") ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return }
            let controller = makeWindow()
            for path in paths { controller.open(url: URL(fileURLWithPath: path)) }
        }
    }

    /// Reopens drafts the previous run left behind (crash, force-quit, or a
    /// quit with untitled buffers). Session restore has already run, so named
    /// files that are open again picked their drafts up in open(url:).
    private func restoreRecoveredDrafts() {
        for entry in RecoveryStore.loadAll() {
            if let path = entry.path {
                let url = URL(fileURLWithPath: path)
                let isOpen = controllers.contains { c in c.documents.contains { $0.url == url } }
                guard !isOpen else { continue }
                if FileManager.default.fileExists(atPath: path) {
                    (keyController ?? makeWindow()).open(url: url)
                } else if !entry.content.isEmpty {
                    // The file vanished; keep the words as an untitled draft.
                    var orphan = entry
                    orphan.path = nil
                    orphan.title = url.deletingPathExtension().lastPathComponent
                    (keyController ?? makeWindow()).adoptRecoveredDraft(orphan)
                } else {
                    RecoveryStore.remove(id: entry.id)
                }
            } else if entry.content.isEmpty {
                RecoveryStore.remove(id: entry.id)
            } else {
                (keyController ?? makeWindow()).adoptRecoveredDraft(entry)
            }
        }
    }

    // MARK: - Settings & font

    @objc func openSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController { [weak self] in self?.applyFontChangeEverywhere() }
        }
        settings?.show()
    }

    private func applyFontChangeEverywhere() {
        controllers.forEach { $0.applyFontChange() }
    }

    @objc func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 2) }
    @objc func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -2) }

    private func adjustFontSize(by delta: CGFloat) {
        // On a Wikipedia page, ⌘= / ⌘− size the article text instead.
        if keyController?.currentDocument.kind == .wiki {
            WikiTheme.adjustFontSize(by: delta / 2)
            return
        }
        Theme.fontSize = min(max(Theme.fontSize + delta, 10), 64)
        applyFontChangeEverywhere()
    }
}
