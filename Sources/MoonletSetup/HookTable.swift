import Foundation

/// Moonlet's part of a hooks object shaped like Claude Code's `hooks` setting and Codex's
/// `hooks.json`: `{"<Event>": [{"matcher"?: …, "hooks": [{"type": "command", "command": …}]}]}`.
///
/// Moonlet owns one group per event, holding its single command. It keeps that group
/// where it is, rewritten if it differs, and adds it after the other groups when it's
/// missing, so every other group keeps its position. Its entries anywhere else are
/// removed, along with groups and events that end up empty.
struct HookTable {
    /// Recognizes Moonlet's entries; its `command` is the one Moonlet installs.
    let ownership: HookOwnership
    /// Every event Moonlet may own, in the order changes are listed.
    let events: [String]
    /// The file the hooks live in, for messages: `settings.json` or `hooks.json`.
    let fileName: String
    /// Moonlet's group for an event.
    let group: (String) -> OrderedJSON

    /// The hooks object with Moonlet's group in place for each `wanted` event and gone
    /// from every other, plus one line per changed event ("Add the Stop hook").
    func update(_ hooks: [OrderedJSON.Member], wanted: [String]) throws -> (members: [OrderedJSON.Member], changes: [String]) {
        var changed: [(event: String, change: String)] = []
        var updated: [OrderedJSON.Member] = []
        for member in hooks {
            guard case .array(let groups) = member.value else {
                if wanted.contains(member.key) {
                    throw InstallError("hooks.\(member.key) in \(fileName) isn't an array, so Moonlet left it alone.")
                }
                updated.append(member)
                continue
            }
            let event = member.key
            let newGroups = reconcile(groups, event: event, wanted: wanted.contains(event))
            if newGroups != groups {
                let hadOurs = groups.contains { !ownership.entries(in: $0).isEmpty }
                let verb = !hadOurs ? "Add" : wanted.contains(event) ? "Update" : "Remove"
                changed.append((event, "\(verb) the \(event) hook"))
                if newGroups.isEmpty {
                    continue  // Moonlet emptied this event; drop it.
                }
            }
            updated.append(OrderedJSON.Member(event, .array(newGroups)))
        }
        for event in wanted where !hooks.contains(where: { $0.key == event }) {
            updated.append(OrderedJSON.Member(event, .array([group(event)])))
            changed.append((event, "Add the \(event) hook"))
        }
        let rank = { (event: String) in events.firstIndex(of: event) ?? events.count }
        let changes = changed.enumerated()
            .sorted { (rank($0.element.event), $0.offset) < (rank($1.element.event), $1.offset) }
            .map(\.element.change)
        return (updated, changes)
    }

    /// One event's groups with Moonlet's group in place (or gone).
    private func reconcile(_ groups: [OrderedJSON], event: String, wanted: Bool) -> [OrderedJSON] {
        var result: [OrderedJSON] = []
        var kept = false
        for group in groups {
            let ourEntries = ownership.entries(in: group)
            guard !ourEntries.isEmpty, case .object(var members) = group, case .array(let entries)? = members["hooks"]
            else {
                result.append(group)
                continue
            }
            if wanted, !kept, ourEntries.count == entries.count {
                kept = true
                result.append(self.group(event))
                continue
            }
            let remaining = entries.filter { !ownership.owns($0) }
            if !remaining.isEmpty, let index = members.lastIndex(where: { $0.key == "hooks" }) {
                members[index].value = .array(remaining)
                result.append(.object(members))
            }
        }
        if wanted, !kept {
            result.append(group(event))
        }
        return result
    }

    /// The events whose other entries sit somewhere else in `new` than in `old` (a later
    /// group's index drops when Moonlet's group goes, and so does a later entry's when
    /// Moonlet's entry leaves a shared group), with how many moved, in `events` order.
    /// Codex keys trust by position, so it asks about those entries again.
    func movedEntries(from old: [OrderedJSON.Member], to new: [OrderedJSON.Member]) -> [(event: String, count: Int)] {
        let rank = { (event: String) in events.firstIndex(of: event) ?? events.count }
        var moved: [(event: String, count: Int)] = []
        for member in old {
            let before = otherPositions(member.value)
            let after = otherPositions(new.last { $0.key == member.key }?.value)
            let count = zip(before, after).filter { $0 != $1 }.count + max(before.count - after.count, 0)
            if count > 0 {
                moved.append((member.key, count))
            }
        }
        return moved.enumerated()
            .sorted { (rank($0.element.event), $0.offset) < (rank($1.element.event), $1.offset) }
            .map(\.element)
    }

    /// The group and entry index of every entry that isn't Moonlet's, in order.
    private func otherPositions(_ groups: OrderedJSON?) -> [[Int]] {
        guard case .array(let groups)? = groups else { return [] }
        var positions: [[Int]] = []
        for (groupIndex, group) in groups.enumerated() {
            guard case .array(let entries)? = group["hooks"] else { continue }
            for (entryIndex, entry) in entries.enumerated() where !ownership.owns(entry) {
                positions.append([groupIndex, entryIndex])
            }
        }
        return positions
    }

    /// The command of Moonlet's first entry for each event, keyed by event name.
    static func installed(in hooks: [OrderedJSON.Member], ownership: HookOwnership) -> [String: String] {
        var installed: [String: String] = [:]
        for (event, position) in positions(in: hooks, ownership: ownership) {
            installed[event] = position.command
        }
        return installed
    }

    /// Where Moonlet's first entry for each event sits: its group's index among the
    /// event's groups, and its own index within that group.
    static func positions(
        in hooks: [OrderedJSON.Member], ownership: HookOwnership
    ) -> [String: (group: Int, entry: Int, command: String)] {
        var positions: [String: (group: Int, entry: Int, command: String)] = [:]
        for member in hooks where positions[member.key] == nil {
            guard case .array(let groups) = member.value else { continue }
            search: for (groupIndex, group) in groups.enumerated() {
                guard case .array(let entries)? = group["hooks"] else { continue }
                for (entryIndex, entry) in entries.enumerated() where ownership.owns(entry) {
                    if case .string(let command)? = entry["command"] {
                        positions[member.key] = (groupIndex, entryIndex, command)
                        break search
                    }
                }
            }
        }
        return positions
    }
}

/// Tells Moonlet's hook entries apart from everyone else's.
struct HookOwnership {
    /// The command Moonlet installs; empty when only recognizing.
    let command: String
    let moonletPath: String
    /// The words after the executable: `hook claude-code` or `hook codex`.
    let subcommand: String

    /// Recognizes any Moonlet hook for `subcommand`, wherever the executable lives.
    static func anyMoonlet(_ subcommand: String) -> HookOwnership {
        HookOwnership(command: "", moonletPath: "moonlet", subcommand: subcommand)
    }

    /// An entry is Moonlet's when it runs exactly `command`, or runs `subcommand` (as whole
    /// words) through `moonletPath` or anything named like moonlet.
    func owns(_ entry: OrderedJSON) -> Bool {
        guard case .string(let entryCommand)? = entry["command"] else { return false }
        if !command.isEmpty, entryCommand == command {
            return true
        }
        return runsSubcommand(entryCommand) && (entryCommand.contains(moonletPath) || entryCommand.contains("moonlet"))
    }

    func entries(in group: OrderedJSON) -> [OrderedJSON] {
        guard case .array(let entries)? = group["hooks"] else { return [] }
        return entries.filter(owns)
    }

    private func runsSubcommand(_ command: String) -> Bool {
        var rest = command[...]
        while let range = rest.range(of: subcommand) {
            if range.upperBound == command.endIndex || command[range.upperBound].isWhitespace {
                return true
            }
            rest = command[range.upperBound...]
        }
        return false
    }
}
