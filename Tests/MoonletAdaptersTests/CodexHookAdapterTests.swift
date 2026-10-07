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

    // MARK: Automatic approval review

    private let transcriptPath =
        "/Users/example/.codex/sessions/2026/10/01/rollout-2026-10-01T09-30-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl"

    /// Transcript lines shaped like Codex's rollout items, with a turn context for each
    /// reviewer setting, in order.
    private static func transcript(reviewers: [String?]) -> String {
        var items: [[String: Any]] = [
            ["timestamp": "2026-10-01T09:30:00.000Z", "type": "session_meta", "payload": ["id": Fixtures.codexSession, "cwd": "/Users/example/code/payments"]]
        ]
        for reviewer in reviewers {
            var context: [String: Any] = ["cwd": "/Users/example/code/payments", "approval_policy": "on-request", "model": "gpt-5-codex"]
            context["approvals_reviewer"] = reviewer
            items.append(["timestamp": "2026-10-01T09:31:00.000Z", "type": "turn_context", "payload": context])
            items.append([
                "timestamp": "2026-10-01T09:31:02.000Z", "type": "response_item",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": #"{"type":"turn_context"}"#]]],
            ])
        }
        return items.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0)) ?? Data(), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    private func permissionRequest(transcript tail: String?) throws -> (event: MoonletEvent, readPaths: [String]) {
        var readPaths: [String] = []
        let report = CodexHookAdapter.report(hookInput: try codex("permission-request-bash.json"), environment: [:], now: now) {
            readPaths.append($0)
            return tail
        }
        try #require(report.events.count == 1)
        return (report.events[0], readPaths)
    }

    @Test func automaticReviewKeepsTheAgentWorking() throws {
        let (event, readPaths) = try permissionRequest(transcript: Self.transcript(reviewers: ["user", "auto_review"]))
        #expect(readPaths == [transcriptPath])
        #expect(event.state == .working)
        #expect(event.activity == "Reviewing: run npm install")
        #expect(event.message == nil)
    }

    @Test(arguments: [
        CodexHookAdapterTests.transcript(reviewers: ["auto_review", "user"]),
        CodexHookAdapterTests.transcript(reviewers: [nil]),
        CodexHookAdapterTests.transcript(reviewers: []),
        // The tail starts partway through the turn context.
        #"proval_policy":"on-request","approvals_reviewer":"auto_review"}}"# + "\n",
        "",
    ])
    func otherwiseAPermissionRequestWaitsOnTheUser(tail: String) throws {
        let event = try permissionRequest(transcript: tail).event
        #expect(event.state == .waiting)
        #expect(event.message == "Wants to run npm install")
        #expect(event.activity == nil)
    }

    @Test func anUnreadableTranscriptMeansWaiting() throws {
        #expect(try permissionRequest(transcript: nil).event.state == .waiting)
        // Without a transcript path, nothing is read.
        var read = false
        let report = CodexHookAdapter.report(
            hookInput: try Fixtures.codexPayload("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]]),
            environment: [:], now: now
        ) { _ in
            read = true
            return Self.transcript(reviewers: ["auto_review"])
        }
        #expect(!read)
        #expect(report.events.first?.state == .waiting)
    }

    @Test(arguments: [
        ("Wants to edit Orders.swift", "Reviewing: edit Orders.swift"),
        ("Wants network access to registry.npmjs.org", "Reviewing: network access to registry.npmjs.org"),
        ("Wants to run swift test --filter PaymentClientTests --parallel --num-workers 8", "Reviewing: run swift test --filter PaymentClientTests…"),
        ("Needs your permission", "Reviewing a request"),
    ])
    func reviewActivityNamesTheRequest(request: String, expected: String) {
        let activity = CodexHookAdapter.reviewActivity(forRequest: request)
        #expect(activity == expected)
        #expect(activity.count <= 60)
    }

    @Test func theTranscriptTailIsBounded() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let filler = String(repeating: #"{"type":"event_msg","payload":{"type":"token_count"}}"# + "\n", count: 6000)
        try Data((Self.transcript(reviewers: ["auto_review"]) + filler).utf8).write(to: file)

        let tail = try #require(CodexTranscript.readTail(atPath: file.path))
        #expect(tail.utf8.count == CodexTranscript.tailLength)
        // The turn context is further back than the tail reaches.
        #expect(CodexTranscript.approvalsReviewer(fromTail: tail) == nil)

        try Data((filler + Self.transcript(reviewers: ["auto_review"])).utf8).write(to: file)
        let recent = try #require(CodexTranscript.readTail(atPath: file.path))
        #expect(CodexTranscript.approvalsReviewer(fromTail: recent) == "auto_review")
        #expect(CodexTranscript.readTail(atPath: file.path + ".missing") == nil)
    }

    // MARK: Tool results

    @Test func postToolUseKeepsWorking() throws {
        let event = try event("PostToolUse", ["tool_name": "apply_patch", "tool_input": ["command": "*** Begin Patch"], "tool_response": "Success"])
        #expect(event.state == .working)
        #expect(event.activity == nil)
        #expect(event.tasks == nil && event.milestone == nil)
    }

    @Test func pushingIsAMilestone() throws {
        // Codex 0.154 sends the command's output alone, without an exit code.
        #expect(try event(codex("post-tool-use-bash-push.json")).milestone == "Pushed changes")
    }

    @Test func committingIsAMilestone() throws {
        #expect(try event(codex("post-tool-use-bash-commit.json")).milestone == "Committed changes")
    }

    @Test func aRejectedPushIsNotAMilestone() throws {
        let event = try event(codex("post-tool-use-bash-push-rejected.json"))
        #expect(event.state == .working)
        #expect(event.milestone == nil)
    }

    @Test func aCommitWithNothingToCommitIsNotAMilestone() throws {
        let event = try event(codex("post-tool-use-bash-commit-failed.json"))
        #expect(event.state == .working)
        #expect(event.milestone == nil)
    }

    @Test(arguments: [
        // Commits
        ("git commit -m \"Add retries\"", "[retries 3f2a1b9] Add retries\n 2 files changed, 40 insertions(+), 3 deletions(-)\n", "Committed changes"),
        ("git commit -m init", "[main (root-commit) 3f2a1b9] init\n 1 file changed, 1 insertion(+)\n", "Committed changes"),
        ("git commit --amend --no-edit", "[detached HEAD 3f2a1b9] Fix the build\n Date: Wed Oct 7 09:53:26 2026 +0300\n", "Committed changes"),
        ("git commit -m x", "Author identity unknown\nfatal: unable to auto-detect email address (got 'me@mac.(none)')\n", nil),
        ("git commit -m x", "Sources/A.swift:3:1: error: expected declaration\nerror: pre-commit hook failed\n", nil),
        ("git commit -qm x", "", nil),
        // Pushes
        ("git push", "To github.com:example/payments.git\n   1a2b3c4..5d6e7f8  retries -> retries\n", "Pushed changes"),
        ("git push --force-with-lease", "To github.com:example/payments.git\n + 1a2b3c4...5d6e7f8 retries -> retries (forced update)\n", "Pushed changes"),
        ("git push", "Everything up-to-date\n", "Pushed changes"),
        ("git push", "To github.com:example/payments.git\n ! [remote rejected] main -> main (protected branch hook declined)\nerror: failed to push some refs to 'github.com:example/payments.git'\n", nil),
        ("git push", "fatal: The current branch retries has no upstream branch.\n", nil),
        ("git push", "Username for 'https://github.com': ", nil),
        // Pull requests
        ("gh pr create --fill", "\nCreating pull request for retries into main in example/payments\n\nhttps://github.com/example/payments/pull/42\n", "Opened a pull request"),
        ("gh pr create --fill", "a pull request for branch \"retries\" into branch \"main\" already exists:\nhttps://github.com/example/payments/pull/42\n", nil),
        ("gh pr create --fill", "pull request create failed: GraphQL: No commits between main and retries (createPullRequest)\n", nil),
        ("gh pr create --web", "Opening https://github.com/example/payments/pull/new/retries in your browser.\n", nil),
        // Several steps: the furthest one the output shows
        ("git commit -am x && git push", "[retries 3f2a1b9] x\n 1 file changed\nTo github.com:example/payments.git\n   1a2b3c4..3f2a1b9  retries -> retries\n", "Pushed changes"),
        ("git commit -am x && git push -q", "[retries 3f2a1b9] x\n 1 file changed\n", "Committed changes"),
        ("git commit -am x && git push", "[retries 3f2a1b9] x\nTo github.com:example/payments.git\n ! [rejected]        retries -> retries (non-fast-forward)\nerror: failed to push some refs\n", nil),
        // Output that looks right for a command that isn't a milestone
        ("git log -1 --format='[%D %h] %s'", "[main 3f2a1b9] x\n", nil),
        // An exit code header, as earlier Codex versions send, decides on its own.
        ("git push -q", "Exit code: 0\nWall time: 1 seconds\nOutput:\n", "Pushed changes"),
        ("git push", "Exit code: 128\nOutput:\nfatal: no upstream", nil),
        ("git commit -m x", "Chunk ID: a\nWall time: 0.1 seconds\nProcess exited with code 1\nOutput:\n[main 3f2a1b9] x\n", nil),
    ] as [(String, String, String?)])
    func milestonesNeedOutputThatShowsTheStepWorked(command: String, output: String, expected: String?) throws {
        let event = try event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": command], "tool_response": output])
        #expect(event.state == .working)
        #expect(event.milestone == expected)
    }

    @Test func aResultWithoutOutputIsNotAMilestone() throws {
        let response: [String: Any] = ["exit_code": 0, "stdout": "[main 3f2a1b9] x"]
        #expect(try event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "git commit -m x"], "tool_response": response]).milestone == nil)
        #expect(try event("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "git commit -m x"]]).milestone == nil)
    }

    @Test(arguments: [
        ("Exit code: 0\nWall time: 1 seconds\nOutput:\n", 0),
        ("Exit code: 128\nOutput:\nfatal", 128),
        ("Chunk ID: a\nWall time: 0.1 seconds\nProcess exited with code 2\nOutput:\n", 2),
        ("plain output without a header", nil),
        ("Exit code: unknown\n", nil),
    ] as [(String, Int?)])
    func exitCodesComeFromTheHeader(output: String, code: Int?) {
        #expect(CodexHookAdapter.exitCode(in: output) == code)
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
