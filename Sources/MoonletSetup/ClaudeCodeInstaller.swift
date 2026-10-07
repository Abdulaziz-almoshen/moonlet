import Foundation

/// Adds Moonlet's hooks to, and removes them from, a Claude Code `settings.json`.
///
/// Moonlet owns one hook group per event, holding a single command:
/// `{"hooks":[{"type":"command","command":"<moonlet> hook claude-code","timeout":5}]}`,
/// with `"matcher":"*"` for the tool events. Every other hook, and every other setting,
/// is left exactly as it was.
public enum ClaudeCodeInstaller {
    /// Every hook event Moonlet listens to, in the order they're written.
    public static let allEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    /// The Claude Code version that introduced each event newer than the original set.
    /// Older versions may reject settings that mention events they don't know.
    static let minimumVersions: [String: [Int]] = [
        "PermissionRequest": [2, 0, 45],
        "StopFailure": [2, 1, 78],
    ]

    /// Hook events that take a tool-name matcher.
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Seconds Claude Code waits for the hook.
    public static let hookTimeout = 5

    /// The events to install for a Claude Code version string such as
    /// `"2.1.290 (Claude Code)"`; every event when the version is unknown.
    public static func events(forClaudeVersion version: String?) -> [String] {
        guard let version = version.flatMap(versionComponents) else { return allEvents }
        return allEvents.filter { event in
            guard let minimum = minimumVersions[event] else { return true }
            return !version.lexicographicallyPrecedes(minimum)
        }
    }

    /// The hook command for a moonlet executable, quoted for the shell if needed.
    public static func hookCommand(moonletPath: String) -> String {
        "\(ShellQuote.quote(moonletPath)) hook claude-code"
    }

    /// Plans adding Moonlet's hooks for `events` (and removing any for other events), or
    /// removing all of them. Idempotent: planning against the result changes nothing.
    public static func plan(
        settingsText: String,
        moonletPath: String,
        action: InstallAction,
        events: [String] = allEvents
    ) throws -> InstallPlan {
        var root = try settingsMembers(settingsText)
        let hooksIndex = root.lastIndex { $0.key == "hooks" }
        var hooks: [OrderedJSON.Member] = []
        if let hooksIndex {
            guard case .object(let members) = root[hooksIndex].value else {
                throw InstallError("\"hooks\" in settings.json isn't an object, so Moonlet left it alone.")
            }
            hooks = members
        }

        let (updatedHooks, changes) = try table(moonletPath: moonletPath)
            .update(hooks, wanted: action == .install ? events : [])
        guard !changes.isEmpty else { return .unchanged(settingsText) }
        switch (hooksIndex, updatedHooks.isEmpty) {
        case (let index?, true):
            root.remove(at: index)
        case (let index?, false):
            root[index].value = .object(updatedHooks)
        case (nil, false):
            root.append(OrderedJSON.Member("hooks", .object(updatedHooks)))
        case (nil, true):
            break
        }
        let keepsTrailingNewline = settingsText.hasSuffix("\n") || settingsText.allSatisfy(\.isWhitespace)
        let newText = OrderedJSON.object(root).formatted() + (keepsTrailingNewline ? "\n" : "")
        return InstallPlan(originalText: settingsText, newText: newText, changes: changes)
    }

    /// Plans the edit to the settings file at `url` and, unless `dryRun` is set, writes it
    /// after saving a timestamped backup beside the file.
    @discardableResult
    public static func apply(
        settingsURL url: URL,
        moonletPath: String,
        action: InstallAction,
        events: [String] = allEvents,
        dryRun: Bool = false,
        now: Date = .now
    ) throws -> InstallResult {
        try ConfigFile.apply(to: url, dryRun: dryRun, now: now) { text in
            try plan(settingsText: text, moonletPath: moonletPath, action: action, events: events)
        }
    }

    /// The hook command Moonlet installed for each event, keyed by event name.
    public static func installedHooks(settingsText: String) throws -> [String: String] {
        guard case .object(let hooks)? = try settingsMembers(settingsText)["hooks"] else { return [:] }
        return HookTable.installed(in: hooks, ownership: .anyMoonlet(subcommand))
    }

    // MARK: Internals

    private static func settingsMembers(_ text: String) throws -> [OrderedJSON.Member] {
        guard !text.allSatisfy(\.isWhitespace) else { return [] }
        let root: OrderedJSON
        do {
            root = try OrderedJSON(parsing: text)
        } catch let error as OrderedJSON.ParseError {
            throw InstallError("settings.json isn't valid JSON (\(error)), so Moonlet left it alone.")
        }
        guard case .object(let members) = root else {
            throw InstallError("settings.json doesn't hold a JSON object, so Moonlet left it alone.")
        }
        return members
    }

    /// The words after the executable in Moonlet's hook command.
    private static let subcommand = "hook claude-code"

    private static func table(moonletPath: String) -> HookTable {
        let command = hookCommand(moonletPath: moonletPath)
        return HookTable(
            ownership: HookOwnership(command: command, moonletPath: moonletPath, subcommand: subcommand),
            events: allEvents, fileName: "settings.json"
        ) { group(for: $0, command: command) }
    }

    /// Moonlet's hook group for an event.
    static func group(for event: String, command: String) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if toolEvents.contains(event) {
            members.append(OrderedJSON.Member("matcher", .string("*")))
        }
        let entry = OrderedJSON.object([
            OrderedJSON.Member("type", .string("command")),
            OrderedJSON.Member("command", .string(command)),
            OrderedJSON.Member("timeout", .number(String(hookTimeout))),
        ])
        members.append(OrderedJSON.Member("hooks", .array([entry])))
        return .object(members)
    }

    /// `[2, 1, 290]` from `"2.1.290 (Claude Code)"`.
    static func versionComponents(_ text: String) -> [Int]? {
        let token = text.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }
        let components = token?.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard let components, components.count >= 2, components.allSatisfy({ $0 != nil }) else { return nil }
        return components.compactMap { $0 }
    }
}
