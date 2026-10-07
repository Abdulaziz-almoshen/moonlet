import Foundation
import MoonletCore

/// Turns Codex hook payloads into Moonlet events.
///
/// Codex pipes one JSON payload to each command hook's stdin. Every payload carries
/// `session_id`, `cwd`, and `hook_event_name`; turn events add `turn_id`, and events from
/// a subagent's thread add `agent_id` (the subagent's thread) while `session_id` stays the
/// root session's. Tools keep Codex's names: shell commands arrive as `Bash`, file edits as
/// `apply_patch` with the patch in `tool_input.command`, and MCP tools as
/// `mcp__<server>__<tool>`. See `docs/INTEGRATIONS.md` for the full mapping.
public enum CodexHookAdapter {
    /// What one hook payload means for Moonlet.
    public struct Report: Sendable, Equatable {
        /// The payload's `hook_event_name`; `nil` when the input isn't a hook payload.
        public var hookEvent: String?
        /// The events to send; empty for payloads Moonlet doesn't track.
        public var events: [MoonletEvent]
        /// What `CodexHookLedger` should remember, so Codex's notify program doesn't report
        /// the same turn again; `nil` when the input isn't a hook payload.
        public var note: CodexHookLedger.Note?

        public init(hookEvent: String? = nil, events: [MoonletEvent] = [], note: CodexHookLedger.Note? = nil) {
            self.hookEvent = hookEvent
            self.events = events
            self.note = note
        }
    }

    /// The events and ledger note for one hook payload.
    ///
    /// - Parameters:
    ///   - hookInput: The JSON payload from stdin.
    ///   - environment: The hook's environment, for host details.
    ///   - now: The event timestamp.
    ///   - host: Host details to attach. Defaults to what `environment` reveals.
    ///   - readTranscriptTail: Reads the end of the transcript at a path. Only called for
    ///     `PermissionRequest`, to see whether Codex's automatic reviewer answers it.
    public static func report(
        hookInput: Data,
        environment: [String: String],
        now: Date,
        host: HostInfo? = nil,
        readTranscriptTail: (String) -> String? = { _ in nil }
    ) -> Report {
        guard let payload = JSONFields(data: hookInput),
            let session = payload.nonEmptyString("session_id"),
            let hookEvent = payload.string("hook_event_name")
        else { return Report() }

        let subagent = payload.nonEmptyString("agent_id")
        var report = Report(hookEvent: hookEvent, note: CodexHookLedger.Note(session: session, subagentThread: subagent))
        let host = host ?? HostInfo(environment: environment)
        var event = MoonletEvent(
            source: CodexAdapter.source, session: session, cwd: payload.nonEmptyString("cwd"),
            host: host.isEmpty ? nil : host, ts: now.timeIntervalSince1970)
        let tool = payload.string("tool_name") ?? ""
        let input = payload.object("tool_input")

        switch hookEvent {
        case "SessionStart":
            // Compaction restarts the session mid-turn, so it keeps whatever state it had.
            if payload.string("source") != "compact" {
                event.state = .idle
            }
            event.label = event.cwd.map(TextTools.label(fromCwd:))

        case "UserPromptSubmit":
            event.state = .working
            // A subagent's prompt comes from its parent agent, not from the user.
            if subagent == nil, let prompt = payload.string("prompt") {
                event.title = TextTools.firstLine(of: prompt, max: 80)
            }

        case "PreToolUse":
            if tool == "request_user_input" {
                event.state = .waiting
                event.message = requestMessage(forTool: tool, input: input)
            } else {
                event.state = .working
                event.activity = tool.isEmpty ? nil : activity(forTool: tool, input: input)
                if subagent == nil, tool == "update_plan" {
                    event.tasks = planTasks(input)
                }
            }

        case "PermissionRequest":
            let request = requestMessage(forTool: tool, input: input)
            if let path = payload.nonEmptyString("transcript_path"),
                let tail = readTranscriptTail(path),
                CodexTranscript.approvalsReviewer(fromTail: tail) == CodexTranscript.automaticReviewer
            {
                // Codex's reviewer answers the request, not the user, so the agent keeps going.
                event.state = .working
                event.activity = reviewActivity(forRequest: request)
            } else {
                event.state = .waiting
                event.message = request
            }

        case "PostToolUse":
            event.state = .working
            if subagent == nil, tool == "update_plan" {
                event.tasks = planTasks(input)
            }
            if tool == "Bash", let command = input?.string("command") {
                event.milestone = milestone(forCommand: command, response: payload["tool_response"])
            }

        case "Stop":
            event.state = .done
            event.summary = payload.nonEmptyString("last_assistant_message")
            report.note?.finishedTurn = payload.nonEmptyString("turn_id")

        case "Interrupt":
            // The user stopped the turn; the session waits for the next prompt.
            event.state = .idle

        case "SessionEnd":
            report.events = [MoonletEvent(kind: .end, source: CodexAdapter.source, session: session, ts: now.timeIntervalSince1970)]
            return report

        default:  // SubagentStart, SubagentStop, PreCompact, PostCompact, and newer events.
            return report
        }
        report.events = [event]
        return report
    }

    // MARK: Requests

    /// What the agent asks of the user, specific enough to decide from the card:
    /// "Wants to run npm install", "Wants to edit Orders.swift", or the agent's own question.
    static func requestMessage(forTool tool: String, input: JSONFields?) -> String {
        let text: String
        switch tool {
        case "Bash":
            if let target = networkTarget(input) {
                text = target.isEmpty ? "Wants network access" : "Wants network access to \(target)"
            } else if let command = input?.nonEmptyString("command") {
                text = "Wants to run \(TextTools.firstLine(of: command, max: 60))"
            } else {
                text = "Wants to run a command"
            }
        case "apply_patch":
            text = PatchSummary(patchText(input)).request
        case "write_stdin":
            text = "Wants to send input to a running command"
        case "request_permissions":
            let reason = input?.nonEmptyString("reason").map { TextTools.firstLine(of: $0, max: 70) }
            text = reason.map { "Wants more permissions: \($0)" } ?? "Wants more permissions"
        case "request_user_input":
            text = ClaudeCodeAdapter.question(in: input) ?? "Has a question for you"
        case "spawn_agent":
            text = "Wants to start a subagent"
        default:
            text = ClaudeCodeAdapter.requestMessage(forTool: tool, input: input)
        }
        return TextTools.oneLine(text, max: 100)
    }

    /// "Reviewing: run npm install" for "Wants to run npm install": what the agent asked,
    /// while Codex's automatic reviewer decides.
    static func reviewActivity(forRequest request: String) -> String {
        for prefix in ["Wants to ", "Wants "] where request.hasPrefix(prefix) {
            return TextTools.oneLine("Reviewing: \(request.dropFirst(prefix.count))", max: 60)
        }
        return "Reviewing a request"
    }

    /// The host of a managed-network approval, which Codex describes as
    /// `network-access <target>`; `nil` for other shell approvals.
    private static func networkTarget(_ input: JSONFields?) -> String? {
        let prefix = "network-access"
        guard let description = input?.string("description"), description.hasPrefix(prefix) else { return nil }
        return description.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Activity

    /// What a tool call is doing, in 60 characters or fewer.
    static func activity(forTool tool: String, input: JSONFields?) -> String {
        let text: String
        switch tool {
        case "Bash":
            let command = TextTools.firstLine(of: input?.string("command") ?? "", max: 40)
            text = command.isEmpty ? "Running a command" : "Running \(command)"
        case "apply_patch":
            text = PatchSummary(patchText(input)).activity
        case "update_plan":
            text = "Updating the plan"
        case "spawn_agent":
            text = "Starting a subagent"
        case "view_image":
            text = "Viewing \(ClaudeCodeAdapter.fileName(input?.string("path")))"
        default:
            return ClaudeCodeAdapter.activity(forTool: tool, input: input)
        }
        return TextTools.oneLine(text, max: 60)
    }

    private static func patchText(_ input: JSONFields?) -> String {
        input?.string("command") ?? input?.string("patch") ?? input?.string("input") ?? ""
    }

    // MARK: Tool results

    /// `update_plan`'s steps (`{"plan": [{"step", "status"}]}`) as a full task list.
    static func planTasks(_ input: JSONFields?) -> [TaskItem]? {
        guard let steps = input?.array("plan") else { return nil }
        return steps.enumerated().compactMap { index, value in
            guard let step = JSONFields(value), let title = step.nonEmptyString("step") else { return nil }
            let status = step.string("status").flatMap(TaskItem.Status.init(rawValue:)).flatMap {
                $0 == .deleted ? nil : $0
            }
            return TaskItem(id: ClaudeCodeAdapter.todoID(index: index, content: title), title: title, status: status ?? .pending)
        }
    }

    /// The milestone for a finished shell command, if it committed, pushed, or opened a
    /// pull request. When the result starts with an exit code header (`Exit code: N` or
    /// `Process exited with code N`), the code says whether the command worked. Codex 0.154
    /// sends only the command's output, so then the output has to show the step went
    /// through; without such evidence there's no milestone.
    static func milestone(forCommand command: String, response: Any?) -> String? {
        guard let output = response as? String else { return nil }
        switch exitCode(in: output) {
        case 0?: return ShellMilestone.milestone(forCommand: command)
        case _?: return nil
        case nil: return ShellMilestone.milestone(forCommand: command, output: output)
        }
    }

    /// The exit code in a shell result's header, or `nil` when it has none.
    static func exitCode(in output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline).prefix(6) {
            for marker in ["Exit code:", "Process exited with code"] where line.hasPrefix(marker) {
                return Int(line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

/// The files an `apply_patch` call touches, from its `*** Update File:`, `*** Add File:`,
/// and `*** Delete File:` lines.
struct PatchSummary {
    enum Change {
        case edit, add, delete
    }

    /// Each file once, deletions first, since those are the ones worth a second look.
    let files: [(change: Change, name: String)]

    init(_ patch: String) {
        var seen: Set<String> = []
        var files: [(change: Change, name: String)] = []
        for line in patch.split(whereSeparator: \.isNewline) {
            let markers: [(String, Change)] = [("*** Update File:", .edit), ("*** Add File:", .add), ("*** Delete File:", .delete)]
            guard let (marker, change) = markers.first(where: { line.hasPrefix($0.0) }) else { continue }
            let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            files.append((change, ClaudeCodeAdapter.fileName(path)))
        }
        self.files = files.filter { $0.change == .delete } + files.filter { $0.change != .delete }
    }

    /// "Wants to edit Orders.swift", "Wants to delete old.swift and 2 more", and so on.
    var request: String {
        guard let first = files.first else { return "Wants to edit files" }
        let verb = switch first.change {
        case .edit: "edit"
        case .add: "create"
        case .delete: "delete"
        }
        return "Wants to \(verb) \(first.name)\(more)"
    }

    /// "Editing Orders.swift", "Creating Notes.md and 1 more", and so on.
    var activity: String {
        guard let first = files.first else { return "Editing files" }
        let verb = switch first.change {
        case .edit: "Editing"
        case .add: "Creating"
        case .delete: "Deleting"
        }
        return "\(verb) \(first.name)\(more)"
    }

    private var more: String {
        files.count > 1 ? " and \(files.count - 1) more" : ""
    }
}
