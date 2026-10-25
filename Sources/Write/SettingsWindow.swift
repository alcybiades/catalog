import AppKit

/// Minimal settings panel with independent document and interface fonts,
/// applied live and persisted.
final class SettingsWindowController: NSObject {

    private(set) var window: NSWindow?
    private let onFontChange: () -> Void
    private var interfaceLabels: [(label: NSTextField, size: CGFloat)] = []
    private var popups: [NSPopUpButton] = []
    private var colorWells: [Int: NSColorWell] = [:]
    private var noColorButtons: [Int: NSButton] = [:]
    private var keyField: NSSecureTextField?
    private var keyButton: NSButton?
    private var keyStatus: NSTextField?

    private enum ColorRole: Int, CaseIterable {
        case bold, heading, italic, listMarker, quote, inlineCode, link

        var title: String {
            switch self {
            case .bold: return "bold text"
            case .heading: return "headings"
            case .italic: return "italic text"
            case .listMarker: return "list markers"
            case .quote: return "quotes"
            case .inlineCode: return "inline code"
            case .link: return "links"
            }
        }

        var color: NSColor? {
            get {
                switch self {
                case .bold: return Theme.bold
                case .heading: return Theme.heading
                case .italic: return Theme.italic
                case .listMarker: return Theme.listMarker
                case .quote: return Theme.quote
                case .inlineCode: return Theme.codeAmber
                case .link: return Theme.link
                }
            }
            set {
                switch self {
                case .bold: Theme.bold = newValue
                case .heading: Theme.heading = newValue
                case .italic: Theme.italic = newValue
                case .listMarker: Theme.listMarker = newValue
                case .quote: Theme.quote = newValue
                case .inlineCode: Theme.codeAmber = newValue
                case .link: Theme.link = newValue
                }
            }
        }
    }

    init(onFontChange: @escaping () -> Void) {
        self.onFontChange = onFontChange
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = WriteWindow(
            contentRect: NSRect(x: 0, y: 0, width: 455, height: 530),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false

        let container = applyTerminalBackdrop(to: panel)

        // Native titlebar controls are hidden, so draw our own × in the
        // corner, mirroring the tab strip's.
        let close = HoverCloseButton()
        close.onClick = { [weak panel] in panel?.close() }
        close.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            close.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])

        let heading = NSTextField(labelWithString: "settings")
        heading.font = Theme.interfaceFont(size: 12)
        heading.textColor = Theme.secondary
        interfaceLabels.append((heading, 12))

        let bodyRow = fontRow(label: "body font", selectedFamily: Theme.fontFamily, tag: 0)
        let interfaceRow = fontRow(label: "interface font", selectedFamily: Theme.interfaceFontFamily, tag: 1)

        let colorsHeading = NSTextField(labelWithString: "semantic colors")
        colorsHeading.font = Theme.interfaceFont(size: 12)
        colorsHeading.textColor = Theme.secondary
        interfaceLabels.append((colorsHeading, 12))

        let colorRows = ColorRole.allCases.map(colorRow)
        let colors = NSStackView(views: colorRows)
        colors.orientation = .vertical
        colors.alignment = .leading
        colors.spacing = 7

        let assistantHeading = NSTextField(labelWithString: "assistant")
        assistantHeading.font = Theme.interfaceFont(size: 12)
        assistantHeading.textColor = Theme.secondary
        interfaceLabels.append((assistantHeading, 12))
        let assistant = assistantRows()

        let column = NSStackView(views: [heading, bodyRow, interfaceRow, colorsHeading, colors, assistantHeading, assistant])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 13
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: container.topAnchor, constant: 34),
            bodyRow.widthAnchor.constraint(equalToConstant: 405),
            interfaceRow.widthAnchor.constraint(equalToConstant: 405),
            colors.widthAnchor.constraint(equalToConstant: 405),
        ])

        panel.center()
        window = panel
    }

    private func fontRow(label title: String, selectedFamily: String, tag: Int) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.interfaceFont(size: 13)
        label.textColor = Theme.foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        interfaceLabels.append((label, 13))

        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = Theme.interfaceFont(size: 13)
        popup.contentTintColor = Theme.foreground
        popup.target = self
        popup.action = #selector(fontSelected(_:))
        popup.tag = tag
        // Items are added with nil actions; without this, menu validation
        // can disable them all, making the font list unselectable.
        popup.autoenablesItems = false
        let families = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for family in families {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.isEnabled = true
            if let previewFont = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) {
                item.attributedTitle = NSAttributedString(string: family, attributes: [
                    .font: previewFont,
                    .foregroundColor: NSColor.labelColor,
                ])
            }
            popup.menu?.addItem(item)
        }
        popup.selectItem(withTitle: selectedFamily)
        if popup.selectedItem == nil { popup.selectItem(withTitle: Theme.defaultFontFamily) }
        popups.append(popup)

        // A subtle pill behind the borderless popup, echoing the tab style.
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        pill.layer?.cornerRadius = 5
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.widthAnchor.constraint(equalToConstant: 288).isActive = true
        popup.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            popup.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            popup.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
        ])

        let row = NSStackView(views: [label, pill])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    private func colorRow(_ role: ColorRole) -> NSView {
        let label = NSTextField(labelWithString: role.title)
        label.font = Theme.interfaceFont(size: 13)
        label.textColor = Theme.foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        interfaceLabels.append((label, 13))

        let well = NSColorWell()
        well.color = role.color ?? Theme.foreground
        well.tag = role.rawValue
        well.target = self
        well.action = #selector(colorSelected(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 48),
            well.heightAnchor.constraint(equalToConstant: 24),
        ])

        let noColor = NSButton(checkboxWithTitle: "No color", target: self,
                               action: #selector(noColorSelected(_:)))
        noColor.tag = role.rawValue
        noColor.font = Theme.interfaceFont(size: 12)
        noColor.state = role.color == nil ? .on : .off
        well.isEnabled = role.color != nil
        colorWells[role.rawValue] = well
        noColorButtons[role.rawValue] = noColor

        let row = NSStackView(views: [label, well, noColor])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 405).isActive = true
        return row
    }

    /// The Anthropic API key for the assistant, kept in the Keychain (shared
    /// with Encyclopedia). ANTHROPIC_API_KEY in the environment also works.
    private func assistantRows() -> NSView {
        let label = NSTextField(labelWithString: "anthropic key")
        label.font = Theme.interfaceFont(size: 13)
        label.textColor = Theme.foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        interfaceLabels.append((label, 13))

        let field = NSSecureTextField()
        field.placeholderString = "sk-ant-…"
        field.font = Theme.interfaceFont(size: 12)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        field.focusRingType = .none
        field.target = self
        field.action = #selector(keyAction(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        keyField = field

        let button = NSButton(title: "Save", target: self, action: #selector(keyAction(_:)))
        button.font = Theme.interfaceFont(size: 12)
        button.bezelStyle = .push
        keyButton = button

        let row = NSStackView(views: [label, field, button])
        row.orientation = .horizontal
        row.spacing = 12

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = Theme.interfaceFont(size: 11)
        status.textColor = Theme.secondary
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 405).isActive = true
        keyStatus = status
        interfaceLabels.append((status, 11))

        let stack = NSStackView(views: [row, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        refreshKeyRow()
        return stack
    }

    private func refreshKeyRow() {
        let saved = APIKeyStore.read()
        let hasSaved = !(saved ?? "").isEmpty
        keyField?.isHidden = hasSaved
        keyButton?.title = hasSaved ? "Remove saved key" : "Save"
        if hasSaved, let saved {
            keyStatus?.stringValue = "Saved in your Keychain (\(saved.prefix(7))…\(saved.suffix(4))). Used by “Claude API” in the assistant’s model menu; Claude and Codex subscriptions sign in from that menu."
        } else if APIKeyStore.key != nil {
            keyStatus?.stringValue = "Using ANTHROPIC_API_KEY from the environment."
        } else {
            keyStatus?.stringValue = "Optional. The assistant can also use your Claude or ChatGPT subscription through Claude Code or Codex — choose them in its model menu."
        }
    }

    @objc private func keyAction(_ sender: Any?) {
        if !(APIKeyStore.read() ?? "").isEmpty {
            APIKeyStore.save(nil)
        } else {
            guard let value = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            APIKeyStore.save(value)
            keyField?.stringValue = ""
        }
        refreshKeyRow()
    }

    @objc private func fontSelected(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        if sender.tag == 0 {
            Theme.fontFamily = family
        } else {
            Theme.interfaceFontFamily = family
            interfaceLabels.forEach { entry in
                entry.label.font = Theme.interfaceFont(size: entry.size)
            }
            popups.forEach { $0.font = Theme.interfaceFont(size: 13) }
            noColorButtons.values.forEach { $0.font = Theme.interfaceFont(size: 12) }
        }
        onFontChange()
    }

    @objc private func colorSelected(_ sender: NSColorWell) {
        guard var role = ColorRole(rawValue: sender.tag) else { return }
        role.color = sender.color
        noColorButtons[sender.tag]?.state = .off
        sender.isEnabled = true
        onFontChange()
    }

    @objc private func noColorSelected(_ sender: NSButton) {
        guard var role = ColorRole(rawValue: sender.tag) else { return }
        if sender.state == .on {
            role.color = nil
            colorWells[sender.tag]?.isEnabled = false
        } else {
            let color = colorWells[sender.tag]?.color ?? Theme.foreground
            role.color = color
            colorWells[sender.tag]?.isEnabled = true
        }
        onFontChange()
    }
}
