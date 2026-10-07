import Foundation
import MoonletCore

/// Turns Claude Code hook payloads into Moonlet events.
///
/// Claude Code pipes one JSON payload to each hook's stdin. Every payload carries
/// `session_id`, `transcript_path`, `cwd`, and `hook_event_name`, plus fields specific to
/// the event. See `docs/INTEGRATIONS.md` for the full mapping.
public enum ClaudeCodeAdapter {
    /// The `source` of every event this adapter produces.
    public static let source = "claude-code"

    /// The events for one hook payload; empty for payloads Moonlet doesn't track.
    ///
    /// - Parameters:
    ///   - hookInput: The JSON payload from stdin.
    ///   - environment: The hook's environment, for host details.
    ///   - now: The event timestamp.
    ///   - host: Host details to attach. Defaults to what `environment` reveals.
    ///   - readTranscriptTail: Reads the end of the transcript at a path. Only called when a
    ///     `Stop` payload lacks `last_assistant_message`.
    public static func events(
        hookInput: Data,
        environment: [String: String],
        now: Date,
        host: HostInfo? = nil,
        readTranscriptTail: (String) -> String?
    ) -> [MoonletEvent] {
        guard let payload = JSONFields(data: hookInput),
            let session = payload.nonEmptyString("session_id"),
            let hookEvent = payload.string("hook_event_name")
        else { return [] }

        let host = host ?? HostInfo(environment: environment)
        var event = MoonletEvent(
            source: source, session: session, cwd: payload.nonEmptyString("cwd"),
            host: host.isEmpty ? nil : host, ts: now.timeIntervalSince1970)

        switch hookEvent {
        case "SessionStart":
            // Compaction restarts the session mid-turn, so it keeps whatever state it had.
            if payload.string("source") != "compact" {
                event.state = .idle
            }
            event.label = event.cwd.map(TextTools.label(fromCwd:))

        case "UserPromptSubmit":
            event.state = .working
            if !isMachineAuthored(payload.string("source")), let prompt = payload.string("prompt") {
                event.title = TextTools.firstLine(of: prompt, max: 80)
            }

        case "PreToolUse":
            let tool = payload.string("tool_name") ?? ""
            if waitingMessage(forTool: tool) != nil {
                event.state = .waiting
                event.message = requestMessage(forTool: tool, input: payload.object("tool_input"))
            } else {
                event.state = .working
                event.activity = activity(forTool: tool, input: payload.object("tool_input"))
            }

        case "PermissionRequest":
            event.state = .waiting
            event.message = requestMessage(forTool: payload.string("tool_name") ?? "", input: payload.object("tool_input"))

        case "PostToolUse":
            event.state = .working
            applyToolResult(of: payload, to: &event)

        case "Notification":
            guard notificationNeedsUser(payload) else { return [] }
            event.state = .waiting
            event.message = notificationMessage(payload)

        case "Stop":
            event.state = .done
            event.summary =
                payload.nonEmptyString("last_assistant_message")
                ?? payload.nonEmptyString("transcript_path")
                .flatMap(readTranscriptTail)
                .flatMap(ClaudeTranscript.lastAssistantText(fromTail:))

        case "StopFailure":
            event.state = .failed
            event.message = failureMessage(error: payload.string("error"), details: payload.string("error_details"))
            event.summary = payload.nonEmptyString("last_assistant_message")

        case "SessionEnd":
            return [MoonletEvent(kind: .end, source: source, session: session, ts: now.timeIntervalSince1970)]

        default:  // SubagentStop, and events Moonlet doesn't track.
            return []
        }
        return [event]
    }

    // MARK: Prompts

    /// Turns injected by Claude Code itself (task notifications, channel messages) aren't
    /// something the user asked, so they don't replace the title.
    private static func isMachineAuthored(_ source: String?) -> Bool {
        source == "system" || source == "poll_event"
    }

    // MARK: Tools

    /// Tools that hand control to the user rather than doing work.
    static func waitingMessage(forTool tool: String) -> String? {
        switch tool {
        case "AskUserQuestion": "Has a question for you"
        case "ExitPlanMode": "Plan ready for review"
        default: nil
        }
    }

    static func permissionMessage(forTool tool: String) -> String {
        if let message = waitingMessage(forTool: tool) {
            return message
        }
        let name = displayName(ofTool: tool)
        return name.isEmpty ? "Needs your permission" : "Needs permission for \(name)"
    }

    /// What the agent asks of the user, specific enough to decide from the card:
    /// "Wants to run npm install", "Wants to edit orders.ts", or the agent's own question.
    static func requestMessage(forTool tool: String, input: JSONFields?) -> String {
        let text: String
        switch tool {
        case "AskUserQuestion":
            text = question(in: input) ?? "Has a question for you"
        case "ExitPlanMode":
            text = planTitle(in: input).map { "Plan ready: \($0)" } ?? "Plan ready for review"
        case "Bash" where input?.nonEmptyString("command") != nil:
            text = "Wants to run \(TextTools.firstLine(of: input?.string("command") ?? "", max: 60))"
        case "Edit", "MultiEdit":
            text = "Wants to edit \(fileName(input?.string("file_path")))"
        case "NotebookEdit":
            text = "Wants to edit \(fileName(input?.string("notebook_path")))"
        case "Write":
            text = "Wants to write \(fileName(input?.string("file_path")))"
        case "Read":
            text = "Wants to read \(fileName(input?.string("file_path")))"
        case "WebFetch":
            text = "Wants to open \(webHost(input?.string("url")))"
        case "WebSearch":
            text = "Wants to search the web"
        case "Agent", "Task":
            text = "Wants to start a subagent"
        default:
            let name = displayName(ofTool: tool)
            text = name.isEmpty ? "Needs your permission" : "Wants to use \(name)"
        }
        return TextTools.oneLine(text, max: 100)
    }

    /// The first question of an `AskUserQuestion` call, followed by its options when they fit.
    static func question(in input: JSONFields?) -> String? {
        guard let first = JSONFields(input?.array("questions")?.first),
              let text = first.nonEmptyString("question") else { return nil }
        let options = (first.array("options") ?? []).compactMap { JSONFields($0)?.nonEmptyString("label") }
        let withOptions = options.isEmpty ? text : "\(text) \(options.joined(separator: " · "))"
        return TextTools.oneLine(withOptions.count <= 100 ? withOptions : text, max: 100)
    }

    /// The first line of an `ExitPlanMode` plan, without Markdown heading marks.
    static func planTitle(in input: JSONFields?) -> String? {
        let lines = (input?.string("plan") ?? "").split(whereSeparator: \.isNewline)
        guard let line = lines.lazy.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "# \t")) }).first(where: { !$0.isEmpty })
        else { return nil }
        return TextTools.oneLine(line, max: 60)
    }

    /// Claude Code's display name for a tool, which its permission notifications use:
    /// the last `__` segment, with underscores as spaces and each word capitalized
    /// (`mcp__github__create_issue` becomes "Create Issue").
    static func displayName(ofTool tool: String) -> String {
        let name = tool.components(separatedBy: "__").last { !$0.isEmpty } ?? tool
        var result = ""
        var previousIsWordCharacter = false
        for character in name.replacingOccurrences(of: "_", with: " ") {
            let isWordCharacter = character.isASCII && (character.isLetter || character.isNumber)
            result += isWordCharacter && !previousIsWordCharacter ? character.uppercased() : String(character)
            previousIsWordCharacter = isWordCharacter
        }
        return result
    }

    /// What a tool call is doing, in 60 characters or fewer.
    static func activity(forTool tool: String, input: JSONFields?) -> String {
        let text: String
        switch tool {
        case "Read":
            text = "Reading \(fileName(input?.string("file_path")))"
        case "Edit", "MultiEdit":
            text = "Editing \(fileName(input?.string("file_path")))"
        case "NotebookEdit":
            text = "Editing \(fileName(input?.string("notebook_path")))"
        case "Write":
            text = "Writing \(fileName(input?.string("file_path")))"
        case "Bash":
            text = "Running \(TextTools.firstLine(of: input?.string("command") ?? "", max: 40))"
        case "Grep", "Glob":
            text = "Searching code"
        case "WebFetch":
            text = "Reading \(webHost(input?.string("url")))"
        case "WebSearch":
            text = "Searching the web"
        case "Agent", "Task":
            text = "Running a subagent"
        case "Skill":
            text = "Using \(input?.nonEmptyString("skill") ?? "a skill")"
        case _ where tool.hasPrefix("mcp__"):
            let parts = tool.components(separatedBy: "__")
            text = "Using \(parts.count > 2 && !parts[1].isEmpty ? parts[1] : tool)"
        default:
            text = "Using \(tool)"
        }
        return TextTools.oneLine(text, max: 60)
    }

    static func fileName(_ path: String?) -> String {
        guard let path, let name = path.split(separator: "/").last else { return "a file" }
        return String(name)
    }

    private static func webHost(_ url: String?) -> String {
        guard let host = url.flatMap(URL.init(string:))?.host(), !host.isEmpty else { return "a web page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Tool results

    private static func applyToolResult(of payload: JSONFields, to event: inout MoonletEvent) {
        let input = payload.object("tool_input")
        let response = payload["tool_response"]
        switch payload.string("tool_name") {
        case "TodoWrite" where payload.string("agent_id") == nil:
            // Subagents keep their own todo lists; only the main thread's is the session's.
            event.tasks = todoTasks(input)
        case "TaskCreate":
            event.task = createdTask(input: input, response: response)
        case "TaskUpdate":
            event.task = updatedTask(input: input, response: response)
        case "Bash":
            event.milestone = input?.string("command").flatMap(ShellMilestone.milestone(forCommand:))
        default:
            break
        }
    }

    /// TodoWrite's `todos` (`{content, status, activeForm}`) as a full task list.
    static func todoTasks(_ input: JSONFields?) -> [TaskItem]? {
        guard let todos = input?.array("todos") else { return nil }
        return todos.enumerated().compactMap { index, value in
            guard let todo = JSONFields(value), let content = todo.string("content") else { return nil }
            let status = todo.string("status").flatMap(TaskItem.Status.init(rawValue:)).flatMap {
                $0 == .deleted ? nil : $0
            }
            return TaskItem(id: todoID(index: index, content: content), title: content, status: status ?? .pending)
        }
    }

    /// A stable id from a todo's position and text. TodoWrite items have no ids of their own.
    static func todoID(index: Int, content: String) -> String {
        // 32-bit FNV-1a: unlike `Hasher`, stable across processes.
        var hash: UInt32 = 0x811C_9DC5
        for byte in content.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return "todo-\(index)-\(String(repeating: "0", count: 8 - hex.count))\(hex)"
    }

    /// TaskCreate's input is `{subject, description, activeForm?}`; the new id only
    /// appears in the response.
    static func createdTask(input: JSONFields?, response: Any?) -> TaskItem? {
        guard let id = createdTaskID(in: response) else { return nil }
        let title = input?.string("subject") ?? JSONFields(response)?.object("task")?.string("subject") ?? ""
        return TaskItem(id: id, title: title, status: .pending)
    }

    /// The new task's id: `tool_response.task.id`, or the `#<id>` in the
    /// "Task #<id> created successfully: …" text, whether that arrives as a string or as
    /// content blocks.
    static func createdTaskID(in response: Any?) -> String? {
        switch response {
        case let text as String:
            return taskNumber(inCreationText: text)
        case let blocks as [Any]:
            return blocks.lazy.compactMap { createdTaskID(in: $0) }.first
        case let dictionary as [String: Any]:
            let fields = JSONFields(dictionary)
            return identifier(fields.object("task")?["id"]) ?? identifier(fields["taskId"])
                ?? createdTaskID(in: fields["text"] ?? fields["content"])
        default:
            return nil
        }
    }

    private static func taskNumber(inCreationText text: String) -> String? {
        guard let marker = text.range(of: "Task #") else { return nil }
        let rest = text[marker.upperBound...]
        let id = rest.prefix { !$0.isWhitespace }
        guard !id.isEmpty, rest.dropFirst(id.count).hasPrefix(" created") else { return nil }
        return String(id)
    }

    /// TaskUpdate's input is `{taskId, status?, subject?, …}` and its response
    /// `{success, taskId, updatedFields, statusChange?: {from, to}}`. Updates that don't
    /// set a status are skipped, since a task upsert always carries one.
    static func updatedTask(input: JSONFields?, response: Any?) -> TaskItem? {
        let result = JSONFields(response)
        guard result?.bool("success") != false,
            let id = identifier(input?["taskId"]) ?? identifier(result?["taskId"]),
            let status = (input?.string("status") ?? result?.object("statusChange")?.string("to"))
                .flatMap(TaskItem.Status.init(rawValue:))
        else { return nil }
        return TaskItem(id: id, title: input?.string("subject") ?? "", status: status)
    }

    private static func identifier(_ value: Any?) -> String? {
        switch value {
        case let string as String: string.isEmpty ? nil : string
        case let number as Int: String(number)
        default: nil
        }
    }

    // MARK: Notifications

    /// Notification types that never mean the user is needed.
    private static let informationalNotifications: Set<String> = [
        "idle_prompt", "auth_success", "auth_storage_failure", "agent_needs_input", "agent_completed",
        "push_notification", "computer_use_enter", "computer_use_exit", "quota_auto_resume_fired",
        "quota_auto_resume_stale", "quota_auto_resume_disabled", "model_refusal_fallback",
        "elicitation_complete", "elicitation_response",
    ]

    /// Whether a notification means the agent is blocked on the user.
    static func notificationNeedsUser(_ payload: JSONFields) -> Bool {
        let type = payload.string("notification_type") ?? ""
        let message = payload.string("message") ?? ""
        switch type {
        case "permission_prompt", "worker_permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
            return true
        case _ where informationalNotifications.contains(type):
            return false
        default:
            // No type (older Claude Code versions) or a new one: go by the text.
            if message.localizedCaseInsensitiveContains("waiting for your input") {
                return false
            }
            return message.localizedCaseInsensitiveContains("permission")
        }
    }

    /// The message for a notification that needs the user, or `nil` to keep the stored one.
    static func notificationMessage(_ payload: JSONFields) -> String? {
        switch payload.string("notification_type") {
        case "elicitation_dialog", "elicitation_url_dialog":
            return "Needs your input"
        default:
            return normalizedPermissionMessage(payload.string("message") ?? "")
        }
    }

    /// The standard "Claude needs your permission to use X" notification follows a
    /// `PermissionRequest` that already described the request in detail, so it adds no
    /// message (the stored one stays). Other permission texts are kept as they are.
    private static func normalizedPermissionMessage(_ message: String) -> String? {
        if message.hasPrefix("Claude needs your permission to use ") {
            return nil
        }
        return message.isEmpty ? nil : TextTools.oneLine(message, max: 120)
    }

    // MARK: Failures

    /// A short reason for a `StopFailure` `error` code.
    static func failureMessage(error: String?, details: String?) -> String {
        switch error {
        case "authentication_failed": "Authentication failed"
        case "oauth_org_not_allowed": "Organization not allowed"
        case "account_on_hold": "Account on hold"
        case "verification_required": "Account verification required"
        case "billing_error": "Billing problem"
        case "rate_limit": "Rate limited"
        case "overloaded": "The API is overloaded"
        case "invalid_request": "Invalid API request"
        case "model_not_found": "Model not found"
        case "server_error": "API server error"
        case "max_output_tokens": "Hit the output token limit"
        case "cloud_credential_error": "Cloud credentials problem"
        default:
            details.map { TextTools.oneLine($0, max: 120) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Stopped with an error"
        }
    }
}
