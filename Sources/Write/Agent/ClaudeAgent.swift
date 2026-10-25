import Foundation

enum AgentPrompt {
    /// Static, so it caches: everything that varies (the open tab, the
    /// working directory) arrives in each user turn's <context> block.
    static let system = """
    You are the assistant inside Write, a Mac app for reading Wikipedia and writing Markdown notes. You sit in a \
    sidebar beside whatever the user has open: a Wikipedia article, a Markdown note, an image, or a folder.

    Each user message starts with a <context> block naming the open tab and the working directory. The article's or \
    note's full text follows it whenever it is new to this conversation or has changed; otherwise rely on the copy \
    you already have. An open image is attached to the message.

    You can list, read, search, create, edit, and move files in the working directory with your tools. Paths are \
    relative to it. You cannot delete files.

    - Answer questions about the open article or note directly, grounded in its text. If you add knowledge it \
    doesn't contain, say so briefly; if it doesn't cover something, say that plainly rather than guessing.
    - When the user asks you to write, save, or change notes, do it with your tools instead of pasting the content \
    into the chat. Use edit_file for targeted changes to existing files, and read a file before editing it unless \
    its current text is already in the conversation. New notes are Markdown files (.md) with a short, descriptive \
    file name; match the style and conventions of nearby notes. The user sees file changes appear live in their tabs.
    - When "the note" or "this" is ambiguous, it means the open tab.
    - After changing files, reply with one or two sentences on what you changed and where. Don't restate the content.
    - Write chat replies in light Markdown only: **bold**, *italics*, `code`, and simple "- " bullets. No headings, \
    tables, or code fences in chat (notes you write may use full Markdown).
    - When you mention a person, place, event, or idea that has its own Wikipedia article, you may link it as \
    [Name](encyclopedia://wiki/Exact_Article_Title), with underscores for spaces, so the user can open it.
    - Be concise unless the user asks for depth.
    """

    static let appleInstructions = """
    You are the research assistant inside Write, a reader and notes app. The reader asks about the article or note \
    excerpted below. Ground your answers in it; if it doesn't cover something, say so plainly. Be concise: a short \
    paragraph or a few "- " bullets, with **bold** and *italics* only. You can't create or edit files.
    """
}

/// Raw-HTTP streaming client for the Messages API: there is no official
/// Swift SDK, so this speaks SSE directly.
enum ClaudeAgent {
    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    enum Event {
        case blockStarted(index: Int, type: String, name: String?)
        case textDelta(index: Int, text: String)
    }

    struct Turn {
        /// The assistant content to append to history, unchanged except where
        /// a mid-stream fallback requires dropping blocks before its marker.
        var content: [[String: Any]]
        var stopReason: String?
    }

    /// Streams one response. History is append-only: the returned blocks
    /// (thinking with signatures included) are echoed back verbatim next turn.
    @MainActor
    static func turn(apiKey: String, messages: [[String: Any]], tools: [[String: Any]],
                     onEvent: (Event) -> Void) async throws -> Turn {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
            "system": [["type": "text", "text": AgentPrompt.system]],
            "tools": tools,
            "messages": messages,
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantError.api("No response from Claude.") }
        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw error(status: http.statusCode, body: data)
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let index = event["index"] as? Int ?? 0
            switch type {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any], let blockType = block["type"] as? String else { continue }
                blocks[index] = block
                if blockType == "tool_use" { partialJSON[index] = "" }
                onEvent(.blockStarted(index: index, type: blockType, name: block["name"] as? String))
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], var block = blocks[index] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + piece
                    onEvent(.textDelta(index: index, text: piece))
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    break
                default:
                    break
                }
                blocks[index] = block
            case "content_block_stop":
                // Eager input streaming skips server-side validation: parse
                // strictly here; the session validates fields before running.
                if var block = blocks[index], block["type"] as? String == "tool_use" {
                    let raw = partialJSON[index] ?? ""
                    if raw.isEmpty {
                        block["input"] = [String: Any]()
                    } else if let data = raw.data(using: .utf8),
                              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        block["input"] = input
                    } else {
                        block["input"] = [String: Any]()
                        block[invalidInputKey] = raw
                    }
                    blocks[index] = block
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "error":
                let info = event["error"] as? [String: Any]
                if info?["type"] as? String == "overloaded_error" { throw AssistantError.overloaded }
                throw AssistantError.api(info?["message"] as? String ?? "Claude ran into an error.")
            default:
                break
            }
        }

        var content = blocks.keys.sorted().compactMap { blocks[$0] }
        // After a mid-output fallback, blocks before the last marker other
        // than text can't be echoed back.
        if let boundary = content.lastIndex(where: { $0["type"] as? String == "fallback" }) {
            content = content.enumerated().compactMap { offset, block in
                guard offset < boundary else { return block }
                return block["type"] as? String == "text" ? block : nil
            }
        }
        // The API rejects empty text blocks in requests.
        content.removeAll { $0["type"] as? String == "text" && ($0["text"] as? String ?? "").isEmpty }
        return Turn(content: content, stopReason: stopReason)
    }

    /// Marks a tool_use whose streamed input wasn't valid JSON (stripped
    /// before the block is echoed back).
    static let invalidInputKey = "_write_invalid_input"

    private static func error(status: Int, body: Data) -> AssistantError {
        let message = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401, 403: return .invalidKey
        case 429: return .rateLimited
        case 529, 503: return .overloaded
        default: return .api(message ?? "Claude returned an error (\(status)).")
        }
    }
}
