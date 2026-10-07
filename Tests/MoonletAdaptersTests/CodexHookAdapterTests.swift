import Foundation
import MoonletCore
import Testing

@testable import MoonletAdapters

@Suite("CodexHookAdapter")
struct CodexHookAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let session = Fixtures.codexSession

    private func report(_ input: Data, environment: [String: String] = [:]) -> CodexHookAdapter.Report {
        CodexHookAdapter.report(hookInput: input, environment: environment, now: now)
    }

    private func event(_ input: Data, environment: [String: String] = [:]) throws -> MoonletEvent {
        let events = report(input, environment: environment).events
        try #require(events.count == 1)
        return events[0]
    }

    private func event(_ hookEvent: String, _ fields: [String: Any] = [:]) throws -> MoonletEvent {
        try event(Fixtures.codexPayload(hookEvent, fields))
    }

    private func codex(_ name: String) throws -> Data {
        try Fixtures.data(name, in: "codex")
    }

    // MARK: Session lifecycle

    @Test func sessionStartIsIdleWithALabelAndHost() throws {
        let event = try event(codex("session-start.json"), environment: ["TERM_PROGRAM": "ghostty"])
        #expect(event.source == "codex")
        #expect(event.session == session)
        #expect(event.kind == .update)
        #expect(event.state == .idle)
        #expect(event.label == "payments")
        #expect(event.cwd == "/Users/example/code/payments")
        #expect(event.host == HostInfo(termProgram: "ghostty"))
        #expect(event.ts == now.timeIntervalSince1970)
    }

    @Test func sessionStartAfterCompactionKeepsTheState() throws {
        let event = try event("SessionStart", ["source": "compact"])
        #expect(event.state == nil)
        #expect(event.label == "payments")
    }

    @Test func explicitHostWinsAndAnEmptyOneIsOmitted() throws {
        let host = HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys004", pid: 4242)
        let explicit = CodexHookAdapter.report(
            hookInput: try codex("session-start.json"), environment: ["TERM_PROGRAM": "vscode"], now: now, host: host)
        #expect(explicit.events.first?.host == host)
        #expect(try event(codex("session-start.json")).host == nil)
    }

    @Test func userPromptSubmitStartsWorkWithTheFirstLineAsTitle() throws {
        let event = try event(codex("user-prompt-submit.json"))
        #expect(event.state == .working)
        #expect(event.title == "Add retries to the payment client")
    }

    @Test func aSubagentsPromptDoesNotRetitleTheSession() throws {
        let event = try event("UserPromptSubmit", ["prompt": "Scan the tests", "agent_id": "0199b000-sub", "agent_type": "explorer"])
        #expect(event.session == session)
        #expect(event.state == .working)
        #expect(event.title == nil)
    }

    @Test func interruptReturnsToIdle() throws {
        let event = try event(codex("interrupt.json"))
        #expect(event.state == .idle)
        #expect(event.message == nil && event.summary == nil)
    }

    @Test func sessionEndEndsTheSession() throws {
        let event = try event(codex("session-end.json"))
        #expect(event == MoonletEvent(kind: .end, source: "codex", session: session, ts: now.timeIntervalSince1970))
    }

    // MARK: Tools

    @Test func bashActivityShowsTheCommand() throws {
        let event = try event(codex("pre-tool-use-bash.json"))
        #expect(event.state == .working)
        #expect(event.activity == "Running swift test --filter PaymentClientTests")
        #expect(event.milestone == nil)
    }

    @Test func applyPatchActivityNamesTheFile() throws {
        #expect(try event(codex("pre-tool-use-apply-patch.json")).activity == "Editing PaymentClient.swift")
    }

    @Test(arguments: [
        ("Bash", #"{"command":"for f in Sources/*.swift; do swiftformat \"$f\"; done\necho ok"}"#, "Running for f in Sources/*.swift; do…"),
        ("Bash", #"{}"#, "Running a command"),
        ("apply_patch", #"{"command":"*** Begin Patch\n*** Add File: docs/RETRIES.md\n+# Retries\n*** End Patch"}"#, "Creating RETRIES.md"),
        ("apply_patch", #"{"command":"*** Begin Patch\n*** Update File: a/One.swift\n*** Update File: b/Two.swift\n*** Update File: a/One.swift\n*** End Patch"}"#, "Editing One.swift and 1 more"),
        ("apply_patch", #"{"command":"*** Begin Patch\n*** Update File: Keep.swift\n*** Delete File: Old.swift\n*** End Patch"}"#, "Deleting Old.swift and 1 more"),
        ("apply_patch", #"{"command":"not a patch"}"#, "Editing files"),
        ("update_plan", #"{"plan":[]}"#, "Updating the plan"),
        ("spawn_agent", #"{"message":"Find the callers"}"#, "Starting a subagent"),
        ("view_image", #"{"path":"/Users/example/Desktop/screenshot.png"}"#, "Viewing screenshot.png"),
        ("mcp__linear__create_issue", #"{"title":"Flaky test"}"#, "Using linear"),
        ("list_mcp_resources", #"{}"#, "Using list_mcp_resources"),
    ])
    func preToolUseDescribesTheActivity(tool: String, input: String, expected: String) throws {
        let toolInput = try JSONSerialization.jsonObject(with: Data(input.utf8))
        let event = try event("PreToolUse", ["tool_name": tool, "tool_input": toolInput, "tool_use_id": "call_1"])
        #expect(event.state == .working)
        #expect(event.activity == expected)
        #expect((event.activity?.count ?? 0) <= 60)
    }

    @Test func requestUserInputWaitsWithTheQuestion() throws {
        let questions: [[String: Any]] = [[
            "id": "db", "header": "Database", "question": "Which database should the tests use?",
            "options": [["label": "SQLite", "description": "Fast"], ["label": "Postgres", "description": "Like production"]],
        ]]
        let event = try event("PreToolUse", ["tool_name": "request_user_input", "tool_input": ["questions": questions]])
        #expect(event.state == .waiting)
        #expect(event.message == "Which database should the tests use? SQLite · Postgres")
        #expect(event.activity == nil)
        let bare = try self.event("PreToolUse", ["tool_name": "request_user_input", "tool_input": [:]])
        #expect(bare.message == "Has a question for you")
    }

    // MARK: Permission requests

    @Test func permissionRequestSaysWhatTheAgentWantsToRun() throws {
        let event = try event(codex("permission-request-bash.json"))
        #expect(event.state == .waiting)
        #expect(event.message == "Wants to run npm install")
    }

    @Test func permissionRequestForAPatchNamesTheFiles() throws {
        #expect(try event(codex("permission-request-apply-patch.json")).message == "Wants to edit PaymentClient.swift and 1 more")
    }

    @Test(arguments: [
        ("Bash", ["command": "curl -sS https://registry.example.com/x", "description": "network-access registry.example.com"],
         "Wants network access to registry.example.com"),
        ("Bash", ["command": "rm -rf build/\nls"], "Wants to run rm -rf build/"),
        ("Bash", [:], "Wants to run a command"),
        ("apply_patch", ["command": "*** Begin Patch\n*** Delete File: Sources/Legacy.swift\n*** End Patch"], "Wants to delete Legacy.swift"),
        ("apply_patch", ["command": "*** Begin Patch\n*** Add File: Notes.md\n+hi\n*** End Patch"], "Wants to create Notes.md"),
        ("apply_patch", [:], "Wants to edit files"),
        ("write_stdin", ["chars": "y\n"], "Wants to send input to a running command"),
        ("request_permissions", ["reason": "Install packages from the network"], "Wants more permissions: Install packages from the network"),
        ("request_permissions", [:], "Wants more permissions"),
        ("spawn_agent", [:], "Wants to start a subagent"),
        ("mcp__github__create_issue", ["title": "Bug"], "Wants to use Create Issue"),
        ("", [:], "Needs your permission"),
    ] as [(String, [String: String], String)])
    func permissionRequestsDescribeTheRequest(tool: String, input: [String: String], expected: String) throws {
        let event = try event("PermissionRequest", ["tool_name": tool, "tool_input": input])
        #expect(event.state == .waiting)
        #expect(event.message == expected)
    }

    @Test func aSubagentsPermissionRequestWaitsOnTheSession() throws {
        let report = report(
            try Fixtures.codexPayload(
                "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make deploy"], "agent_id": "0199b000-sub"]))
        #expect(report.events.first?.session == session)
        #expect(report.events.first?.state == .waiting)
        #expect(report.events.first?.message == "Wants to run make deploy")
        #expect(report.note == CodexHookLedger.Note(session: session, subagentThread: "0199b000-sub"))
    }

    // MARK: Tool results

    @Test func postToolUseKeepsWorking() throws {
        let event = try event("PostToolUse", ["tool_name": "apply_patch", "tool_input": ["command": "*** Begin Patch"], "tool_response": "Success"])
        #expect(event.state == .working)
        #expect(event.activity == nil)
        #expect(event.tasks == nil && event.milestone == nil)
    }

    @Test func pushingIsAMilestone() throws {
        #expect(try event(codex("post-tool-use-bash-push.json")).milestone == "Pushed changes")
    }

    @Test func aFailedCommandIsNotAMilestone() throws {
        let response = "Exit code: 1\nWall time: 0.4 seconds\nOutput:\nrejected: non-fast-forward\n"
        let event = try event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "git push"], "tool_response": response])
        #expect(event.state == .working)
        #expect(event.milestone == nil)
    }

    @Test(arguments: [
        ("Exit code: 0\nWall time: 1 seconds\nOutput:\n", true),
        ("Exit code: 128\nOutput:\nfatal", false),
        ("Chunk ID: a\nWall time: 0.1 seconds\nProcess exited with code 2\nOutput:\n", false),
        ("plain output without a header", true),
    ])
    func commandSuccessComesFromTheOutputHeader(response: String, succeeded: Bool) {
        #expect(CodexHookAdapter.commandSucceeded(response) == succeeded)
    }

    @Test func updatePlanReplacesTheTaskList() throws {
        let event = try event(codex("post-tool-use-update-plan.json"))
        let tasks = try #require(event.tasks)
        #expect(tasks.map(\.title) == ["Add a Backoff type", "Retry failed requests", "Cover retries in tests"])
        #expect(tasks.map(\.status) == [.completed, .inProgress, .pending])
        #expect(tasks.first?.id == ClaudeCodeAdapter.todoID(index: 0, content: "Add a Backoff type"))
    }

    @Test func updatePlanAlsoAppliesBeforeTheToolRuns() throws {
        let plan: [[String: Any]] = [["step": "Write the parser", "status": "in_progress"], ["step": " ", "status": "pending"]]
        let event = try event("PreToolUse", ["tool_name": "update_plan", "tool_input": ["plan": plan]])
        #expect(event.activity == "Updating the plan")
        #expect(event.tasks == [TaskItem(id: ClaudeCodeAdapter.todoID(index: 0, content: "Write the parser"), title: "Write the parser", status: .inProgress)])
    }

    @Test func aSubagentsPlanIsNotTheSessions() throws {
        let plan: [[String: Any]] = [["step": "Scan", "status": "pending"]]
        let event = try event("PostToolUse", ["tool_name": "update_plan", "tool_input": ["plan": plan], "agent_id": "0199b000-sub"])
        #expect(event.state == .working)
        #expect(event.tasks == nil)
    }

    // MARK: Stopping

    @Test func stopFinishesWithTheLastMessageAndNotesTheTurn() throws {
        let report = report(try codex("stop.json"))
        let event = try #require(report.events.first)
        #expect(event.state == .done)
        #expect(event.summary == "Added retries with exponential backoff to PaymentClient. All 42 tests pass.")
        #expect(report.hookEvent == "Stop")
        #expect(report.note == CodexHookLedger.Note(session: session, finishedTurn: "7"))
    }

    @Test func stopWithoutAMessageHasNoSummary() throws {
        let event = try event("Stop", ["stop_hook_active": false, "last_assistant_message": NSNull()])
        #expect(event.state == .done)
        #expect(event.summary == nil)
    }

    // MARK: A whole turn

    @Test func aTurnWithAPermissionRequestSignalsLikeClaudeCode() throws {
        var store = AgentStore()
        var signals: [Signal] = []
        let payloads = [
            try codex("session-start.json"), try codex("user-prompt-submit.json"), try codex("pre-tool-use-bash.json"),
            try codex("permission-request-bash.json"), try codex("post-tool-use-bash-push.json"), try codex("stop.json"),
        ]
        for (index, payload) in payloads.enumerated() {
            for event in report(payload).events {
                signals += store.apply(event, now: now.addingTimeInterval(Double(index)))
            }
        }
        let id = "codex:\(session)"
        #expect(
            signals == [
                .appeared(agentID: id), .needsYou(agentID: id, message: "Wants to run npm install"), .resolved(agentID: id),
                .milestone(agentID: id, text: "Pushed changes"),
                .finished(agentID: id, summary: "Added retries with exponential backoff to PaymentClient. All 42 tests pass."),
            ])
        #expect(store.agent(id: id)?.title == "Add retries to the payment client")
        #expect(store.agent(id: id)?.label == "payments")
    }

    // MARK: Ignored input

    @Test(arguments: ["SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "SomethingNew"])
    func untrackedEventsSendNothingButStillNoteTheSession(hookEvent: String) throws {
        let report = report(try Fixtures.codexPayload(hookEvent, ["agent_id": "0199b000-sub", "agent_type": "explorer"]))
        #expect(report.events.isEmpty)
        #expect(report.hookEvent == hookEvent)
        #expect(report.note == CodexHookLedger.Note(session: session, subagentThread: "0199b000-sub"))
    }

    @Test(arguments: [
        "", "not json", "[]", #"{"hook_event_name":"Stop"}"#, #"{"session_id":"","hook_event_name":"Stop"}"#,
        #"{"session_id":"s"}"#, #"{"type":"agent-turn-complete","thread-id":"t"}"#,
    ])
    func malformedPayloadsAreIgnored(json: String) {
        let report = report(Data(json.utf8))
        #expect(report.events.isEmpty)
        #expect(report.note == nil)
    }

    @Test func unexpectedFieldTypesDoNotCrash() throws {
        let event = try event("PreToolUse", ["tool_name": 42, "tool_input": "a string", "agent_id": ["nested": true]])
        #expect(event.state == .working)
        #expect(event.activity == nil)
    }
}
