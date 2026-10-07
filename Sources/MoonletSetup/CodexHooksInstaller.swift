import Foundation

/// Adds Moonlet's hooks to, and removes them from, Codex's user-level `hooks.json`
/// (`$CODEX_HOME/hooks.json`, beside `config.toml`).
///
/// Moonlet owns one matcher group per event, holding a single command:
/// `{"hooks":[{"type":"command","command":"<moonlet> hook codex","timeout":5}]}`. Like
/// Claude Code's, the hooks run synchronously, so their events arrive in order; each run
/// writes nothing to stdout and exits 0 within a fraction of a second, so Codex never
/// changes course because of it. The Codex TUI hides such quick, successful runs, but
/// `codex exec` lists each one as a `hook: <Event>` line.
///
/// Codex keys a hook's trust by file, event, and position, so Moonlet's groups go after
/// any that are already there and the other hooks keep their trust. Removing Moonlet's
/// group moves the groups after it, and the plan says Codex will ask about those again. A
/// file Moonlet creates starts with a `description` saying so, and uninstalling deletes
/// it again once nothing else is left in it. Codex asks the user to trust new or changed
/// hooks before it runs them; Moonlet never answers for the user.
public enum CodexHooksInstaller {
    /// Every hook event Moonlet listens to, in the order they're written.
    public static let allEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Stop", "Interrupt", "SessionEnd",
    ]

    /// Seconds Codex waits for the hook.
    public static let hookTimeout = 5
    /// Codex limits `Interrupt` and `SessionEnd` hooks to between 1 and 3 seconds.
    static let shortHookTimeout = 2
    private static let shortTimeoutEvents: Set<String> = ["Interrupt", "SessionEnd"]

    /// The `description` of a hooks.json that Moonlet creates.
    public static let fileDescription = "Added by Moonlet, which only observes. Remove with: moonlet uninstall codex"
    private static let descriptionPrefix = "Added by Moonlet"

    /// How to let Codex run new hooks, which it skips until the user trusts them. The
    /// install command prints it, and the app shows it after connecting Codex.
    public static let trustHint = "Codex runs new hooks once you trust them: it asks at startup, or type /hooks and press t."

    /// The words after the executable in Moonlet's hook command.
    private static let subcommand = "hook codex"

    /// The hook command for a moonlet executable, quoted for the shell if needed.
    public static func hookCommand(moonletPath: String) -> String {
        "\(ShellQuote.quote(moonletPath)) \(subcommand)"
    }

    /// Plans adding Moonlet's hooks, or removing them. Idempotent: planning against the
    /// result changes nothing.
    public static func plan(hooksText: String, moonletPath: String, action: InstallAction) throws -> InstallPlan {
        let isNewFile = hooksText.allSatisfy(\.isWhitespace)
        var root = try members(hooksText)
        let hooksIndex = root.lastIndex { $0.key == "hooks" }
        var hooks: [OrderedJSON.Member] = []
        if let hooksIndex {
            guard case .object(let members) = root[hooksIndex].value else {
                throw InstallError("\"hooks\" in hooks.json isn't an object, so Moonlet left it alone.")
            }
            hooks = members
        }

        let table = table(moonletPath: moonletPath)
        var (updatedHooks, changes) = try table.update(hooks, wanted: action == .install ? allEvents : [])
        guard !changes.isEmpty else { return .unchanged(hooksText) }
        if let note = retrustNote(table.movedEntries(from: hooks, to: updatedHooks)) {
            changes.append(note)
        }
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

        switch action {
        case .install where isNewFile:
            root.insert(OrderedJSON.Member("description", .string(fileDescription)), at: 0)
        case .install:
            break
        case .uninstall:
            let before = root.count
            root.removeAll { member in
                guard member.key == "description", case .string(let text) = member.value else { return false }
                return text.hasPrefix(descriptionPrefix)
            }
            if root.isEmpty, before > 0 {
                changes.append("Delete hooks.json, which only held Moonlet's hooks")
                return InstallPlan(originalText: hooksText, newText: "", changes: changes, removesFile: true)
            }
        }
        let keepsTrailingNewline = isNewFile || hooksText.hasSuffix("\n")
        let newText = OrderedJSON.object(root).formatted() + (keepsTrailingNewline ? "\n" : "")
        return InstallPlan(originalText: hooksText, newText: newText, changes: changes)
    }

    /// Plans the edit to the hooks file at `url` and, unless `dryRun` is set, writes it
    /// (or deletes it) after saving a timestamped backup beside it.
    @discardableResult
    public static func apply(
        hooksURL url: URL,
        moonletPath: String,
        action: InstallAction,
        dryRun: Bool = false,
        now: Date = .now
    ) throws -> InstallResult {
        try ConfigFile.apply(to: url, dryRun: dryRun, now: now) { text in
            try plan(hooksText: text, moonletPath: moonletPath, action: action)
        }
    }

    /// The hook command Moonlet installed for each event, keyed by event name.
    public static func installedHooks(hooksText: String) throws -> [String: String] {
        HookTable.installed(in: try hooksObject(hooksText), ownership: .anyMoonlet(subcommand))
    }

    /// "Codex will ask you to trust 2 of your own hooks again: PreToolUse, Stop", for the
    /// other hooks that moved, since Codex keys trust by position.
    private static func retrustNote(_ moved: [(event: String, count: Int)]) -> String? {
        guard !moved.isEmpty else { return nil }
        let count = moved.map(\.count).reduce(0, +)
        let which = count == 1 ? "one of your own hooks" : "\(count) of your own hooks"
        return "Codex will ask you to trust \(which) again: \(moved.map(\.event).joined(separator: ", "))"
    }

    // MARK: Trust

    /// Whether Codex runs one of Moonlet's hooks, as far as its config file shows.
    public enum Trust: Sendable, Equatable {
        /// Codex holds a trust record for the hook. If the hook changed since it was
        /// trusted, Codex asks again; `health` accounts for that.
        case trusted
        /// No trust record: Codex lists the hook for review and skips it until then.
        case untrusted
        /// Turned off in Codex's `/hooks`.
        case disabled
    }

    /// What Codex's user `config.toml` records for each of Moonlet's hooks in the
    /// hooks.json at `hooksPath`, keyed by event name.
    ///
    /// Codex keeps trust in `[hooks.state."<file>:<event>:<group>:<handler>"]` tables with a
    /// `trusted_hash` and an optional `enabled = false`. That layout is Codex's own and may
    /// change, so callers should treat the answer as a hint.
    public static func trust(hooksText: String, hooksPath: String, configText: String) -> [String: Trust] {
        guard let hooks = try? hooksObject(hooksText) else { return [:] }
        let states = hookStates(configText)
        var result: [String: Trust] = [:]
        for (event, position) in HookTable.positions(in: hooks, ownership: .anyMoonlet(subcommand)) {
            let suffix = ":\(snakeCase(event)):\(position.group):\(position.entry)"
            let state = states.first { key, _ in
                key.hasSuffix(suffix) && isSameFile(String(key.dropLast(suffix.count)), hooksPath)
            }?.value
            switch state {
            case let state? where !state.enabled: result[event] = .disabled
            case let state? where state.trusted: result[event] = .trusted
            default: result[event] = .untrusted
            }
        }
        return result
    }

    /// Whether Codex runs Moonlet's hooks.
    public enum Health: Sendable, Equatable {
        /// A hook reported after hooks.json last changed, so Codex runs the hooks as they are.
        case reporting
        /// Every hook has a trust record, but none reported since hooks.json last changed.
        /// If the change touched Moonlet's hooks, Codex asks to trust them again.
        case mayAskAgain
        /// These hooks have no trust record, so Codex skips them until the user trusts them.
        case untrusted([String])
        /// These hooks are turned off in Codex's `/hooks`.
        case disabled([String])
    }

    /// Judges whether Codex runs Moonlet's hooks, from what its config records for each
    /// (see `trust(hooksText:hooksPath:configText:)`), when hooks.json last changed, and
    /// when a hook last reported (`CodexHookLedger.lastActivity`).
    ///
    /// A trust record holds a hash of the hook as it was trusted, in a format Codex doesn't
    /// document, so a record alone can't show that Codex still runs the hook. A report
    /// written after the file last changed can, since only hooks Codex runs report. That
    /// also covers hooks Codex runs without a record this check can read.
    public static func health(trust: [String: Trust], hooksModified: Date?, lastReport: Date?) -> Health {
        let disabled = allEvents.filter { trust[$0] == .disabled }
        if !disabled.isEmpty {
            return .disabled(disabled)
        }
        let reportedSinceChange = lastReport.map { report in hooksModified.map { report > $0 } ?? true } ?? false
        let untrusted = allEvents.filter { trust[$0] == .untrusted }
        let installed = allEvents.filter { trust[$0] != nil }
        if !untrusted.isEmpty, untrusted.count < installed.count || !reportedSinceChange {
            return .untrusted(untrusted)
        }
        return reportedSinceChange ? .reporting : .mayAskAgain
    }

    /// `PermissionRequest` → `permission_request`, the event labels in Codex's hook keys.
    static func snakeCase(_ event: String) -> String {
        var result = ""
        for character in event {
            if character.isUppercase, !result.isEmpty {
                result += "_"
            }
            result += character.lowercased()
        }
        return result
    }

    /// Each `hooks.state` key in a config file, with whether it holds a trusted hash and
    /// whether the hook is enabled.
    private static func hookStates(_ configText: String) -> [String: (trusted: Bool, enabled: Bool)] {
        var states: [String: (trusted: Bool, enabled: Bool)] = [:]
        for entry in TOMLDocument.entries(in: configText) where entry.path.count >= 3 {
            guard entry.path[0] == "hooks", entry.path[1] == "state" else { continue }
            let key = entry.path[2]
            var state = states[key] ?? (false, true)
            switch entry.path.dropFirst(3).first {
            case "trusted_hash":
                state.trusted = entry.value.count > 2
            case "enabled":
                state.enabled = entry.value != "false"
            case nil:  // An inline table: "<key>" = { trusted_hash = "…", enabled = false }
                state.trusted = state.trusted || entry.value.contains("trusted_hash")
                let compact = entry.value.filter { !$0.isWhitespace }
                state.enabled = state.enabled && !compact.contains("enabled=false")
            default:
                break
            }
            states[key] = state
        }
        return states
    }

    /// Whether a hook key's file part (possibly `file:`-prefixed) names `path`.
    private static func isSameFile(_ keyPath: String, _ path: String) -> Bool {
        let keyPath = keyPath.hasPrefix("file:") ? String(keyPath.dropFirst(5)) : keyPath
        let a = URL(filePath: keyPath).standardizedFileURL
        let b = URL(filePath: path).standardizedFileURL
        return a.path == b.path || a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    // MARK: Internals

    private static func table(moonletPath: String) -> HookTable {
        let command = hookCommand(moonletPath: moonletPath)
        return HookTable(
            ownership: HookOwnership(command: command, moonletPath: moonletPath, subcommand: subcommand),
            events: allEvents, fileName: "hooks.json"
        ) { group(for: $0, command: command) }
    }

    /// Moonlet's hook group for an event. No matcher: Codex then runs it for every tool.
    static func group(for event: String, command: String) -> OrderedJSON {
        let timeout = shortTimeoutEvents.contains(event) ? shortHookTimeout : hookTimeout
        let entry = OrderedJSON.object([
            OrderedJSON.Member("type", .string("command")),
            OrderedJSON.Member("command", .string(command)),
            OrderedJSON.Member("timeout", .number(String(timeout))),
        ])
        return .object([OrderedJSON.Member("hooks", .array([entry]))])
    }

    private static func members(_ text: String) throws -> [OrderedJSON.Member] {
        guard !text.allSatisfy(\.isWhitespace) else { return [] }
        let root: OrderedJSON
        do {
            root = try OrderedJSON(parsing: text)
        } catch let error as OrderedJSON.ParseError {
            throw InstallError("hooks.json isn't valid JSON (\(error)), so Moonlet left it alone.")
        }
        guard case .object(let members) = root else {
            throw InstallError("hooks.json doesn't hold a JSON object, so Moonlet left it alone.")
        }
        return members
    }

    private static func hooksObject(_ text: String) throws -> [OrderedJSON.Member] {
        guard case .object(let hooks)? = try members(text)["hooks"] else { return [] }
        return hooks
    }
}
