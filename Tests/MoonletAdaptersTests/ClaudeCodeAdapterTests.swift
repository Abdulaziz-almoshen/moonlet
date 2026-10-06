import Foundation
import MoonletCore
import Testing

@testable import MoonletAdapters

@Suite("ClaudeCodeAdapter")
struct ClaudeCodeAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let session = "4f6c9a2e-7b1d-4c3e-9f0a-1d2e3f4a5b6c"

    private func events(
        _ input: Data, environment: [String: String] = [:], transcript: String? = nil
    ) -> [MoonletEvent] {
        ClaudeCodeAdapter.events(hookInput: input, environment: environment, now: now) { _ in transcript }
    }

    private func event(_ input: Data, environment: [String: String] = [:]) throws -> MoonletEvent {
        let events = events(input, environment: environment)
        try #require(events.count == 1)
        return events[0]
    }

    // MARK: Session lifecycle

    @Test func sessionStartIsIdleWithALabelAndHost() throws {
        let environment = ["__CFBundleIdentifier": "com.googlecode.iterm2", "TERM_PROGRAM": "iTerm.app"]
        let event = try event(Fixtures.data("session-start.json"), environment: environment)
        #expect(event.source == "claude-code")
        #expect(event.session == session)
        #expect(event.kind == .update)
        #expect(event.state == .idle)
        #expect(event.label == "payments")
        #expect(event.cwd == "/Users/example/code/payments")
        #expect(event.host == HostInfo(bundleID: "com.googlecode.iterm2", termProgram: "iTerm.app"))
        #expect(event.ts == now.timeIntervalSince1970)
    }

    @Test func sessionStartAfterCompactionKeepsTheState() throws {
        let event = try event(Fixtures.claudePayload("SessionStart", ["source": "compact"]))
        #expect(event.state == nil)
        #expect(event.label == "payments")
    }

    @Test func explicitHostWinsOverTheEnvironment() throws {
        let host = HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys009", pid: 321)
        let events = ClaudeCodeAdapter.events(
            hookInput: try Fixtures.data("session-start.json"), environment: ["TERM_PROGRAM": "vscode"], now: now,
            host: host
        ) { _ in nil }
        #expect(events.first?.host == host)
    }

    @Test func hostIsOmittedWhenNothingIsKnown() throws {
        #expect(try event(Fixtures.data("session-start.json")).host == nil)
    }

    @Test func userPromptSubmitStartsWorkWithTheFirstLineAsTitle() throws {
        let event = try event(Fixtures.data("user-prompt-submit.json"))
        #expect(event.state == .working)
        #expect(event.title == "Fix the flaky login test in LoginTests.swift")
    }

    @Test func longPromptsAreShortenedAndLeadingBlankLinesSkipped() throws {
        let prompt = "\n\n   \n" + String(repeating: "refactor ", count: 30)
        let event = try event(Fixtures.claudePayload("UserPromptSubmit", ["prompt": prompt]))
        let title = try #require(event.title)
        #expect(title.count <= 80)
        #expect(title.hasPrefix("refactor refactor"))
        #expect(title.hasSuffix("…"))
    }

    @Test(arguments: ["system", "poll_event"])
    func machineInjectedPromptsDoNotRetitle(source: String) throws {
        let event = try event(Fixtures.claudePayload("UserPromptSubmit", ["prompt": "<task-notification>", "source": source]))
        #expect(event.state == .working)
        #expect(event.title == nil)
    }

    @Test func sessionEndEndsTheSession() throws {
        let event = try event(Fixtures.data("session-end.json"))
        #expect(event == MoonletEvent(kind: .end, source: "claude-code", session: session, ts: now.timeIntervalSince1970))
    }

    // MARK: Tools

    @Test(arguments: [
        ("Read", #"{"file_path":"/Users/example/code/payments/Sources/App.swift"}"#, "Reading App.swift"),
        ("Edit", #"{"file_path":"/x/Login.swift","old_string":"a","new_string":"b"}"#, "Editing Login.swift"),
        ("MultiEdit", #"{"file_path":"/x/Login.swift","edits":[]}"#, "Editing Login.swift"),
        ("NotebookEdit", #"{"notebook_path":"/x/analysis.ipynb","new_source":""}"#, "Editing analysis.ipynb"),
        ("Write", #"{"file_path":"/x/NOTES.md","content":"hi"}"#, "Writing NOTES.md"),
        ("Bash", #"{"command":"swift test --filter LoginTests","description":"Run tests"}"#, "Running swift test --filter LoginTests"),
        ("Bash", #"{"command":"for f in Sources/*.swift; do swiftformat \"$f\" --lint; done\necho ok"}"#,
         "Running for f in Sources/*.swift; do…"),
        ("Grep", #"{"pattern":"TODO"}"#, "Searching code"),
        ("Glob", #"{"pattern":"**/*.swift"}"#, "Searching code"),
        ("WebFetch", #"{"url":"https://www.swift.org/documentation/","prompt":"Summarize"}"#, "Reading swift.org"),
        ("WebSearch", #"{"query":"swift testing traits"}"#, "Searching the web"),
        ("Agent", #"{"description":"Find callers","prompt":"…","subagent_type":"Explore"}"#, "Running a subagent"),
        ("Task", #"{"description":"Find callers","prompt":"…"}"#, "Running a subagent"),
        ("Skill", #"{"skill":"review","args":"--quick"}"#, "Using review"),
        ("mcp__github__create_issue", #"{"title":"Bug"}"#, "Using github"),
        ("TaskList", #"{}"#, "Using TaskList"),
        ("Read", #"{}"#, "Reading a file"),
    ])
    func preToolUseDescribesTheActivity(tool: String, input: String, expected: String) throws {
        let toolInput = try JSONSerialization.jsonObject(with: Data(input.utf8))
        let event = try event(Fixtures.claudePayload("PreToolUse", ["tool_name": tool, "tool_input": toolInput]))
        #expect(event.state == .working)
        #expect(event.activity == expected)
        #expect((event.activity?.count ?? 0) <= 60)
    }

    @Test func bashActivityShowsTheCommand() throws {
        let event = try event(Fixtures.data("pre-tool-use-bash.json"))
        #expect(event.activity == "Running swift test --filter LoginTests")
    }

    @Test func askUserQuestionWaitsForTheUser() throws {
        let event = try event(Fixtures.data("pre-tool-use-ask-user-question.json"))
        #expect(event.state == .waiting)
        #expect(event.message == "Which database should the tests use? SQLite · Postgres")
        #expect(event.activity == nil)
    }

    @Test func exitPlanModeWaitsForReview() throws {
        let event = try event(Fixtures.claudePayload("PreToolUse", ["tool_name": "ExitPlanMode", "tool_input": ["plan": "1. Do it"]]))
        #expect(event.state == .waiting)
        #expect(event.message == "Plan ready: 1. Do it")
    }

    @Test func permissionRequestSaysWhatTheAgentWantsToDo() throws {
        let event = try event(Fixtures.data("permission-request.json"))
        #expect(event.state == .waiting)
        #expect(event.message == "Wants to run rm -rf .build")
    }

    @Test(arguments: [
        ("Edit", ["file_path": "/repo/Sources/Orders.swift"], "Wants to edit Orders.swift"),
        ("Write", ["file_path": "/repo/notes.md"], "Wants to write notes.md"),
        ("WebFetch", ["url": "https://www.example.com/docs"], "Wants to open example.com"),
        ("ExitPlanMode", ["plan": "## Add pagination\n\n1. Index"], "Plan ready: Add pagination"),
    ] as [(String, [String: String], String)])
    func permissionRequestsDescribeTheRequest(tool: String, input: [String: String], expected: String) throws {
        let event = try event(Fixtures.claudePayload("PermissionRequest", ["tool_name": tool, "tool_input": input]))
        #expect(event.message == expected)
    }

    @Test(arguments: [
        ("mcp__github__create_issue", "Wants to use Create Issue"),
        ("WebFetch", "Wants to open a web page"),
        ("AskUserQuestion", "Has a question for you"),
        ("ExitPlanMode", "Plan ready for review"),
        ("", "Needs your permission"),
    ])
    func permissionRequestMessages(tool: String, expected: String) throws {
        let event = try event(Fixtures.claudePayload("PermissionRequest", ["tool_name": tool, "tool_input": [:]]))
        #expect(event.message == expected)
    }

    @Test func postToolUseKeepsWorking() throws {
        let event = try event(Fixtures.claudePayload("PostToolUse", ["tool_name": "Read", "tool_input": [:], "tool_response": [:]]))
        #expect(event.state == .working)
        #expect(event.activity == nil)
        #expect(event.tasks == nil && event.task == nil && event.milestone == nil)
    }

    // MARK: Tasks

    @Test func todoWriteReplacesTheTaskList() throws {
        let event = try event(Fixtures.data("post-tool-use-todo-write.json"))
        let tasks = try #require(event.tasks)
        #expect(tasks.map(\.title) == ["Reproduce the failure", "Fix the race in LoginViewModel", "Run the full test suite"])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
        #expect(Set(tasks.map(\.id)).count == 3)
    }

    @Test func todoIdsAreStableAndDependOnPositionAndText() {
        let id = ClaudeCodeAdapter.todoID(index: 0, content: "Write tests")
        #expect(id == ClaudeCodeAdapter.todoID(index: 0, content: "Write tests"))
        #expect(id != ClaudeCodeAdapter.todoID(index: 1, content: "Write tests"))
        #expect(id != ClaudeCodeAdapter.todoID(index: 0, content: "Write docs"))
        #expect(id == "todo-0-c8b606d9")
    }

    @Test func subagentTodoListsAreIgnored() throws {
        let todos: [[String: Any]] = [["content": "Scan files", "status": "pending", "activeForm": "Scanning files"]]
        let event = try event(
            Fixtures.claudePayload(
                "PostToolUse", ["tool_name": "TodoWrite", "tool_input": ["todos": todos], "agent_id": "a1b2"]))
        #expect(event.state == .working)
        #expect(event.tasks == nil)
    }

    @Test func taskCreateUpsertsTheNewTask() throws {
        let event = try event(Fixtures.data("post-tool-use-task-create.json"))
        #expect(event.task == TaskItem(id: "3", title: "Add a regression test", status: .pending))
    }

    @Test(arguments: [
        #""Task #12 created successfully: Write docs""#,
        #"[{"type":"text","text":"Task #12 created successfully: Write docs"}]"#,
        #"{"content":[{"type":"text","text":"Task #12 created successfully: Write docs"}]}"#,
        #"{"task":{"id":12,"subject":"Write docs"}}"#,
    ])
    func taskCreateFindsTheIdInAnyResponseShape(response: String) throws {
        let toolResponse = try JSONSerialization.jsonObject(with: Data(response.utf8), options: .fragmentsAllowed)
        let event = try event(
            Fixtures.claudePayload(
                "PostToolUse",
                ["tool_name": "TaskCreate", "tool_input": ["subject": "Write docs"], "tool_response": toolResponse]))
        #expect(event.task == TaskItem(id: "12", title: "Write docs"))
    }

    @Test func taskCreateWithoutAnIdIsSkipped() throws {
        let event = try event(
            Fixtures.claudePayload(
                "PostToolUse", ["tool_name": "TaskCreate", "tool_input": ["subject": "X"], "tool_response": "Error: bad input"]))
        #expect(event.task == nil)
    }

    @Test func taskUpdateUpsertsTheStatus() throws {
        let event = try event(Fixtures.data("post-tool-use-task-update.json"))
        #expect(event.task == TaskItem(id: "3", title: "", status: .completed))
    }

    @Test func taskUpdateHandlesDeletionsRenamesAndFailures() throws {
        func task(_ input: [String: Any], _ response: [String: Any]) throws -> TaskItem? {
            try event(
                Fixtures.claudePayload(
                    "PostToolUse", ["tool_name": "TaskUpdate", "tool_input": input, "tool_response": response])
            ).task
        }
        #expect(try task(["taskId": "4", "status": "deleted"], ["success": true]) == TaskItem(id: "4", title: "", status: .deleted))
        #expect(
            try task(["taskId": "4", "status": "in_progress", "subject": "Ship"], ["success": true])
                == TaskItem(id: "4", title: "Ship", status: .inProgress))
        #expect(try task(["taskId": "4", "status": "completed"], ["success": false, "error": "Task not found"]) == nil)
        #expect(try task(["taskId": "4", "owner": "me"], ["success": true]) == nil)
        #expect(
            try task(["taskId": "5"], ["success": true, "statusChange": ["from": "pending", "to": "in_progress"]])
                == TaskItem(id: "5", title: "", status: .inProgress))
    }

    // MARK: Milestones

    @Test func committingIsAMilestone() throws {
        let event = try event(Fixtures.data("post-tool-use-bash-commit.json"))
        #expect(event.milestone == "Committed changes")
    }

    @Test(arguments: [
        ("git commit -m 'Fix it'", "Committed changes"),
        ("git -C ~/code/api commit --amend --no-edit", "Committed changes"),
        ("GIT_AUTHOR_NAME=bot git commit -am wip", "Committed changes"),
        ("git add . && git commit -m x && git push origin main", "Pushed changes"),
        ("sudo git push", "Pushed changes"),
        ("git status; git push --force-with-lease", "Pushed changes"),
        ("gh pr create --fill", "Opened a pull request"),
        ("git push -u origin HEAD && gh pr create --title \"Fix\" --body \"…\"", "Opened a pull request"),
        ("gh -R example/api pr create", "Opened a pull request"),
    ])
    func gitAndGitHubMilestones(command: String, expected: String) throws {
        let event = try event(Fixtures.claudePayload("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command]]))
        #expect(event.milestone == expected)
    }

    @Test(arguments: ["echo git commit", "git log --grep commit", "gh pr list", "git commit-tree abc", "npm run push"])
    func otherCommandsAreNotMilestones(command: String) throws {
        let event = try event(Fixtures.claudePayload("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command]]))
        #expect(event.milestone == nil)
    }

    @Test func preToolUseOfACommitIsNotYetAMilestone() throws {
        let event = try event(Fixtures.claudePayload("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "git commit -m x"]]))
        #expect(event.milestone == nil)
    }

    // MARK: Notifications

    @Test func permissionNotificationKeepsTheRequestsMessage() throws {
        let notification = try event(Fixtures.data("notification-permission.json"))
        #expect(notification.state == .waiting)
        #expect(notification.message == nil)
    }

    @Test(arguments: [
        ("permission_prompt", "Claude needs your permission to use AskUserQuestion", nil),
        ("worker_permission_prompt", "researcher needs permission for Bash", "researcher needs permission for Bash"),
        ("elicitation_dialog", "Claude Code needs your input", "Needs your input"),
        ("", "Claude needs your permission to use Write", nil),
        ("some_future_type", "Permission needed to continue", "Permission needed to continue"),
    ] as [(String, String, String?)])
    func notificationsThatNeedTheUser(type: String, message: String, expected: String?) throws {
        let event = try event(Fixtures.claudePayload("Notification", ["message": message, "notification_type": type]))
        #expect(event.state == .waiting)
        #expect(event.message == expected)
    }

    @Test(arguments: [
        ("idle_prompt", "Claude is waiting for your input"),
        ("", "Claude is waiting for your input"),
        ("auth_success", "Logged in"),
        ("agent_completed", "researcher finished"),
        ("auth_storage_failure", "Permission denied writing the keychain"),
        ("some_future_type", "Something happened"),
    ])
    func notificationsThatDoNotNeedTheUser(type: String, message: String) throws {
        #expect(events(try Fixtures.claudePayload("Notification", ["message": message, "notification_type": type])).isEmpty)
    }

    @Test func idleNotificationFixtureIsIgnored() throws {
        #expect(events(try Fixtures.data("notification-idle.json")).isEmpty)
    }

    // MARK: Stopping

    @Test func stopFinishesWithTheLastMessage() throws {
        let event = try event(Fixtures.data("stop.json"))
        #expect(event.state == .done)
        #expect(event.summary == "Fixed the race in `LoginViewModel` by serializing submits. All 128 tests pass.")
    }

    @Test func stopFallsBackToTheTranscript() throws {
        var requestedPath: String?
        let tail = try Fixtures.text("transcript-tail.jsonl")
        let events = ClaudeCodeAdapter.events(
            hookInput: try Fixtures.data("stop-without-message.json"), environment: [:], now: now
        ) { path in
            requestedPath = path
            return tail
        }
        #expect(requestedPath?.hasSuffix("4f6c9a2e-7b1d-4c3e-9f0a-1d2e3f4a5b6c.jsonl") == true)
        #expect(events.first?.summary == "Fixed the race in `LoginViewModel`.\n\nAll 128 tests pass.")
    }

    @Test func stopWithoutAnyTextHasNoSummary() throws {
        let event = try #require(events(try Fixtures.data("stop-without-message.json"), transcript: nil).first)
        #expect(event.state == .done)
        #expect(event.summary == nil)
    }

    @Test func stopDoesNotReadTheTranscriptWhenItHasTheMessage() throws {
        var read = false
        _ = ClaudeCodeAdapter.events(hookInput: try Fixtures.data("stop.json"), environment: [:], now: now) { _ in
            read = true
            return nil
        }
        #expect(!read)
    }

    @Test func stopFailureFails() throws {
        let event = try event(Fixtures.data("stop-failure.json"))
        #expect(event.state == .failed)
        #expect(event.message == "Rate limited")
        #expect(event.summary == "Running the full suite next.")
    }

    @Test func failureMessages() {
        #expect(ClaudeCodeAdapter.failureMessage(error: "overloaded", details: nil) == "The API is overloaded")
        #expect(ClaudeCodeAdapter.failureMessage(error: "unknown", details: "Socket hang up") == "Socket hang up")
        #expect(ClaudeCodeAdapter.failureMessage(error: nil, details: " ") == "Stopped with an error")
    }

    // MARK: Ignored input

    @Test func subagentStopIsIgnored() throws {
        #expect(events(try Fixtures.data("subagent-stop.json")).isEmpty)
    }

    @Test(arguments: ["PreCompact", "SubagentStart", "TaskCreated", "SomethingNew"])
    func untrackedEventsAreIgnored(hookEvent: String) throws {
        #expect(events(try Fixtures.claudePayload(hookEvent)).isEmpty)
    }

    @Test(arguments: [
        "", "not json", "[]", #"{"hook_event_name":"Stop"}"#, #"{"session_id":"","hook_event_name":"Stop"}"#,
        #"{"session_id":"s"}"#,
    ])
    func malformedPayloadsAreIgnored(json: String) {
        #expect(events(Data(json.utf8)).isEmpty)
    }

    @Test func displayNamesMatchClaudeCode() {
        #expect(ClaudeCodeAdapter.displayName(ofTool: "Bash") == "Bash")
        #expect(ClaudeCodeAdapter.displayName(ofTool: "mcp__github__create_issue") == "Create Issue")
        #expect(ClaudeCodeAdapter.displayName(ofTool: "mcp__claude_ai_Gmail__search_threads") == "Search Threads")
        #expect(ClaudeCodeAdapter.displayName(ofTool: "get-file_contents") == "Get-File Contents")
    }
}
