import Foundation

/// What a CLI run reports to the conversation, already mapped from its
/// own event format. Keys tie updates to the item they started.
enum AgentStreamEvent {
    case session(String)
    case text(key: String, delta: String)
    /// Codex reports whole messages rather than deltas.
    case fullText(key: String, text: String)
    case toolStarted(key: String, label: String)
    case toolUpdated(key: String, label: String, url: URL?)
    case toolFinished(key: String, failed: Bool, changedFiles: Bool)
    case failure(String)
}

/// Shared instructions for the subscription CLIs.
enum AgentCLIPrompt {
    static let instructions = """
    You are the assistant in the sidebar of Catalog, a Mac app for browsing, reading, and writing creative and research work: Wikipedia, Markdown notes, and images. \
    Each user message starts with a <context> block naming the tab the user has open and the working directory.
    - Questions about "this", "the article", or "the note" mean the open tab. Ground answers in it.
    - When asked to write, save, or change notes, edit the files directly; the user sees changes appear live in \
    their tabs. New notes are Markdown (.md) files with short descriptive names. Don't delete files unless asked.
    - Keep chat replies brief, in light Markdown: **bold**, *italics*, `code`, and "- " bullets. No headings or tables.
    - Link Wikipedia articles as [Name](encyclopedia://wiki/Exact_Article_Title) (underscores for spaces) so they open in Catalog.
    """
}

// MARK: - Claude Code

/// Runs Claude Code headless (`claude -p … --output-format stream-json`),
/// signed in with the user's Claude subscription.
enum ClaudeCodeRunner {
    static func run(prompt: String, model: String, sessionID: String?, directory: URL, extraDirectory: URL?,
                    onEvent: @MainActor (AgentStreamEvent) -> Void) async throws {
        guard let claude = ShellEnvironment.executable("claude") else {
            throw AssistantError.api("Claude Code isn’t installed. Install it, then sign in from the model menu.")
        }
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", "acceptEdits", "--model", model,
                         "--append-system-prompt", AgentCLIPrompt.instructions]
        if let sessionID { arguments += ["--resume", sessionID] }
        if let extraDirectory { arguments += ["--add-dir", extraDirectory.path] }
        // An API key in the environment would bill the API instead of the subscription.
        let process = CLIProcess(claude, arguments, directory: directory, input: prompt, removing: ["ANTHROPIC_API_KEY"])
        var tools: [String: (name: String, input: [String: Any])] = [:]
        var streamedMessages = Set<String>()
        var currentMessage = ""
        var gotResult = false
        do {
            for try await line in try process.lines() {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // Subagents' own traffic stays out of the transcript.
                if event["parent_tool_use_id"] is String { continue }
                switch event["type"] as? String {
                case "system":
                    if let id = event["session_id"] as? String, event["subtype"] as? String == "init" { await onEvent(.session(id)) }
                case "stream_event":
                    guard let inner = event["event"] as? [String: Any] else { continue }
                    switch inner["type"] as? String {
                    case "message_start":
                        currentMessage = (inner["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
                    case "content_block_start":
                        let block = inner["content_block"] as? [String: Any] ?? [:]
                        let index = inner["index"] as? Int ?? 0
                        if block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                            tools[id] = (name, [:])
                            await onEvent(.toolStarted(key: id, label: ClaudeCodeTools.label(name, [:], directory: directory)))
                        } else if block["type"] as? String == "text" {
                            streamedMessages.insert(currentMessage)
                            _ = index
                        }
                    case "content_block_delta":
                        let delta = inner["delta"] as? [String: Any] ?? [:]
                        if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                            await onEvent(.text(key: "\(currentMessage)-\(inner["index"] as? Int ?? 0)", delta: text))
                        }
                    default:
                        break
                    }
                case "assistant":
                    // Complete messages: tool inputs, and text if it wasn't streamed.
                    guard let message = event["message"] as? [String: Any],
                          let content = message["content"] as? [[String: Any]] else { continue }
                    let messageID = message["id"] as? String ?? UUID().uuidString
                    for (index, block) in content.enumerated() {
                        switch block["type"] as? String {
                        case "tool_use":
                            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                            let input = block["input"] as? [String: Any] ?? [:]
                            if tools[id] == nil { await onEvent(.toolStarted(key: id, label: ClaudeCodeTools.label(name, input, directory: directory))) }
                            tools[id] = (name, input)
                            await onEvent(.toolUpdated(key: id, label: ClaudeCodeTools.label(name, input, directory: directory),
                                                       url: ClaudeCodeTools.file(name, input, directory: directory)))
                        case "text":
                            if !streamedMessages.contains(messageID), let text = block["text"] as? String {
                                await onEvent(.fullText(key: "\(messageID)-\(index)", text: text))
                            }
                        default:
                            break
                        }
                    }
                case "user":
                    guard let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                    for block in content where block["type"] as? String == "tool_result" {
                        guard let id = block["tool_use_id"] as? String else { continue }
                        let name = tools[id]?.name ?? ""
                        await onEvent(.toolFinished(key: id, failed: block["is_error"] as? Bool == true,
                                                    changedFiles: ClaudeCodeTools.mayChangeFiles(name)))
                    }
                case "result":
                    gotResult = true
                    if let id = event["session_id"] as? String { await onEvent(.session(id)) }
                    if event["is_error"] as? Bool == true || (event["subtype"] as? String ?? "success") != "success" {
                        let message = event["result"] as? String ?? (event["errors"] as? [String])?.joined(separator: "\n")
                        await onEvent(.failure(message ?? "Claude Code stopped with an error."))
                    }
                default:
                    break
                }
            }
        } catch {
            process.terminate()
            throw error
        }
        let status = await process.exitStatus()
        if !gotResult, status != 0, !Task.isCancelled {
            throw AssistantError.api(Self.explain(process.errorOutput, status: status))
        }
    }

    private static func explain(_ stderr: String, status: Int32) -> String {
        if stderr.localizedCaseInsensitiveContains("login") || stderr.localizedCaseInsensitiveContains("auth") {
            return "Claude Code isn’t signed in. Choose Sign In to Claude… from the model menu."
        }
        return stderr.isEmpty ? "Claude Code exited with status \(status)." : String(stderr.suffix(600))
    }
}

/// How Claude Code's tools read in the transcript.
enum ClaudeCodeTools {
    static func label(_ name: String, _ input: [String: Any], directory: URL) -> String {
        let path = (input["file_path"] as? String ?? input["path"] as? String ?? input["notebook_path"] as? String)
            .map { AgentCLIPaths.display($0, root: directory) }
        switch name {
        case "Read": return "Reading " + (path ?? "a file")
        case "Write": return "Writing " + (path ?? "a file")
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing " + (path ?? "a file")
        case "Bash": return "Running " + AgentCLIPaths.command(input["command"] as? String ?? "a command")
        case "Glob": return "Finding " + (input["pattern"] as? String ?? "files")
        case "Grep": return "Searching for “\(input["pattern"] as? String ?? "")”"
        case "WebFetch": return "Fetching " + ((input["url"] as? String).flatMap { URL(string: $0)?.host() } ?? "a page")
        case "WebSearch": return "Searching the web for “\(input["query"] as? String ?? "")”"
        case "TodoWrite": return "Updating the plan"
        case "Task", "Agent": return "Running a subagent"
        default: return name
        }
    }

    static func file(_ name: String, _ input: [String: Any], directory: URL) -> URL? {
        guard ["Read", "Write", "Edit", "MultiEdit"].contains(name), let path = input["file_path"] as? String else { return nil }
        return AgentCLIPaths.url(path, root: directory)
    }

    static func mayChangeFiles(_ name: String) -> Bool {
        ["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash", "Task", "Agent"].contains(name)
    }
}

// MARK: - Codex

/// Runs Codex headless (`codex exec --json`), signed in with the user's
/// ChatGPT subscription, sandboxed to the working directory.
enum CodexRunner {
    static func run(prompt: String, model: String, sessionID: String?, directory: URL, extraDirectory: URL?,
                    images: [URL], onEvent: @MainActor (AgentStreamEvent) -> Void) async throws {
        guard let codex = ShellEnvironment.executable("codex") else {
            throw AssistantError.api("Codex isn’t installed. Install it, then sign in from the model menu.")
        }
        var arguments = ["exec"]
        if let sessionID {
            // `resume` takes no --sandbox or --cd; the config override and
            // the process's directory stand in for them.
            arguments += ["resume", sessionID, "-c", "sandbox_mode=\"workspace-write\""]
        } else {
            arguments += ["--sandbox", "workspace-write", "--cd", directory.path]
            if let extraDirectory { arguments += ["--add-dir", extraDirectory.path] }
        }
        arguments += ["--json", "--skip-git-repo-check", "-m", model]
        for image in images { arguments += ["-i", image.path] }
        arguments.append("-")
        let process = CLIProcess(codex, arguments, directory: directory, input: prompt)
        var failed = false
        do {
            for try await line in try process.lines() {
                try Task.checkCancellation()
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "thread.started":
                    if let id = event["thread_id"] as? String { await onEvent(.session(id)) }
                case "item.started", "item.updated", "item.completed":
                    guard let item = event["item"] as? [String: Any], let id = item["id"] as? String else { continue }
                    await handle(item: item, id: id, completed: event["type"] as? String == "item.completed",
                                 directory: directory, onEvent: onEvent)
                case "turn.failed", "error":
                    let raw = (event["error"] as? [String: Any])?["message"] as? String ?? event["message"] as? String ?? "Codex ran into an error."
                    if !failed { await onEvent(.failure(explain(raw))) }
                    failed = true
                default:
                    break
                }
            }
        } catch {
            process.terminate()
            throw error
        }
        let status = await process.exitStatus()
        if status != 0, !failed, !Task.isCancelled {
            let stderr = process.errorOutput
            throw AssistantError.api(stderr.localizedCaseInsensitiveContains("login")
                ? "Codex isn’t signed in. Choose Sign In to Codex… from the model menu."
                : (stderr.isEmpty ? "Codex exited with status \(status)." : String(stderr.suffix(600))))
        }
    }

    @MainActor
    private static func handle(item: [String: Any], id: String, completed: Bool, directory: URL,
                               onEvent: @MainActor (AgentStreamEvent) -> Void) {
        switch item["type"] as? String {
        case "agent_message":
            if let text = item["text"] as? String, !text.isEmpty { onEvent(.fullText(key: id, text: text)) }
        case "command_execution":
            let label = "Running " + AgentCLIPaths.command(AgentCLIPaths.unwrapShell(item["command"] as? String ?? ""))
            if completed {
                onEvent(.toolStarted(key: id, label: label))
                let exit = item["exit_code"] as? Int ?? 0
                onEvent(.toolFinished(key: id, failed: exit != 0 || item["status"] as? String == "failed", changedFiles: true))
            } else {
                onEvent(.toolStarted(key: id, label: label))
            }
        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let label = "Editing " + (paths.isEmpty ? "files" : paths.map { AgentCLIPaths.display($0, root: directory) }.joined(separator: ", "))
            onEvent(.toolStarted(key: id, label: label))
            onEvent(.toolUpdated(key: id, label: label, url: paths.first.flatMap { AgentCLIPaths.url($0, root: directory) }))
            if completed { onEvent(.toolFinished(key: id, failed: item["status"] as? String == "failed", changedFiles: true)) }
        case "web_search":
            let label = "Searching the web for “\(item["query"] as? String ?? "")”"
            onEvent(.toolStarted(key: id, label: label))
            if completed { onEvent(.toolFinished(key: id, failed: false, changedFiles: false)) }
        case "mcp_tool_call":
            let label = "Using \(item["server"] as? String ?? "a tool") · \(item["tool"] as? String ?? "")"
            onEvent(.toolStarted(key: id, label: label))
            if completed { onEvent(.toolFinished(key: id, failed: item["status"] as? String == "failed", changedFiles: true)) }
        default:
            // Reasoning, plans, and configuration warnings stay out of the transcript.
            break
        }
    }

    private static func explain(_ raw: String) -> String {
        // API errors arrive as JSON inside the message.
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String {
            return message
        }
        return raw
    }
}

enum AgentCLIPaths {
    static func url(_ path: String, root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    static func display(_ path: String, root: URL) -> String {
        let full = url(path, root: root).standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
        // Outside the working directory: the file and its folder are enough.
        let components = URL(fileURLWithPath: full).pathComponents
        return components.count > 2 ? "…/" + components.suffix(2).joined(separator: "/") : full
    }

    static func command(_ command: String) -> String {
        let line = command.split(separator: "\n").first.map(String.init) ?? command
        return "`" + (line.count > 60 ? String(line.prefix(60)) + "…" : line) + "`"
    }

    /// `/bin/zsh -lc "printf …"` → `printf …`
    static func unwrapShell(_ command: String) -> String {
        guard let match = command.range(of: #"^/bin/\w+ -l?c (["'])(.*)\1$"#, options: .regularExpression) else { return command }
        let inner = command[match]
        guard let quote = inner.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return command }
        return String(inner[inner.index(after: quote)..<inner.index(before: inner.endIndex)])
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}
