import Foundation
import MoonletIPC
import MoonletSetup

/// `moonlet doctor [--settings PATH] [--config PATH]`: checks the app, both integrations,
/// and Ollama. Exits 1 if a required check fails; Ollama is optional.
enum DoctorCommand {
    private enum Outcome {
        case pass, fail, skip

        var symbol: String {
            switch self {
            case .pass: "✓"
            case .fail: "✗"
            case .skip: "-"
            }
        }
    }

    static func run(_ arguments: [String], paths: MoonletPaths, environment: [String: String]) async throws -> Int32 {
        var arguments = Arguments(arguments)
        let settings = try arguments.option("--settings").map(Locations.url(forUserPath:))
            ?? Locations.claudeSettings(environment: environment)
        let config = try arguments.option("--config").map(Locations.url(forUserPath:))
            ?? Locations.codexConfig(environment: environment)
        try arguments.finish()

        let checks = [
            checkApp(paths: paths),
            checkClaudeCode(settings: settings, environment: environment),
            checkCodex(config: config),
            await checkOllama(),
        ]
        for (outcome, message) in checks {
            print("\(outcome.symbol) \(message)")
        }
        return checks.contains { $0.0 == .fail } ? 1 : 0
    }

    private static func checkApp(paths: MoonletPaths) -> (Outcome, String) {
        let socket = Console.displayPath(paths.socketURL.path)
        guard let agents = MoonletClient.status(paths: paths, timeout: 1) else {
            return (.fail, "App: nothing answered at \(socket). Is Moonlet running?")
        }
        return (.pass, "App: answering at \(socket) (\(agents.count) agent\(agents.count == 1 ? "" : "s"))")
    }

    private static func checkClaudeCode(settings: URL, environment: [String: String]) -> (Outcome, String) {
        let path = Console.displayPath(settings.path)
        guard FileManager.default.fileExists(atPath: settings.deletingLastPathComponent().path) else {
            return (.skip, "Claude Code: not set up (no \(Console.displayPath(settings.deletingLastPathComponent().path)))")
        }
        let hooks: [String: String]
        do {
            hooks = try ClaudeCodeInstaller.installedHooks(settingsText: (try? String(contentsOf: settings, encoding: .utf8)) ?? "")
        } catch {
            return (.fail, "Claude Code: \(error)")
        }
        let expected = ClaudeCodeInstaller.events(forClaudeVersion: Processes.claudeVersion(environment: environment))
        let missing = expected.filter { hooks[$0] == nil }
        if hooks.isEmpty {
            return (.fail, "Claude Code: no Moonlet hooks in \(path). Run: moonlet install claude-code")
        }
        if !missing.isEmpty {
            return (.fail, "Claude Code: hooks missing for \(missing.joined(separator: ", ")). Run: moonlet install claude-code")
        }
        let broken = Set(hooks.values).filter { !FileManager.default.isExecutableFile(atPath: executable(inCommand: $0)) }
        if let command = broken.first {
            return (.fail, "Claude Code: the hook runs \(executable(inCommand: command)), which isn't executable. Run: moonlet install claude-code")
        }
        return (.pass, "Claude Code: \(hooks.count) hooks installed in \(path)")
    }

    private static func checkCodex(config: URL) -> (Outcome, String) {
        let path = Console.displayPath(config.path)
        guard FileManager.default.fileExists(atPath: config.deletingLastPathComponent().path) else {
            return (.skip, "Codex: not set up (no \(Console.displayPath(config.deletingLastPathComponent().path)))")
        }
        let status: CodexInstaller.NotifyStatus
        do {
            status = try CodexInstaller.notifyStatus(configText: (try? String(contentsOf: config, encoding: .utf8)) ?? "")
        } catch {
            return (.fail, "Codex: \(error)")
        }
        switch status {
        case .notConfigured:
            return (.fail, "Codex: notify isn't set in \(path). Run: moonlet install codex")
        case .foreign(let argv):
            return (.fail, "Codex: notify runs \(argv.first ?? "nothing") without Moonlet. Run: moonlet install codex")
        case .installed(let executable, let chained):
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                return (.fail, "Codex: notify runs \(executable), which isn't executable. Run: moonlet install codex")
            }
            let then = chained.first.map { ", then \(($0 as NSString).lastPathComponent)" } ?? ""
            return (.pass, "Codex: notify runs Moonlet\(then)")
        }
    }

    /// Ollama is optional; the app can use it to condense summaries.
    private static func checkOllama() async -> (Outcome, String) {
        let reachable = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ollamaAnswers() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(300))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return reachable
            ? (.pass, "Ollama: reachable at 127.0.0.1:11434")
            : (.skip, "Ollama: not reachable at 127.0.0.1:11434 (optional)")
    }

    private static func ollamaAnswers() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The executable a hook command runs: its first word, unquoted.
    private static func executable(inCommand command: String) -> String {
        if command.hasPrefix("'") {
            var path = ""
            var rest = command.dropFirst()
            while let quote = rest.firstIndex(of: "'") {
                path += rest[..<quote]
                rest = rest[rest.index(after: quote)...]
                guard rest.hasPrefix(#"\''"#) else { break }
                path += "'"
                rest = rest.dropFirst(3)
            }
            return path
        }
        return command.split(separator: " ").first.map(String.init) ?? command
    }
}
