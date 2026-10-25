import Foundation
import Security
import FoundationModels

enum AssistantError: LocalizedError {
    case needsSetup
    case invalidKey
    case rateLimited
    case overloaded
    case refused
    case api(String)
    case appleUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .needsSetup: "Add an Anthropic API key in Settings (⌘,), or pick Claude or Codex in the model menu."
        case .invalidKey: "That Anthropic API key was rejected. Check it in Settings."
        case .rateLimited: "Claude is rate-limiting requests right now. Try again in a moment."
        case .overloaded: "Claude is busy right now. Try again in a moment."
        case .refused: "Claude declined to answer that."
        case .api(let message): message
        case .appleUnavailable(let reason): reason
        }
    }
}

struct ChatTurn: Sendable {
    enum Role: String, Sendable { case user, assistant }
    var role: Role
    var text: String
}

// MARK: - API key

enum APIKeyStore {
    // Shared with Encyclopedia, so a key saved there works here too.
    private static let service = "com.grant.encyclopedia"
    private static let account = "anthropic-api-key"

    static var key: String? {
        if let stored = read(), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    /// Whether a key is configured, without reading the secret itself: an
    /// attributes-only query never triggers a Keychain access prompt.
    static var isConfigured: Bool {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return true }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String?) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var item = base
        item[kSecValueData] = Data(value.utf8)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - Apple Intelligence

enum AppleAssistant {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device doesn’t support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use the on-device assistant."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again soon."
        case .unavailable: return "Apple Intelligence isn’t available right now."
        }
    }

    /// The on-device model has a small context window, so it gets the lead
    /// plus the passages most relevant to the question.
    static func stream(context: String, history: [ChatTurn], question: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var budget = 6000
                while true {
                    do {
                        let excerpt = Self.excerpt(of: context, for: question + " " + (history.last(where: { $0.role == .user })?.text ?? ""), budget: budget)
                        let session = LanguageModelSession(instructions: AgentPrompt.appleInstructions + "\n\nExcerpt of what the reader has open:\n" + excerpt)
                        var prompt = ""
                        for turn in history.suffix(4) {
                            prompt += (turn.role == .user ? "Reader: " : "You: ") + String(turn.text.prefix(600)) + "\n"
                        }
                        prompt += (prompt.isEmpty ? "" : "\nNow answer this. ") + "Reader: " + question
                        for try await snapshot in session.streamResponse(to: prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                        return
                    } catch let error as LanguageModelSession.GenerationError {
                        if case .exceededContextWindowSize = error, budget > 1500 {
                            budget /= 2
                            continue
                        }
                        continuation.finish(throwing: AssistantError.api(error.localizedDescription))
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "which", "who", "whom", "why", "how",
        "did", "does", "this", "that", "with", "about", "from", "into", "his", "her", "their", "its", "they",
        "them", "has", "have", "had", "can", "could", "would", "should", "tell", "explain", "article", "you",
    ]

    static func excerpt(of text: String, for question: String, budget: Int) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let terms = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
        var chosen = Set<Int>()
        var used = 0
        // Always the opening: title, description, and the lead.
        for index in paragraphs.indices.prefix(4) where used + paragraphs[index].count <= budget / 2 {
            chosen.insert(index)
            used += paragraphs[index].count
        }
        let ranked = paragraphs.indices
            .map { index -> (Int, Int) in
                let words = paragraphs[index].lowercased().split { !$0.isLetter && !$0.isNumber }
                return (index, words.reduce(0) { $0 + (terms.contains(String($1)) ? 1 : 0) })
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        for (index, _) in ranked where !chosen.contains(index) {
            let length = min(paragraphs[index].count, 1200)
            guard used + length <= budget else { continue }
            chosen.insert(index)
            used += length
        }
        return chosen.sorted().map { String(paragraphs[$0].prefix(1200)) }.joined(separator: "\n\n")
    }
}
