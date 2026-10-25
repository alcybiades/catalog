import SwiftUI
import AppKit

/// The assistant's right sidebar, like an editor's agent panel: header on
/// the tab row, the conversation, and a growing glass input at the bottom.
struct AgentPanel: View {
    @Bindable var session: AgentSession
    let onClose: () -> Void

    @AppStorage(WikiTheme.bodyFontKey, store: AppState.defaults) private var bodyFamily = WikiTheme.defaultBodyFamily
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var font: ReaderFont { ReaderFont(family: bodyFamily, size: 17) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WikiTheme.hairline).frame(height: 1)
            if session.items.isEmpty {
                emptyState
            } else {
                transcript
            }
            input
        }
        .background {
            HStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                Color.black.opacity(0.10)
            }
            .ignoresSafeArea()
        }
        .tint(WikiTheme.foreground)
        .preferredColorScheme(.dark)
        .onChange(of: session.focusRequest) { focused = true }
        .onAppear {
            focused = true
            AgentAccounts.shared.refresh()
        }
        .environment(\.openURL, OpenURLAction { url in
            if let destination = WikiLink.destination(of: url) {
                session.openArticle?(destination.title)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            conversationMenu
            Spacer(minLength: 0)
            iconButton("square.and.pencil", help: "New conversation") {
                withAnimation(.snappy) { session.newConversation() }
            }
            iconButton("sidebar.right", help: "Hide Assistant (⌘J)", action: onClose)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 31)
        .padding(.top, TabBarView.cornerPadding)
        .padding(.bottom, 8)
    }

    /// The conversation's title, opening a list of this window's conversations.
    private var conversationMenu: some View {
        Menu {
            Button("New Conversation", systemImage: "square.and.pencil") { session.newConversation() }
            Divider()
            ForEach(session.conversations) { conversation in
                Button {
                    session.select(conversation)
                } label: {
                    Label(conversation.title + " · " + conversation.backend.label,
                          systemImage: conversation === session.current ? "checkmark" : conversation.backend.symbol)
                }
            }
            if session.conversations.count > 1 {
                Divider()
                Button("Close Conversation", systemImage: "xmark") { session.close(session.current) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.current.items.isEmpty ? "Assistant" : session.current.title)
                        .font(WikiTheme.interface(size: 13, weight: .semibold))
                        .foregroundStyle(WikiTheme.heading)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(WikiTheme.secondary)
                }
                Text(session.contextLabel.isEmpty ? (session.workingDirectory.path as NSString).abbreviatingWithTildeInPath
                     : session.contextLabel)
                    .font(WikiTheme.interface(size: 11))
                    .foregroundStyle(WikiTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Conversations")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WikiTheme.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "sparkle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(WikiTheme.heading.gradient)
            Text(intro)
                .font(font.scaled(0.9))
                .foregroundStyle(WikiTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = accountNotice { notice }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions, id: \.label) { suggestion in
                    Button {
                        session.send(suggestion.prompt)
                    } label: {
                        Label(suggestion.label, systemImage: suggestion.icon)
                            .font(WikiTheme.interface(size: 13))
                            .foregroundStyle(WikiTheme.foreground)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Shown when the chosen model needs installing or signing in.
    private var accountNotice: AnyView? {
        let accounts = AgentAccounts.shared
        let (name, status, isClaude): (String, AgentAccounts.Status, Bool)
        switch session.backend {
        case .claudeCode: (name, status, isClaude) = ("Claude", accounts.claude, true)
        case .codex: (name, status, isClaude) = ("Codex", accounts.codex, false)
        case .claudeAPI:
            guard !APIKeyStore.isConfigured else { return nil }
            return AnyView(NoticeCard(text: "Add an Anthropic API key in Settings (⌘,) to use the Claude API.",
                                      action: "Open Settings…") {
                NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
            })
        case .apple:
            guard let reason = AppleAssistant.unavailableReason else { return nil }
            return AnyView(NoticeCard(text: reason, action: nil) {})
        }
        switch status {
        case .ready, .checking: return nil
        case .notInstalled:
            return AnyView(NoticeCard(text: "\(name == "Claude" ? "Claude Code" : "Codex") isn’t installed on this Mac. Install it, then sign in with your \(name == "Claude" ? "Claude" : "ChatGPT") subscription.",
                                      action: "Get \(name == "Claude" ? "Claude Code" : "Codex")…") {
                NSWorkspace.shared.open(AgentAccounts.installPage(claude: isClaude))
            })
        case .signedOut:
            return AnyView(NoticeCard(text: "Sign in with your \(name == "Claude" ? "Claude" : "ChatGPT") subscription to use \(name) here.",
                                      action: "Sign In to \(name)…") {
                AgentAccounts.shared.signIn(claude: isClaude)
            })
        }
    }

    private var intro: String {
        let folder = (session.workingDirectory.path as NSString).abbreviatingWithTildeInPath
        if !session.backend.canEditFiles {
            return "Ask about what’s open. Apple Intelligence runs on this Mac and can’t edit files; pick Claude or Codex below for that."
        }
        switch session.contextKind {
        case .article: return "Ask about this article, or have notes written from it into \(folder)."
        case .note: return "Ask about this note, or have it edited. I can also create and change other notes in \(folder)."
        case .image: return "Ask about this image, or have notes written about it in \(folder)."
        default: return "Ask anything, or have notes created and edited in \(folder)."
        }
    }

    private var suggestions: [(label: String, prompt: String, icon: String)] {
        switch session.contextKind {
        case .article:
            return [
                ("Summarize", "Summarize this article in a few sentences.", "text.alignleft"),
                ("Key facts", "What are the key facts and dates I should know?", "list.star"),
                ("Explain simply", "Explain the core idea of this article simply, as if I'm new to the subject.", "lightbulb"),
                ("Save study notes", "Write a concise Markdown study note on this article — key ideas, dates, and people — and save it in the working directory.", "square.and.pencil"),
            ]
        case .note:
            return [
                ("Summarize", "Summarize this note in a few sentences.", "text.alignleft"),
                ("Tighten the writing", "Tighten the prose of this note without changing its meaning or structure, and apply the edits.", "wand.and.stars"),
                ("Continue writing", "Continue this note where it leaves off, in the same voice, and apply it.", "text.append"),
                ("Find related notes", "Search the working directory for notes related to this one and list them with a line on each.", "magnifyingglass"),
            ]
        case .image:
            return [
                ("Describe", "Describe this image.", "eye"),
                ("Write a caption note", "Write a short Markdown note that embeds this image with a caption and description, and save it next to the image.", "square.and.pencil"),
            ]
        default:
            return [
                ("What's here?", "Give me an overview of the working directory.", "folder"),
                ("Start a note", "Create a new note called Ideas.md with a short template for capturing ideas, and open it.", "square.and.pencil"),
            ]
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(session.items) { item in
                    ItemView(item: item, font: font, openFile: { session.openFile?($0) })
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                }
                if session.isResponding, session.items.last?.kind != .assistant || session.items.last?.text.isEmpty == true,
                   session.items.last?.status != .running {
                    TypingIndicator()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .animation(.snappy, value: session.items.count)
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask, or ask for changes…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(WikiTheme.interface(size: 14))
                    .foregroundStyle(WikiTheme.foreground)
                    .lineLimit(1...8)
                    .scrollContentBackground(.hidden)
                    .focusEffectDisabled()
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 8)
                sendButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(focused ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(focused ? WikiTheme.foreground.opacity(0.35) : WikiTheme.hairline, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            HStack(spacing: 6) {
                ModelPicker(session: session)
                Spacer(minLength: 4)
                Label((session.workingDirectory.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("The assistant can create and edit files here")
            }
            .font(WikiTheme.interface(size: 10.5))
            .foregroundStyle(WikiTheme.dim)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var sendButton: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if session.isResponding {
            Button(action: session.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(WikiTheme.selection)
            .help("Stop")
            .padding(.bottom, 2)
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(canSend ? WikiTheme.foreground.opacity(0.85) : Color.white.opacity(0.12))
            .disabled(!canSend)
            .help("Send")
            .padding(.bottom, 2)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isResponding else { return }
        draft = ""
        session.send(text)
    }
}

// MARK: - Items

private struct ItemView: View {
    let item: AgentConversation.Item
    let font: ReaderFont
    let openFile: (URL) -> Void

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let detail = item.detail {
                    Label(detail, systemImage: "paperclip")
                        .font(WikiTheme.interface(size: 10.5))
                        .foregroundStyle(WikiTheme.dim)
                        .lineLimit(1)
                }
                Text(item.text)
                    .font(font.scaled(0.86))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineSpacing(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 28)
        case .assistant:
            Text(Self.styled(item.text))
                .font(font.scaled(0.9))
                .foregroundStyle(WikiTheme.foreground)
                .tint(WikiTheme.link)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }
                }
        case .tool:
            ToolRow(item: item, openFile: openFile)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle")
                .font(WikiTheme.interface(size: 12.5))
                .foregroundStyle(Color(hex: 0xFF8A7A))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Light Markdown in Write's colors: bold white, italics lavender, code amber.
    static func styled(_ markdown: String) -> AttributedString {
        // Inline-only parsing keeps line breaks; draw list markers as bullets.
        let source = markdown.replacingOccurrences(of: #"(?m)^(\s*)[*+-] (?=\S)"#, with: "$1• ", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var text = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var searchStart = text.startIndex
        while let range = text[searchStart...].range(of: "• ") {
            text[range].foregroundColor = WikiTheme.listMarker
            searchStart = range.upperBound
        }
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.stronglyEmphasized) { text[run.range].foregroundColor = WikiTheme.bold }
            else if intent.contains(.emphasized) { text[run.range].foregroundColor = WikiTheme.italic }
            if intent.contains(.code) { text[run.range].foregroundColor = WikiTheme.inlineCode }
        }
        return text
    }
}

/// A file or search step: what the assistant did, and a way to open it.
private struct ToolRow: View {
    let item: AgentConversation.Item
    let openFile: (URL) -> Void

    private var icon: String {
        switch item.status {
        case .running: return "circle.dotted"
        case .failed: return "exclamationmark.circle"
        case .done:
            if item.text.hasPrefix("Created") || item.text.hasPrefix("Rewrote") || item.text.hasPrefix("Edited") { return "pencil.circle" }
            if item.text.hasPrefix("Moved") { return "arrow.right.circle" }
            return "checkmark.circle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.status == .failed ? Color(hex: 0xFF8A7A) : WikiTheme.code)
                .symbolEffect(.rotate, options: .repeating, isActive: item.status == .running)
            Text(item.text)
                .font(WikiTheme.interface(size: 12))
                .foregroundStyle(WikiTheme.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let url = item.url, item.status == .done {
                Button("Open") { openFile(url) }
                    .buttonStyle(.plain)
                    .font(WikiTheme.interface(size: 11.5, weight: .semibold))
                    .foregroundStyle(WikiTheme.link)
                    .help(url.path)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WikiTheme.hairline, lineWidth: 1))
        .help(item.detail ?? item.text)
    }
}

private struct TypingIndicator: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(WikiTheme.secondary)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            .frame(height: 22)
            .accessibilityLabel("Thinking")
    }
}

/// The model menu at the bottom of the panel: Claude and Codex through the
/// user's subscriptions, the Claude API with a key, and Apple Intelligence.
private struct ModelPicker: View {
    let session: AgentSession

    var body: some View {
        let accounts = AgentAccounts.shared
        Menu {
            Section("Claude · your subscription") {
                ForEach(AgentBackend.claudeCodeModels, id: \.id) { model in
                    option(.claudeCode(model: model.id), title: "Claude " + model.label, enabled: accounts.claude.isReady)
                }
                accountAction(accounts.claude, claude: true)
            }
            Section("Codex · your ChatGPT subscription") {
                if accounts.codexModels.isEmpty, accounts.codex.isReady {
                    Text("Loading models…")
                }
                ForEach(accounts.codexModels, id: \.id) { model in
                    option(.codex(model: model.id), title: model.name, enabled: accounts.codex.isReady)
                }
                accountAction(accounts.codex, claude: false)
            }
            Section("Other") {
                option(.claudeAPI, title: "Claude API · Opus 5.5" + (APIKeyStore.isConfigured ? "" : " (needs a key)"), enabled: true)
                option(.apple, title: "Apple Intelligence · read-only", enabled: AppleAssistant.unavailableReason == nil)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: session.backend.symbol)
                Text(session.backend.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(WikiTheme.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose the model")
    }

    private func option(_ backend: AgentBackend, title: String, enabled: Bool) -> some View {
        Button {
            session.choose(backend)
        } label: {
            if backend == session.backend { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(!enabled)
    }

    @ViewBuilder
    private func accountAction(_ status: AgentAccounts.Status, claude: Bool) -> some View {
        let name = claude ? "Claude" : "Codex"
        switch status {
        case .checking:
            Text("Checking \(name)…")
        case .notInstalled:
            Button("Get \(claude ? "Claude Code" : "Codex")…") { NSWorkspace.shared.open(AgentAccounts.installPage(claude: claude)) }
        case .signedOut:
            Button("Sign In to \(name)…") { AgentAccounts.shared.signIn(claude: claude) }
        case .ready:
            EmptyView()
        }
    }
}

/// A short message with an optional action, in the empty conversation.
private struct NoticeCard: View {
    let text: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: "person.crop.circle.badge.exclamationmark")
                .font(WikiTheme.interface(size: 12.5))
                .foregroundStyle(WikiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action, action: perform)
                    .buttonStyle(.glassPill)
                    .font(WikiTheme.interface(size: 12.5))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WikiTheme.hairline, lineWidth: 1))
    }
}
