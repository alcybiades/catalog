import Foundation
import AppKit
import CryptoKit

/// The app's one assistant: its conversations (each pinned to the model it
/// started with) and the model picker, shared by every window so a message
/// sent in one appears, streaming, in all of them. Each window attaches an
/// `AgentSession` for what stays its own: the open tab, the draft, and
/// where tools act.
@MainActor @Observable
final class AgentStore {
    static let shared = AgentStore()

    private(set) var conversations: [AgentConversation] = []
    private(set) var current: AgentConversation
    /// The model new conversations use; the picker at the bottom.
    private(set) var backend: AgentBackend
    @ObservationIgnored private var sessions: [WeakSession] = []
    /// The window last made key: where tools act once the sending window
    /// has closed.
    @ObservationIgnored weak var frontmost: AgentSession?

    private struct WeakSession { weak var session: AgentSession? }

    init() {
        let backend = AgentBackend.preferred
        self.backend = backend
        current = AgentConversation(backend: backend)
        conversations = [current]
        current.store = self
        // Until the user picks a model, follow what's available once the
        // CLIs have been checked (that finishes after launch).
        NotificationCenter.default.addObserver(forName: AgentAccounts.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AgentBackend.hasChoice else { return }
                let best = AgentBackend.preferred
                guard best != self.backend else { return }
                self.backend = best
                for conversation in self.conversations where conversation.items.isEmpty { conversation.backend = best }
            }
        }
    }

    var attached: [AgentSession] { sessions.compactMap(\.session) }

    func attach(_ session: AgentSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
        sessions.append(WeakSession(session: session))
    }

    /// A closing window stops being a tool target; replies it started keep
    /// streaming to the other windows.
    func detach(_ session: AgentSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
        for conversation in conversations where conversation.origin === session { conversation.origin = nil }
        if frontmost === session { frontmost = nil }
    }

    /// Sends from `session`'s window. Every window first saves its notes,
    /// since a CLI may read any open file. Sends are serialized on the main
    /// actor: once one starts, the conversation is responding and a second
    /// window's send is refused.
    func send(_ question: String, from session: AgentSession) {
        guard !current.isResponding else { return }
        attached.forEach { $0.prepareToSend?() }
        guard let context = session.contextProvider?() else { return }
        current.origin = session
        current.send(question, context: context)
    }

    func stop() { current.stop() }
    func stopAll() { conversations.forEach { $0.stop() } }

    /// Starts a fresh conversation with the selected model (reusing an empty one).
    func newConversation() {
        if current.items.isEmpty && current.backend == backend { return }
        if let empty = conversations.first(where: { $0.items.isEmpty }) {
            empty.backend = backend
            current = empty
        } else {
            let conversation = AgentConversation(backend: backend)
            conversation.store = self
            conversations.insert(conversation, at: 0)
            current = conversation
        }
    }

    func select(_ conversation: AgentConversation) {
        current = conversation
        backend = conversation.backend
    }

    /// Picking a model applies to the current conversation while it is
    /// empty; otherwise it starts a new one (a CLI session can't switch).
    func choose(_ backend: AgentBackend) {
        self.backend = backend
        AgentBackend.preferred = backend
        if current.items.isEmpty {
            current.backend = backend
        } else if current.backend != backend {
            newConversation()
        }
    }

    func close(_ conversation: AgentConversation) {
        conversation.stop()
        conversations.removeAll { $0 === conversation }
        if conversations.isEmpty {
            let fresh = AgentConversation(backend: backend)
            fresh.store = self
            conversations = [fresh]
        }
        if current === conversation { current = conversations[0] }
    }
}

/// One window's side of the shared assistant: the tab context every
/// message carries (so the assistant follows the user across tabs), the
/// unsent draft, focus, and the window's handlers for opening things.
@MainActor @Observable
final class AgentSession {
    let store: AgentStore
    /// The open tab, shown in the panel header.
    var contextLabel = ""
    var contextKind: AgentContext.Kind = .home
    var workingDirectory: URL = AgentSession.defaultDirectory
    /// The unsent message, shared by the floating and docked panels.
    var draft = ""
    /// The panel on screen, which alone takes focus requests.
    @ObservationIgnored var activeStyle: AgentPanel.Style?
    /// Bumped to focus the input field.
    private(set) var focusRequest = 0

    @ObservationIgnored var contextProvider: (() -> AgentContext)?
    /// Saves unsaved notes so the assistant reads what the user sees.
    @ObservationIgnored var prepareToSend: (() -> Void)?
    @ObservationIgnored var openFile: ((URL) -> Void)?
    @ObservationIgnored var openArticle: ((String) -> Void)?

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    init(store: AgentStore? = nil) {
        self.store = store ?? .shared
        self.store.attach(self)
    }

    var conversations: [AgentConversation] { store.conversations }
    var current: AgentConversation { store.current }
    var backend: AgentBackend { store.backend }
    var items: [AgentConversation.Item] { current.items }
    var isResponding: Bool { current.isResponding }

    func requestFocus() { focusRequest += 1 }

    func send(_ question: String) { store.send(question, from: self) }
    func stop() { store.stop() }
    func newConversation() { store.newConversation(); requestFocus() }
    func select(_ conversation: AgentConversation) { store.select(conversation); requestFocus() }
    func choose(_ backend: AgentBackend) { store.choose(backend); requestFocus() }
    func close(_ conversation: AgentConversation) { store.close(conversation) }
}

/// One conversation with one model. Claude Code and Codex keep their own
/// session (resumed by id each turn); the API backend keeps the history.
@MainActor @Observable
final class AgentConversation: Identifiable {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case user, assistant, tool, error }
        enum Status: Equatable { case running, done, failed }
        let id = UUID()
        var kind: Kind
        var text: String
        /// User messages: what was open. Tools: the outcome.
        var detail: String?
        var status: Status = .done
        var url: URL?
    }

    let id = UUID()
    /// Fixed once the conversation has messages.
    var backend: AgentBackend
    private(set) var items: [Item] = []
    private(set) var isResponding = false
    @ObservationIgnored weak var store: AgentStore?
    /// The window the latest message came from: its tab is the one the
    /// context described, and its tools open files there.
    @ObservationIgnored weak var origin: AgentSession?

    init(backend: AgentBackend) {
        self.backend = backend
    }

    /// Scripting (test mode only): shows a canned exchange, as JSON
    /// `[{"role": "user"|"assistant"|"tool", "text", "detail"?, "url"?}]`
    /// (a `url` path is relative to the JSON file),
    /// without calling a model.
    func loadTranscript(_ url: URL) {
        guard AppState.isTesting, let data = try? Data(contentsOf: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
        let kinds: [String: Item.Kind] = ["user": .user, "assistant": .assistant, "tool": .tool, "error": .error]
        items = entries.compactMap { entry in
            guard let kind = entry["role"].flatMap({ kinds[$0] }), let text = entry["text"] else { return nil }
            return Item(kind: kind, text: text, detail: entry["detail"], url: entry["url"].map { URL(fileURLWithPath: $0, relativeTo: url.deletingLastPathComponent()).absoluteURL })
        }
    }

    var title: String {
        guard let first = items.first(where: { $0.kind == .user })?.text else { return "New conversation" }
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }

    /// The CLI's session, resumed on every later turn.
    @ObservationIgnored private var cliSessionID: String?
    @ObservationIgnored private var history: [[String: Any]] = []
    /// Digest of the text last sent per context, so unchanged articles and
    /// notes aren't resent every turn (they stay cached in the prefix).
    @ObservationIgnored private var sentDigests: [String: String] = [:]
    @ObservationIgnored private var sentImages: Set<String> = []
    @ObservationIgnored private var lastContextKey: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func send(_ question: String, context: AgentContext) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        let key = Self.key(for: context)
        items.append(Item(kind: .user, text: question, detail: key == lastContextKey ? nil : context.label))
        lastContextKey = key
        isResponding = true
        let backend = backend

        task = Task { [weak self] in
            guard let self else { return }
            do {
                switch backend {
                case .claudeAPI:
                    guard let key = APIKeyStore.key else { throw AssistantError.needsSetup }
                    try await runClaude(apiKey: key, question: question, context: context)
                case .claudeCode(let model):
                    try await runCLI(question: question, context: context) { prompt, session, onEvent in
                        try await ClaudeCodeRunner.run(prompt: prompt, model: model, sessionID: session,
                                                       directory: context.workingDirectory,
                                                       extraDirectory: Self.extraDirectory(context), onEvent: onEvent)
                    }
                case .codex(let model):
                    let images = context.kind == .image ? [context.fileURL].compactMap { $0 } : []
                    try await runCLI(question: question, context: context) { prompt, session, onEvent in
                        try await CodexRunner.run(prompt: prompt, model: model, sessionID: session,
                                                  directory: context.workingDirectory,
                                                  extraDirectory: Self.extraDirectory(context),
                                                  images: images, onEvent: onEvent)
                    }
                case .apple:
                    if let reason = AppleAssistant.unavailableReason { throw AssistantError.appleUnavailable(reason) }
                    try await runApple(question: question, context: context)
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                items.append(Item(kind: .error, text: error.localizedDescription))
            }
            finish()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func reset() {
        stop()
        items.removeAll()
        history.removeAll()
        sentDigests.removeAll()
        sentImages.removeAll()
        lastContextKey = nil
        cliSessionID = nil
        isResponding = false
    }

    private func finish() {
        for index in items.indices where items[index].status == .running {
            items[index].status = .failed
            items[index].detail = "Stopped"
        }
        // A cancelled tool round leaves tool_use blocks without results; the
        // API would reject the next turn, so close them out.
        if let last = history.last, last["role"] as? String == "assistant",
           let content = last["content"] as? [[String: Any]] {
            let pending = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            if !pending.isEmpty {
                history.append(["role": "user", "content": pending.map {
                    ["type": "tool_result", "tool_use_id": $0, "content": "Stopped by the user.", "is_error": true] as [String: Any]
                }])
            }
        }
        isResponding = false
        task = nil
    }

    // MARK: Claude

    private func runClaude(apiKey: String, question: String, context: AgentContext) async throws {
        var content: [[String: Any]] = [["type": "text", "text": contextText(context)]]
        if context.kind == .image, let url = context.fileURL, !sentImages.contains(url.path),
           let image = NSImage(contentsOf: url), let jpeg = AgentImage.jpeg(image) {
            content.append(AgentImage.block(jpeg))
            sentImages.insert(url.path)
        }
        content.append(["type": "text", "text": question])
        history.append(["role": "user", "content": content])

        let tools = AgentTools(root: context.workingDirectory, openFile: context.fileURL) { [weak self] url in
            guard let self else { return }
            (self.origin ?? self.store?.frontmost)?.openFile?(url)
        }
        for _ in 0..<40 {
            var textItems: [Int: UUID] = [:]
            var toolItems: [Int: UUID] = [:]
            let turn = try await ClaudeAgent.turn(apiKey: apiKey, messages: history, tools: AgentTools.definitions) { event in
                switch event {
                case .blockStarted(let index, "text", _):
                    let item = Item(kind: .assistant, text: "")
                    textItems[index] = item.id
                    items.append(item)
                case .blockStarted(let index, "tool_use", let name):
                    let item = Item(kind: .tool, text: Self.pendingLabel(name ?? "tool"), status: .running)
                    toolItems[index] = item.id
                    items.append(item)
                case .textDelta(let index, let text):
                    if let id = textItems[index] { update(id) { $0.text += text } }
                default:
                    break
                }
            }
            // Empty text items (a block that never got text) disappear.
            items.removeAll { $0.kind == .assistant && $0.text.isEmpty && textItems.values.contains($0.id) }

            history.append(["role": "assistant", "content": turn.content.map {
                var block = $0
                block[ClaudeAgent.invalidInputKey] = nil
                return block
            }])

            switch turn.stopReason {
            case "tool_use":
                break
            case "refusal":
                throw AssistantError.refused
            case "max_tokens" where turn.content.contains(where: { $0["type"] as? String == "tool_use" }):
                throw AssistantError.api("The response was cut off before a file change finished. Try asking for a smaller change.")
            default:
                return
            }

            var results: [[String: Any]] = []
            let calls = turn.content.filter { $0["type"] as? String == "tool_use" }
            let itemIDs = toolItems.keys.sorted().compactMap { toolItems[$0] }
            for (offset, call) in calls.enumerated() {
                try Task.checkCancellation()
                let id = call["id"] as? String ?? ""
                let name = call["name"] as? String ?? ""
                let input = call["input"] as? [String: Any] ?? [:]
                let itemID = offset < itemIDs.count ? itemIDs[offset] : nil
                if let itemID { update(itemID) { $0.text = AgentTools.describe(name, input) } }
                let outcome: ToolOutcome
                if let raw = call[ClaudeAgent.invalidInputKey] as? String {
                    outcome = .failure("The tool input was not valid JSON, so nothing ran. Received: \(raw.prefix(2000))",
                                       summary: "Invalid tool input")
                } else {
                    outcome = await tools.run(name, input: input)
                }
                if let itemID {
                    update(itemID) {
                        $0.text = outcome.summary
                        $0.status = outcome.isError ? .failed : .done
                        $0.url = outcome.url
                    }
                }
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": outcome.content]
                if outcome.isError { result["is_error"] = true }
                results.append(result)
            }
            history.append(["role": "user", "content": results])
        }
        throw AssistantError.api("Stopped after many steps. Ask again to continue.")
    }

    private static func pendingLabel(_ name: String) -> String {
        AgentTools.describe(name, [:]).replacingOccurrences(of: " .", with: "…")
    }

    /// The per-turn context block, plus the article or note text when it is
    /// new to the conversation or has changed since it was last sent.
    private func contextText(_ context: AgentContext) -> String {
        let tools = AgentTools(root: context.workingDirectory, openFile: nil) { _ in }
        var lines = ["<context>", "Working directory: \(context.workingDirectory.path)"]
        switch context.kind {
        case .article:
            lines.append("Open tab: the Wikipedia article “\(context.title)” (\(context.articleURL?.absoluteString ?? ""))")
        case .note:
            let path = context.fileURL.map(tools.display) ?? "an unsaved note"
            lines.append("Open tab: the Markdown note “\(context.title)” at \(path)")
            if context.fileURL == nil {
                lines.append("(It has no file yet; you can't edit it with tools. Offer to save a copy if useful.)")
            }
        case .image:
            lines.append("Open tab: the image \(context.fileURL.map(tools.display) ?? context.title) (attached)")
        case .folder:
            lines.append("Open tab: the image gallery of \(context.fileURL.map(tools.display) ?? context.title)")
        case .home, .other:
            lines.append("Open tab: \(context.title) (nothing is open)")
        }
        lines.append("</context>")
        var text = lines.joined(separator: "\n")
        if let body = context.text, !body.isEmpty {
            let key = Self.key(for: context)
            let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            if sentDigests[key] != digest {
                sentDigests[key] = digest
                switch context.kind {
                case .article:
                    text += "\n\n<article title=\"\(context.title)\">\n\(body)\n</article>"
                default:
                    text += "\n\n<note title=\"\(context.title)\">\n\(body)\n</note>"
                }
            } else {
                text += "\n(The open tab's text is unchanged since you last saw it.)"
            }
        }
        return text
    }

    private static func key(for context: AgentContext) -> String {
        context.fileURL?.path ?? context.articleURL?.absoluteString ?? "\(context.kind)-\(context.title)"
    }

    // MARK: Claude Code and Codex

    /// The open file's folder, when it lies outside the working directory.
    private static func extraDirectory(_ context: AgentContext) -> URL? {
        guard let file = context.fileURL, context.kind == .note || context.kind == .image else { return nil }
        let folder = file.deletingLastPathComponent().standardizedFileURL
        return folder.path.hasPrefix(context.workingDirectory.standardizedFileURL.path) ? nil : folder
    }

    private func runCLI(question: String, context: AgentContext,
                        run: (String, String?, @MainActor (AgentStreamEvent) -> Void) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: context.workingDirectory, withIntermediateDirectories: true)
        let prompt = cliContextText(context) + "\n\n" + question
        var textItems: [String: UUID] = [:]
        var toolItems: [String: UUID] = [:]
        var failure: String?
        try await run(prompt, cliSessionID) { [weak self] event in
            guard let self else { return }
            switch event {
            case .session(let id):
                cliSessionID = id
            case .text(let key, let delta):
                if let id = textItems[key] {
                    update(id) { $0.text += delta }
                } else {
                    let item = Item(kind: .assistant, text: delta)
                    textItems[key] = item.id
                    items.append(item)
                }
            case .fullText(let key, let text):
                if let id = textItems[key] {
                    update(id) { $0.text = text }
                } else {
                    let item = Item(kind: .assistant, text: text)
                    textItems[key] = item.id
                    items.append(item)
                }
            case .toolStarted(let key, let label):
                guard toolItems[key] == nil else { return }
                let item = Item(kind: .tool, text: label, status: .running)
                toolItems[key] = item.id
                items.append(item)
            case .toolUpdated(let key, let label, let url):
                if let id = toolItems[key] { update(id) { $0.text = label; $0.url = url ?? $0.url } }
            case .toolFinished(let key, let failed, let changedFiles):
                if let id = toolItems[key] {
                    update(id) {
                        $0.status = failed ? .failed : .done
                        $0.text = Self.pastTense($0.text)
                        if failed { $0.url = nil }
                    }
                }
                // The CLI wrote files itself: refresh open notes and the sidebar.
                if changedFiles { NotificationCenter.default.post(name: .agentDidModifyFiles, object: nil, userInfo: [:]) }
            case .failure(let message):
                failure = message
            }
        }
        NotificationCenter.default.post(name: .agentDidModifyFiles, object: nil, userInfo: [:])
        if let failure { throw AssistantError.api(failure) }
    }

    private static func pastTense(_ label: String) -> String {
        for (present, past) in [("Reading ", "Read "), ("Writing ", "Wrote "), ("Editing ", "Edited "), ("Running ", "Ran "),
                                ("Finding ", "Found "), ("Searching ", "Searched "), ("Fetching ", "Fetched "),
                                ("Updating ", "Updated "), ("Using ", "Used ")] where label.hasPrefix(present) {
            return past + label.dropFirst(present.count)
        }
        return label
    }

    /// The context block for a CLI turn. The CLIs read notes and images
    /// themselves; article text is included when new or changed.
    private func cliContextText(_ context: AgentContext) -> String {
        var lines = ["<context>", "Working directory: \(context.workingDirectory.path)"]
        switch context.kind {
        case .article:
            lines.append("Open tab: the Wikipedia article “\(context.title)” (\(context.articleURL?.absoluteString ?? ""))")
        case .note:
            if let url = context.fileURL {
                lines.append("Open tab: the Markdown note \(url.path) (saved; read it for its current text)")
            } else {
                lines.append("Open tab: an unsaved, untitled note (its text is below; it has no file yet)")
            }
        case .image:
            lines.append("Open tab: the image \(context.fileURL?.path ?? context.title)" + (backend.isCodex ? " (attached)" : " (read it to see it)"))
        case .folder:
            lines.append("Open tab: the image gallery of \(context.fileURL?.path ?? context.title)")
        case .home, .other:
            lines.append("Open tab: \(context.title) (nothing is open)")
        }
        if backend.isCodex && cliSessionID == nil {
            lines.append("")
            lines.append(AgentCLIPrompt.instructions)
        }
        lines.append("</context>")
        var text = lines.joined(separator: "\n")
        let body = context.kind == .article || (context.kind == .note && context.fileURL == nil) ? context.text : nil
        if let body, !body.isEmpty {
            let key = Self.key(for: context)
            let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
            if sentDigests[key] != digest {
                sentDigests[key] = digest
                text += "\n\n<\(context.kind == .article ? "article" : "note") title=\"\(context.title)\">\n\(body)\n</\(context.kind == .article ? "article" : "note")>"
            }
        }
        return text
    }

    // MARK: Apple Intelligence

    private func runApple(question: String, context: AgentContext) async throws {
        let turns = items.dropLast().compactMap { item -> ChatTurn? in
            switch item.kind {
            case .user: return ChatTurn(role: .user, text: item.text)
            case .assistant: return ChatTurn(role: .assistant, text: item.text)
            default: return nil
            }
        }
        let reply = Item(kind: .assistant, text: "")
        items.append(reply)
        let source = (context.text ?? "") .isEmpty ? "The reader has \(context.title) open." : context.text!
        for try await text in AppleAssistant.stream(context: source, history: Array(turns), question: question) {
            update(reply.id) { $0.text = text }
        }
        items.removeAll { $0.id == reply.id && $0.text.isEmpty }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
