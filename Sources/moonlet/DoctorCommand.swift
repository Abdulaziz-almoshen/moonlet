import Foundation
import MoonletAdapters
import MoonletIPC
import MoonletSetup

/// `moonlet doctor [--settings PATH] [--config PATH]`: checks the app, both integrations,
/// and Ollama. Exits 1 if a required check fails; warnings and Ollama don't count.
enum DoctorCommand {
    private enum Outcome {
        case pass, warn, fail, skip

        var symbol: String {
            switch self {
            case .pass: "✓"
            case .warn: "!"
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

        let codex = checkCodex(
            config: config, ledger: CodexHookLedger(directory: paths.codexHooksDirectory), environment: environment)
        let checks = [checkApp(paths: paths), checkClaudeCode(settings: settings, environment: environment)]
            + codex + [await checkOllama()]
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

    /// One line for Codex's hooks and, when it matters, one for its notify setting.
    private static func checkCodex(
        config: URL, ledger: CodexHookLedger, environment: [String: String]
    ) -> [(Outcome, String)] {
        let directory = config.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return [(.skip, "Codex: not set up (no \(Console.displayPath(directory.path)))")]
        }
        let hooksFile = Locations.codexHooks(besideConfig: config)
        let configText = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        let hooksText = (try? String(contentsOf: hooksFile, encoding: .utf8)) ?? ""
        let version = Processes.codexVersion(environment: environment)
        let mechanism = CodexInstaller.mechanism(forCodexVersion: version)
        let name = version?.split(separator: " ").last.map { "Codex \($0)" } ?? "Codex"

        let hooks: [String: String]
        let notify: CodexInstaller.NotifyStatus
        do {
            hooks = try CodexHooksInstaller.installedHooks(hooksText: hooksText)
            notify = try CodexInstaller.notifyStatus(configText: configText)
        } catch {
            return [(.fail, "Codex: \(error)")]
        }

        var lines: [(Outcome, String)] = []
        if !hooks.isEmpty {
            lines.append(
                checkCodexHooks(
                    hooks, name: name, mechanism: mechanism, hooksFile: hooksFile, hooksText: hooksText,
                    configText: configText, ledger: ledger))
            if CodexInstaller.runsHooksOnTheTerminal(codexVersion: version),
                let warning = terminalWarning(name: name, environment: environment)
            {
                lines.append(warning)
            }
        } else if mechanism == .hooks {
            lines.append((.fail, "\(name): no Moonlet hooks in \(Console.displayPath(hooksFile.path)). Run: moonlet install codex"))
        }

        // Notify matters when there are no hooks; with hooks it's only a fallback.
        let needsNotify = hooks.isEmpty && mechanism != .hooks
        switch notify {
        case .notConfigured where needsNotify:
            lines.append((.fail, "\(name): notify isn't set in \(Console.displayPath(config.path)). Run: moonlet install codex"))
        case .foreign(let argv) where needsNotify:
            lines.append((.fail, "\(name): notify runs \(argv.first ?? "nothing") without Moonlet. Run: moonlet install codex"))
        case .notConfigured, .foreign:
            break
        case .installed(let executable, let chained):
            let then = chained.first.map { ", then \(($0 as NSString).lastPathComponent)" } ?? ""
            lines.append(notifyLine(name, "notify runs Moonlet\(then)", executable: executable, primary: needsNotify, fixable: true))
        case .nested(let notifier, let executable):
            let outer = notifier.first.map(CodexInstaller.programName) ?? "another program"
            // Moonlet never edits another program's notify, so only a notify install (which chains it) helps.
            lines.append(
                notifyLine(name, "notify runs Moonlet through \(outer)", executable: executable, primary: needsNotify, fixable: needsNotify))
        }
        return lines
    }

    /// The notify line: a pass when notify is how Moonlet hears from Codex, otherwise a note.
    private static func notifyLine(
        _ name: String, _ description: String, executable: String, primary: Bool, fixable: Bool
    ) -> (Outcome, String) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            let fix = fixable ? " Run: moonlet install codex" : ""
            return (primary ? .fail : .skip, "\(name): \(description) at \(executable), which isn't executable.\(fix)")
        }
        return primary ? (.pass, "\(name): \(description)") : (.skip, "\(name): \(description), as a fallback")
    }

    private static func checkCodexHooks(
        _ hooks: [String: String], name: String, mechanism: CodexInstaller.Mechanism?, hooksFile: URL, hooksText: String,
        configText: String, ledger: CodexHookLedger
    ) -> (Outcome, String) {
        let path = Console.displayPath(hooksFile.path)
        let minimum = CodexInstaller.minimumHooksVersion.map(String.init).joined(separator: ".")
        if mechanism == .notify {
            return (.fail, "\(name): Moonlet's hooks need Codex \(minimum) or later. Run: moonlet install codex")
        }
        let missing = CodexHooksInstaller.allEvents.filter { hooks[$0] == nil }
        if !missing.isEmpty {
            return (.fail, "\(name): hooks missing for \(missing.joined(separator: ", ")). Run: moonlet install codex")
        }
        if let command = Set(hooks.values).first(where: { !FileManager.default.isExecutableFile(atPath: executable(inCommand: $0)) }) {
            return (.fail, "\(name): the hook runs \(executable(inCommand: command)), which isn't executable. Run: moonlet install codex")
        }

        let lastReport = ledger.lastActivity
        let modified = try? hooksFile.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey])
        let health = CodexHooksInstaller.health(
            trust: CodexHooksInstaller.trust(hooksText: hooksText, hooksPath: hooksFile.path, configText: configText),
            hooksModified: modified?.contentModificationDate, lastReport: lastReport)
        switch health {
        case .disabled(let events):
            let which = events.count == 1 ? "Moonlet's \(events[0]) hook is" : "\(events.count) of Moonlet's hooks are"
            return (.fail, "\(name): \(which) turned off. Turn \(events.count == 1 ? "it" : "them") on in Codex's /hooks.")
        case .untrusted(let events):
            let which = events.count == hooks.count ? "Moonlet's hooks aren't" : "\(events.count) of Moonlet's \(hooks.count) hooks aren't"
            return (.fail, "\(name): \(which) trusted yet. In Codex, type /hooks and press t.")
        case .mayAskAgain:
            return (.warn, "\(name): Codex may ask you to trust Moonlet's hooks again: open /hooks in Codex.")
        case .reporting:
            let age = lastReport.map { Console.age(since: $0) } ?? "now"
            return (.pass, "\(name): \(hooks.count) hooks in \(path), reporting (last report \(age == "now" ? "just now" : age))")
        }
    }

    /// A warning when a shell startup file uses the terminal, which can stop a hook in a
    /// Codex that runs hooks attached to it; `nil` otherwise.
    private static func terminalWarning(name: String, environment: [String: String]) -> (Outcome, String)? {
        let files = ShellStartup.files(environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
        guard let use = ShellStartup.terminalUse(in: files, read: { try? String(contentsOf: $0, encoding: .utf8) }) else {
            return nil
        }
        let fixed = CodexInstaller.detachedHooksVersion.prefix(2).map(String.init).joined(separator: ".")
        return (
            .warn,
            "\(name): \(Console.displayPath(use.file.path)) runs \(use.command), which can stall Moonlet's hooks before Codex \(fixed). Update Codex, or run it only in interactive shells."
        )
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
