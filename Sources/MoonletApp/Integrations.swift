import AppKit
import MoonletSetup

/// Connects coding agents to Moonlet by running the bundled `moonlet` command,
/// the same code path people use from a terminal. Every change is previewed
/// and confirmed first, and the command keeps a backup of each file it edits.
@MainActor
enum Integrations {
    static var isClaudeCodeConnected: Bool {
        contents(of: "~/.claude/settings.json")?.contains("hook claude-code") == true
    }

    /// Moonlet's hooks in `hooks.json`, or a notify command that runs Moonlet (for Codex
    /// before 0.153): its own, or another app's that runs a Moonlet still on disk, which
    /// `moonlet install codex` leaves as it is.
    static var isCodexConnected: Bool {
        if let hooks = try? CodexHooksInstaller.installedHooks(hooksText: contents(of: "~/.codex/hooks.json") ?? ""),
            !hooks.isEmpty
        {
            return true
        }
        switch try? CodexInstaller.notifyStatus(configText: contents(of: "~/.codex/config.toml") ?? "") {
        case .installed?:
            return true
        case .nested(_, let executable)?:
            return FileManager.default.isExecutableFile(atPath: executable)
        case .notConfigured?, .foreign?, nil:
            return false
        }
    }

    static func connectClaudeCode() {
        connect(target: "claude-code", name: "Claude Code")
    }

    static func connectCodex() {
        connect(target: "codex", name: "Codex")
    }

    /// The `moonlet` command: `Contents/Helpers` in the app bundle (APFS is usually
    /// case-insensitive, so it can't sit next to the `Moonlet` executable), or next
    /// to the executable in a development build.
    static var commandPath: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/moonlet"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("moonlet"),
        ]
        return candidates.compactMap { $0?.path }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func connect(target: String, name: String) {
        NSApp.activate()
        guard let command = commandPath else {
            show("The moonlet command is missing", "Reinstall Moonlet, or run `moonlet install \(target)` from a terminal.")
            return
        }
        let preview = run(command, ["install", target, "--dry-run"])
        let confirm = NSAlert()
        confirm.messageText = "Connect \(name)?"
        confirm.informativeText = """
            Moonlet will make the changes below and back up any file it edits. Your other settings stay as they are.

            \(preview.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
            """
        confirm.addButton(withTitle: "Connect")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let result = run(command, ["install", target])
        if result.status == 0 {
            // Codex skips new hooks until you trust them; the command says how.
            let nextStep = result.output.contains(CodexHooksInstaller.trustHint) ? "\n\n\(CodexHooksInstaller.trustHint)" : ""
            show("\(name) connected", "New \(name) sessions now report to Moonlet. Sessions already open start reporting after a restart.\(nextStep)")
        } else {
            show("Couldn't connect \(name)", result.output)
        }
    }

    private static func run(_ command: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func contents(of path: String) -> String? {
        try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
