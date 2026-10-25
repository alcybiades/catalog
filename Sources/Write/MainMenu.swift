import AppKit

extension AppDelegate {

    func buildMainMenu() {
        let mainMenu = NSMenu()

        // App
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Write", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Write", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Write", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Note", action: #selector(newTab(_:)), keyEquivalent: "t")
        let wikiTab = fileMenu.addItem(withTitle: "New Wikipedia Page", action: #selector(newWikiTab(_:)), keyEquivalent: "T")
        wikiTab.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let folder = fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder(_:)), keyEquivalent: "o")
        folder.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(withTitle: "Close Folder", action: #selector(EditorWindowController.closeFolder(_:)), keyEquivalent: "")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        recentItem.submenu = openRecentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue

        // Format
        let formatItem = NSMenuItem()
        mainMenu.addItem(formatItem)
        let formatMenu = NSMenu(title: "Format")
        formatItem.submenu = formatMenu
        formatMenu.addItem(withTitle: "Bold", action: #selector(EditorTextView.toggleBoldMD(_:)), keyEquivalent: "b")
        formatMenu.addItem(withTitle: "Italic", action: #selector(EditorTextView.toggleItalicMD(_:)), keyEquivalent: "i")
        formatMenu.addItem(withTitle: "Code", action: #selector(EditorTextView.toggleCodeMD(_:)), keyEquivalent: "e")
        formatMenu.addItem(withTitle: "Link", action: #selector(EditorTextView.insertLinkMD(_:)), keyEquivalent: "k")
        formatMenu.addItem(.separator())
        for level in 1...6 {
            let item = formatMenu.addItem(withTitle: "Heading \(level)", action: #selector(EditorTextView.setHeading(_:)), keyEquivalent: "\(level)")
            item.tag = level
        }
        let clear = formatMenu.addItem(withTitle: "Clear Heading", action: #selector(EditorTextView.setHeading(_:)), keyEquivalent: "0")
        clear.tag = 0
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: "Bigger Text", action: #selector(increaseFontSize(_:)), keyEquivalent: "=")
        formatMenu.addItem(withTitle: "Smaller Text", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")

        // Go: Wikipedia navigation
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        goMenu.addItem(withTitle: "Back", action: #selector(EditorWindowController.wikiBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Search Wikipedia", action: #selector(EditorWindowController.searchWikipedia(_:)), keyEquivalent: "l")
        let random = goMenu.addItem(withTitle: "Random Article", action: #selector(EditorWindowController.randomArticle(_:)), keyEquivalent: "r")
        random.keyEquivalentModifierMask = [.command, .option]
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Show Assistant", action: #selector(toggleAgent(_:)), keyEquivalent: "j")

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: "Next Tab", action: #selector(EditorWindowController.nextTab(_:)), keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let prevTab = windowMenu.addItem(withTitle: "Previous Tab", action: #selector(EditorWindowController.previousTab(_:)), keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        let nextTabCtrl = windowMenu.addItem(withTitle: "Next Tab (Control)", action: #selector(EditorWindowController.nextTab(_:)), keyEquivalent: "\t")
        nextTabCtrl.keyEquivalentModifierMask = [.control]
        nextTabCtrl.isAlternate = false
        nextTabCtrl.isHidden = true
        let prevTabCtrl = windowMenu.addItem(withTitle: "Previous Tab (Control)", action: #selector(EditorWindowController.previousTab(_:)), keyEquivalent: "\t")
        prevTabCtrl.keyEquivalentModifierMask = [.control, .shift]
        prevTabCtrl.isHidden = true
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
