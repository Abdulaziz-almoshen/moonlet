import Foundation
import MoonletSetup

/// `moonlet install|uninstall claude-code|codex [--dry-run] [--settings PATH|--config PATH]`.
enum InstallCommand {
    static func run(_ action: InstallAction, _ arguments: [String], environment: [String: String]) throws -> Int32 {
        var arguments = Arguments(arguments)
        let target = try arguments.positional("claude-code or codex")
        let dryRun = arguments.flag("--dry-run")
        let moonlet = Locations.moonletExecutable(environment: environment)

        switch target {
        case "claude-code":
            let file = try arguments.option("--settings").map(Locations.url(forUserPath:))
                ?? Locations.claudeSettings(environment: environment)
            try arguments.finish()
            var events = ClaudeCodeInstaller.allEvents
            if action == .install {
                let version = Processes.claudeVersion(environment: environment)
                events = ClaudeCodeInstaller.events(forClaudeVersion: version)
                let number = version?.split(separator: " ").first.map(String.init) ?? "version unknown"
                print("Claude Code \(number): hooking \(events.joined(separator: ", ")).")
            }
            let result = try ClaudeCodeInstaller.apply(
                settingsURL: file, moonletPath: moonlet, action: action, events: events, dryRun: dryRun)
            report([(file, result)], primary: file, dryRun: dryRun)

        case "codex":
            let config = try arguments.option("--config").map(Locations.url(forUserPath:))
                ?? Locations.codexConfig(environment: environment)
            let hooksFile = Locations.codexHooks(besideConfig: config)
            try arguments.finish()
            let version = action == .install ? Processes.codexVersion(environment: environment) : nil
            let result = try CodexInstaller.apply(
                configURL: config, hooksURL: hooksFile, moonletPath: moonlet, action: action, codexVersion: version,
                dryRun: dryRun)
            if action == .install {
                print(codexSummary(version: version, mechanism: result.mechanism))
            }
            let primary = result.mechanism == .hooks ? hooksFile : config
            report([(hooksFile, result.hooks), (config, result.config)], primary: primary, dryRun: dryRun)
            for note in result.notes {
                print(note)
            }
            // A dry run leaves nothing for Codex to ask about yet.
            if action == .install, !dryRun, result.mechanism == .hooks, result.hooks.plan.hasChanges {
                print(CodexHooksInstaller.trustHint)
            }

        default:
            throw UsageError("Unknown integration '\(target)'. Expected claude-code or codex.")
        }
        return 0
    }

    /// "Codex 0.154.0: reporting through hooks.", and so on.
    private static func codexSummary(version: String?, mechanism: CodexInstaller.Mechanism) -> String {
        let number = version?.split(separator: " ").last.map(String.init)
        let minimum = CodexInstaller.minimumHooksVersion.map(String.init).joined(separator: ".")
        switch (number, mechanism) {
        case (let number?, .hooks):
            return "Codex \(number): reporting through hooks."
        case (let number?, .notify):
            return "Codex \(number): reporting finished turns through notify. Hooks need Codex \(minimum) or later."
        case (nil, .hooks):
            return "Codex version unknown: keeping Moonlet's hooks."
        case (nil, .notify):
            return "Codex version unknown: reporting finished turns through notify. With codex \(minimum) or later on your PATH, Moonlet uses hooks."
        }
    }

    /// Prints each file's changes (and, for a dry run, the diff), or that nothing changed.
    private static func report(_ results: [(file: URL, result: InstallResult)], primary: URL, dryRun: Bool) {
        let changed = results.filter { $0.result.plan.hasChanges }
        guard !changed.isEmpty else {
            print("\(Console.displayPath(primary.path)) is already up to date.")
            return
        }
        for (file, result) in changed {
            print("\(dryRun ? "Would change" : "Changed") \(Console.displayPath(file.path)):")
            for change in result.plan.changes {
                print("  - \(change)")
            }
            if dryRun {
                if let diff = LineDiff.render(from: result.plan.originalText, to: result.plan.newText) {
                    print("\n\(diff)\n")
                }
            } else if let backup = result.backupURL {
                print("Saved the previous version as \(Console.displayPath(backup.path)).")
            }
        }
        if dryRun {
            print("Dry run: nothing was written.")
        }
    }
}
