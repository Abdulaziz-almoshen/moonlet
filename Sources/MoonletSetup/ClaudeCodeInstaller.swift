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

        let ours = Ownership(command: hookCommand(moonletPath: moonletPath), moonletPath: moonletPath)
        let wanted = action == .install ? events : []
        var changedEvents: [(event: String, change: String)] = []
        var updatedHooks: [OrderedJSON.Member] = []

        for member in hooks {
            guard case .array(let groups) = member.value else {
                if wanted.contains(member.key) {
                    throw InstallError("hooks.\(member.key) in settings.json isn't an array, so Moonlet left it alone.")
                }
                updatedHooks.append(member)
                continue
            }
            let event = member.key
            let newGroups = reconcile(groups, event: event, wanted: wanted.contains(event), ours: ours)
            if newGroups != groups {
                let hadOurs = groups.contains { !ours.entries(in: $0).isEmpty }
                let verb = !hadOurs ? "Add" : wanted.contains(event) ? "Update" : "Remove"
                changedEvents.append((event, "\(verb) the \(event) hook"))
                if newGroups.isEmpty {
                    continue  // Moonlet emptied this event; drop it.
                }
            }
            updatedHooks.append(OrderedJSON.Member(event, .array(newGroups)))
        }
        for event in wanted where !hooks.contains(where: { $0.key == event }) {
            updatedHooks.append(OrderedJSON.Member(event, .array([group(for: event, command: ours.command)])))
            changedEvents.append((event, "Add the \(event) hook"))
        }

        guard !changedEvents.isEmpty else { return .unchanged(settingsText) }
        let rank = { (event: String) in allEvents.firstIndex(of: event) ?? allEvents.count }
        let changes = changedEvents.enumerated()
            .sorted { (rank($0.element.event), $0.offset) < (rank($1.element.event), $1.offset) }
            .map(\.element.change)
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
        var installed: [String: String] = [:]
        for member in hooks {
            guard case .array(let groups) = member.value else { continue }
            for group in groups {
                if case .string(let command)? = Ownership.anyMoonlet.entries(in: group).first?["command"] {
                    installed[member.key] = installed[member.key] ?? command
                }
            }
        }
        return installed
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

    /// One event's hook groups with Moonlet's entry in place (or gone). Moonlet keeps its
    /// first group of its own, rewritten if it differs; its entries anywhere else are
    /// removed, along with groups that end up empty.
    private static func reconcile(_ groups: [OrderedJSON], event: String, wanted: Bool, ours: Ownership) -> [OrderedJSON] {
        var result: [OrderedJSON] = []
        var kept = false
        for group in groups {
            let ourEntries = ours.entries(in: group)
            guard !ourEntries.isEmpty, case .object(var members) = group, case .array(let entries)? = members["hooks"]
            else {
                result.append(group)
                continue
            }
            if wanted, !kept, ourEntries.count == entries.count {
                kept = true
                result.append(self.group(for: event, command: ours.command))
                continue
            }
            let remaining = entries.filter { !ours.owns($0) }
            if !remaining.isEmpty, let index = members.lastIndex(where: { $0.key == "hooks" }) {
                members[index].value = .array(remaining)
                result.append(.object(members))
            }
        }
        if wanted, !kept {
            result.append(group(for: event, command: ours.command))
        }
        return result
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

    /// Tells Moonlet's hook entries apart from everyone else's.
    private struct Ownership {
        /// The command Moonlet installs; empty when only recognizing.
        let command: String
        let moonletPath: String

        /// Recognizes any Moonlet hook, wherever the executable lives.
        static let anyMoonlet = Ownership(command: "", moonletPath: "moonlet")

        /// An entry is Moonlet's when it runs exactly `command`, or runs `hook claude-code`
        /// through `moonletPath` or anything named like moonlet.
        func owns(_ entry: OrderedJSON) -> Bool {
            guard case .string(let entryCommand)? = entry["command"] else { return false }
            return (!command.isEmpty && entryCommand == command)
                || entryCommand.contains("hook claude-code")
                && (entryCommand.contains(moonletPath) || entryCommand.contains("moonlet"))
        }

        func entries(in group: OrderedJSON) -> [OrderedJSON] {
            guard case .array(let entries)? = group["hooks"] else { return [] }
            return entries.filter(owns)
        }
    }

    /// `[2, 1, 290]` from `"2.1.290 (Claude Code)"`.
    static func versionComponents(_ text: String) -> [Int]? {
        let token = text.split(whereSeparator: \.isWhitespace).first { $0.first?.isNumber == true }
        let components = token?.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard let components, components.count >= 2, components.allSatisfy({ $0 != nil }) else { return nil }
        return components.compactMap { $0 }
    }
}
