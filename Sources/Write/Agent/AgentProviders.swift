import Foundation
import AppKit

/// Which model answers in the assistant sidebar. Claude Code and Codex run
/// the user's own CLIs, signed in with their Claude or ChatGPT subscription;
/// Write never sees those credentials.
enum AgentBackend: Hashable {
    case claudeCode(model: String)
    case codex(model: String)
    /// The Messages API with an Anthropic API key from Settings.
    case claudeAPI
    case apple

    static let claudeCodeModels: [(id: String, label: String)] = [("opus", "Opus"), ("sonnet", "Sonnet")]

    @MainActor var label: String {
        switch self {
        case .claudeCode(let model):
            return "Claude · " + (Self.claudeCodeModels.first { $0.id == model }?.label ?? model)
        case .codex(let model): return "Codex · " + AgentAccounts.displayName(forCodexModel: model)
        case .claudeAPI: return "Claude API · Opus 5.5"
        case .apple: return "Apple Intelligence"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode, .claudeAPI: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .apple: return "apple.intelligence"
        }
    }

    var canEditFiles: Bool { self != .apple }
    var isCodex: Bool { if case .codex = self { return true } else { return false } }

    // Persisted as "claude-code:opus", "codex:<model>", "claude-api", "apple".
    var storageValue: String {
        switch self {
        case .claudeCode(let model): return "claude-code:" + model
        case .codex(let model): return "codex:" + model
        case .claudeAPI: return "claude-api"
        case .apple: return "apple"
        }
    }

    init?(storageValue: String) {
        if storageValue.hasPrefix("claude-code:") { self = .claudeCode(model: String(storageValue.dropFirst(12))) }
        else if storageValue.hasPrefix("codex:") { self = .codex(model: String(storageValue.dropFirst(6))) }
        else if storageValue == "claude-api" { self = .claudeAPI }
        else if storageValue == "apple" { self = .apple }
        else { return nil }
    }

    private static let key = "assistantBackend"

    /// Whether the user has picked a model (otherwise the best available is used).
    @MainActor static var hasChoice: Bool { AppState.defaults.string(forKey: key) != nil }

    /// The last choice, or the best available: Claude, Codex, an API key,
    /// then Apple Intelligence.
    @MainActor static var preferred: AgentBackend {
        get {
            if let stored = AppState.defaults.string(forKey: key), let backend = AgentBackend(storageValue: stored) {
                return backend
            }
            let accounts = AgentAccounts.shared
            if accounts.claude.isReady { return .claudeCode(model: "opus") }
            if accounts.codex.isReady, let model = accounts.codexDefaultModel { return .codex(model: model) }
            if APIKeyStore.isConfigured { return .claudeAPI }
            return .apple
        }
        set { AppState.defaults.set(newValue.storageValue, forKey: key) }
    }
}

/// The user's shell environment. Apps launched from the Dock don't inherit
/// the PATH of a login shell, where npm, Homebrew, and nvm install CLIs.
enum ShellEnvironment {
    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        var paths = loginShellPath()?.split(separator: ":").map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var extras = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                      "\(home)/.bun/bin", "\(home)/.volta/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            extras += versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        paths += extras + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }()

    static func executable(_ name: String) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '__WRITE_PATH__%s__END__' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__WRITE_PATH__"), let end = text.range(of: "__END__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}

/// Whether Claude Code and Codex are installed and signed in, and which
/// Codex models the account offers. Shared by every window.
@MainActor @Observable
final class AgentAccounts {
    static let shared = AgentAccounts()
    static let didChange = Notification.Name("WriteAgentAccountsDidChange")

    enum Status: Equatable {
        case checking
        case notInstalled
        case signedOut
        case ready(String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    private(set) var claude: Status = .checking
    private(set) var codex: Status = .checking
    private(set) var codexModels: [(id: String, name: String)] = []
    private(set) var codexConfiguredModel: String?
    private var refreshing = false

    var codexDefaultModel: String? {
        if let configured = codexConfiguredModel, codexModels.contains(where: { $0.id == configured }) { return configured }
        return codexModels.first?.id
    }

    static func displayName(forCodexModel id: String) -> String {
        shared.codexModels.first { $0.id == id }?.name ?? id
    }

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Back from signing in in Terminal or a browser.
            MainActor.assumeIsolated { AgentAccounts.shared.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let claude = Self.checkClaude()
            let (codex, models, configured) = Self.checkCodex()
            await MainActor.run {
                let accounts = AgentAccounts.shared
                accounts.claude = claude
                accounts.codex = codex
                if !models.isEmpty { accounts.codexModels = models }
                accounts.codexConfiguredModel = configured
                accounts.refreshing = false
                NotificationCenter.default.post(name: AgentAccounts.didChange, object: nil)
            }
        }
    }

    nonisolated private static func checkClaude() -> Status {
        guard let claude = ShellEnvironment.executable("claude") else { return .notInstalled }
        guard let output = CLIProcess.capture(claude, ["auth", "status"]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return .signedOut }
        guard json["loggedIn"] as? Bool == true else { return .signedOut }
        let method = json["authMethod"] as? String ?? ""
        return .ready(method == "claude.ai" ? "Claude subscription" : method)
    }

    nonisolated private static func checkCodex() -> (Status, [(id: String, name: String)], String?) {
        guard let codex = ShellEnvironment.executable("codex") else { return (.notInstalled, [], nil) }
        let status: Status
        if let output = CLIProcess.capture(codex, ["login", "status"], includingErrors: true), output.localizedCaseInsensitiveContains("logged in") {
            status = .ready(output.localizedCaseInsensitiveContains("chatgpt") ? "ChatGPT subscription" : "API key")
        } else {
            status = .signedOut
        }
        var models: [(String, String)] = []
        if let output = CLIProcess.capture(codex, ["debug", "models"]),
           let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
           let list = (json as? [String: Any])?["models"] as? [[String: Any]] ?? json as? [[String: Any]] {
            models = list.compactMap { model in
                guard let slug = model["slug"] as? String ?? model["id"] as? String,
                      (model["visibility"] as? String ?? "list") == "list" else { return nil }
                return (slug, model["display_name"] as? String ?? slug)
            }
        }
        // The user's configured default, from ~/.codex/config.toml.
        let config = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        let configured = config.split(separator: "\n").first { $0.hasPrefix("model ") || $0.hasPrefix("model=") }
            .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        return (status, models, configured)
    }

    /// Signs in through the CLI's own flow, in Terminal (both open a
    /// browser to sign in with the subscription account).
    func signIn(claude: Bool) {
        let command = claude ? "claude auth login" : "codex login"
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Write Sign In.command")
        let body = """
        #!/bin/zsh -il
        echo "Signing in to \(claude ? "Claude" : "Codex") for Write…"
        \(command)
        echo
        echo "Done. You can close this window and return to Write."
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }

    static func installPage(claude: Bool) -> URL {
        URL(string: claude ? "https://claude.com/product/claude-code" : "https://developers.openai.com/codex/cli")!
    }
}

/// A CLI run whose stdout is read line by line as it arrives.
final class CLIProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var errorData = Data()
    private let lock = NSLock()

    init(_ executable: URL, _ arguments: [String], directory: URL?, input: String?, removing removedVariables: [String] = []) {
        process.executableURL = executable
        process.arguments = arguments
        var environment = ShellEnvironment.environment
        removedVariables.forEach { environment[$0] = nil }
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        process.standardOutput = stdout
        process.standardError = stderr
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            DispatchQueue.global().async {
                pipe.fileHandleForWriting.write(Data(input.utf8))
                try? pipe.fileHandleForWriting.close()
            }
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock(); self.errorData.append(data); self.lock.unlock()
        }
    }

    /// Lines of stdout until the process exits.
    func lines() throws -> AsyncThrowingStream<String, Error> {
        try process.run()
        let handle = stdout.fileHandleForReading
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for try await line in handle.bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                if self?.process.isRunning == true { self?.process.terminate() }
            }
        }
    }

    func terminate() { if process.isRunning { process.terminate() } }

    /// The exit status, once stdout has closed.
    func exitStatus() async -> Int32 {
        await Task.detached { [process] in
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    var errorOutput: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a short command and returns its stdout (nil on failure).
    static func capture(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 15,
                        includingErrors: Bool = false) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ShellEnvironment.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = includingErrors ? output : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "write.capture")
        let group = DispatchGroup()
        group.enter()
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return nil }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
