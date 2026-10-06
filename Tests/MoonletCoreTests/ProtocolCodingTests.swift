import Foundation
import Testing

@testable import MoonletCore

@Suite("Wire protocol")
struct ProtocolCodingTests {
    private let fullEvent = MoonletEvent(
        source: "claude-code",
        session: "6f1c2e",
        label: "api",
        state: .working,
        title: "Fix the flaky login test",
        activity: "Reading LoginTests.swift",
        summary: "Done.",
        message: "Needs permission for Bash",
        milestone: "Committed changes",
        tasks: [TaskItem(id: "1", title: "Reproduce", status: .completed)],
        task: TaskItem(id: "2", title: "Fix", status: .inProgress),
        progress: AgentProgress(done: 1, total: 3),
        cwd: "/Users/example/code/api",
        host: HostInfo(bundleID: "com.apple.Terminal", termProgram: "Apple_Terminal", tty: "/dev/ttys003", pid: 4242),
        ts: 1_790_000_000.25
    )

    @Test func eventRoundTrips() throws {
        let decoded = try JSONDecoder().decode(MoonletEvent.self, from: JSONEncoder().encode(fullEvent))
        #expect(decoded == fullEvent)
    }

    @Test func eventDecodesSnakeCaseWireKeys() throws {
        let json = """
            {"v":1,"kind":"update","source":"cli","session":"s","state":"waiting","ts":12.5,
             "tasks":[{"id":"a","title":"A","status":"in_progress"}],
             "host":{"bundle_id":"com.googlecode.iterm2","term_program":"iTerm.app","tty":"/dev/ttys004","pid":7}}
            """
        let event = try JSONDecoder().decode(MoonletEvent.self, from: Data(json.utf8))
        #expect(event.state == .waiting)
        #expect(event.tasks == [TaskItem(id: "a", title: "A", status: .inProgress)])
        #expect(event.host == HostInfo(bundleID: "com.googlecode.iterm2", termProgram: "iTerm.app", tty: "/dev/ttys004", pid: 7))
    }

    @Test func encodedLineIsCompactAndOmitsMissingFields() throws {
        let line = try MoonletEvent(source: "cli", session: "s", ts: 1).encodedLine()
        #expect(String(decoding: line, as: UTF8.self) == #"{"kind":"update","session":"s","source":"cli","ts":1,"v":1}"# + "\n")
    }

    @Test func hostEncodesSnakeCaseKeys() throws {
        let json = String(decoding: try JSONEncoder.wire().encode(fullEvent.host), as: UTF8.self)
        #expect(json == #"{"bundle_id":"com.apple.Terminal","pid":4242,"term_program":"Apple_Terminal","tty":"/dev/ttys003"}"#)
    }

    @Test func unknownFieldsAreIgnored() throws {
        let json = #"{"v":1,"kind":"end","source":"cli","session":"s","ts":3,"added_in_v1_5":{"x":1}}"#
        let event = try JSONDecoder().decode(MoonletEvent.self, from: Data(json.utf8))
        #expect(event.kind == .end)
    }

    @Test(arguments: [
        #"{"v":2,"kind":"update","source":"cli","session":"s","ts":1}"#,
        #"{"kind":"update","source":"cli","session":"s","ts":1}"#,
        #"{"v":1,"kind":"update","source":"","session":"s","ts":1}"#,
        #"{"v":1,"kind":"update","source":"cli","session":"","ts":1}"#,
        #"{"v":1,"kind":"pause","source":"cli","session":"s","ts":1}"#,
        #"{"v":1,"kind":"update","source":"cli","session":"s"}"#,
        #"{"v":1,"kind":"update","source":"cli","session":"s","state":"sleeping","ts":1}"#,
    ])
    func invalidEventsAreRejected(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MoonletEvent.self, from: Data(json.utf8))
        }
    }

    @Test func envelopesRoundTripAsSingleLines() throws {
        let agent = Agent(source: "cli", session: "s", label: "s", firstSeen: Date(timeIntervalSince1970: 100))
        let envelopes: [Envelope] = [.event(fullEvent), .statusRequest, .statusReply([agent]), .summon]
        for envelope in envelopes {
            let line = try envelope.encodedLine()
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(try Envelope(line: line) == envelope)
        }
    }

    @Test func statusRequestAndReplyShareATypeTag() throws {
        #expect(try Envelope(line: Data(#"{"type":"status"}"#.utf8)) == .statusRequest)
        #expect(try Envelope(line: Data(#"{"type":"status","agents":[]}"#.utf8)) == .statusReply([]))
        #expect(String(decoding: try Envelope.statusRequest.encodedLine(), as: UTF8.self) == "{\"type\":\"status\"}\n")
        #expect(String(decoding: try Envelope.summon.encodedLine(), as: UTF8.self) == "{\"type\":\"summon\"}\n")
    }

    @Test func eventEnvelopeNestsTheEvent() throws {
        let line = try Envelope.event(MoonletEvent(source: "cli", session: "s", ts: 1)).encodedLine()
        let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(object["type"] as? String == "event")
        #expect((object["event"] as? [String: Any])?["session"] as? String == "s")
    }

    @Test func unknownEnvelopeTypesAreRejected() {
        #expect(throws: DecodingError.self) { try Envelope(line: Data(#"{"type":"reboot"}"#.utf8)) }
    }

    @Test func agentEncodesUnixDatesAndEffectiveProgress() throws {
        let agent = Agent(
            source: "codex", session: "t", label: "t",
            tasks: [TaskItem(id: "1", title: "A", status: .completed), TaskItem(id: "2", title: "B")],
            firstSeen: Date(timeIntervalSince1970: 1000))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any])
        #expect(object["id"] as? String == "codex:t")
        #expect(object["first_seen"] as? Double == 1000)
        #expect(object["state_changed_at"] as? Double == 1000)
        #expect(object["progress"] as? [String: Int] == ["done": 1, "total": 2])

        let decoded = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(decoded.progress == agent.progress)
        #expect(decoded.firstSeen == agent.firstSeen)
        #expect(decoded.tasks == agent.tasks)
    }

    @Test func progressFromTasks() {
        #expect(AgentProgress(tasks: []) == nil)
        let tasks = [
            TaskItem(id: "1", title: "A", status: .completed), TaskItem(id: "2", title: "B", status: .inProgress),
            TaskItem(id: "3", title: "C"), TaskItem(id: "4", title: "D", status: .completed),
        ]
        #expect(AgentProgress(tasks: tasks) == AgentProgress(done: 2, total: 4))
        #expect(AgentProgress(done: 3, total: 4).fraction == 0.75)
        #expect(AgentProgress(done: 9, total: 4).fraction == 1)
        #expect(AgentProgress(done: 1, total: 0).fraction == 0)
    }

    @Test func hostInfoFromEnvironment() {
        let host = HostInfo(environment: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "TERM_PROGRAM": "", "PATH": "/bin"])
        #expect(host == HostInfo(bundleID: "com.mitchellh.ghostty"))
        #expect(HostInfo(environment: [:]).isEmpty)
    }

    @Test func signalsKnowTheirAgent() {
        let signals: [Signal] = [
            .needsYou(agentID: "a", message: nil), .resolved(agentID: "a"), .finished(agentID: "a", summary: nil),
            .failed(agentID: "a", message: nil), .milestone(agentID: "a", text: "x"), .progressChanged(agentID: "a"),
            .appeared(agentID: "a"), .ended(agentID: "a"),
        ]
        #expect(signals.allSatisfy { $0.agentID == "a" })
    }
}
