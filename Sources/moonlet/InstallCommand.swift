import Foundation
import MoonletSetup

/// `moonlet install|uninstall claude-code|codex [--dry-run] [--settings PATH|--config PATH]`.
enum InstallCommand {
    static func run(_ action: InstallAction, _ arguments: [String], environment: [String: String]) throws -> Int32 {
        var arguments = Arguments(arguments)
        let target = try arguments.positional("claude-code or codex")
        let dryRun = arguments.flag("--dry-run")
        let moonlet = Locations.moonletExecutable(environment: environment)

        let file: URL
        let result: InstallResult
        switch target {
        case "claude-code":
            file = try arguments.option("--settings").map(Locations.url(forUserPath:))
                ?? Locations.claudeSettings(environment: environment)
            try arguments.finish()
            var events = ClaudeCodeInstaller.allEvents
            if action == .install {
                let version = Processes.claudeVersion(environment: environment)
                events = ClaudeCodeInstaller.events(forClaudeVersion: version)
                let number = version?.split(separator: " ").first.map(String.init) ?? "version unknown"
                print("Claude Code \(number): hooking \(events.joined(separator: ", ")).")
            }
            result = try ClaudeCodeInstaller.apply(
                settingsURL: file, moonletPath: moonlet, action: action, events: events, dryRun: dryRun)
        case "codex":
            file = try arguments.option("--config").map(Locations.url(forUserPath:))
                ?? Locations.codexConfig(environment: environment)
            try arguments.finish()
            result = try CodexInstaller.apply(configURL: file, moonletPath: moonlet, action: action, dryRun: dryRun)
        default:
            throw UsageError("Unknown integration '\(target)'. Expected claude-code or codex.")
        }

        report(result, file: file, dryRun: dryRun)
        return 0
    }

    private static func report(_ result: InstallResult, file: URL, dryRun: Bool) {
        let path = Console.displayPath(file.path)
        guard result.plan.hasChanges else {
            print("\(path) is already up to date.")
            return
        }
        print("\(dryRun ? "Would change" : "Changed") \(path):")
        for change in result.plan.changes {
            print("  - \(change)")
        }
        if dryRun {
            if let diff = LineDiff.render(from: result.plan.originalText, to: result.plan.newText) {
                print("\n\(diff)")
            }
            print("\nDry run: nothing was written.")
        } else if let backup = result.backupURL {
            print("Saved the previous version as \(Console.displayPath(backup.path)).")
        }
    }
}
