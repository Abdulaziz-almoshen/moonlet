import Foundation
import MoonletCore
import Testing

@testable import MoonletAdapters

@Suite("CodexAdapter")
struct CodexAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func turnCompleteBecomesAWorkingTurnThatFinishes() throws {
        let events = CodexAdapter.events(
            notifyArgument: try Fixtures.text("agent-turn-complete.json", in: "codex"),
            environment: ["TERM_PROGRAM": "ghostty"], now: now)
        try #require(events.count == 2)
        let (started, finished) = (events[0], events[1])
        #expect(started.source == "codex")
        #expect(started.session == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        #expect(started.state == .working)
        #expect(started.title == "Rename PaymentError to PaymentFailure everywhere")
        #expect(started.cwd == "/Users/example/code/payments")
        #expect(started.host == HostInfo(termProgram: "ghostty"))
        #expect(finished.session == started.session)
        #expect(finished.state == .done)
        #expect(finished.summary == "Renamed PaymentError to PaymentFailure in 14 files. The build and tests pass.")
    }

    @Test func eachTurnSignalsFinishedInTheStore() throws {
        let payload = try Fixtures.text("agent-turn-complete.json", in: "codex")
        var store = AgentStore()
        var finished = 0
        for turn in 0..<2 {
            for event in CodexAdapter.events(notifyArgument: payload, environment: [:], now: now) {
                let signals = store.apply(event, now: now.addingTimeInterval(Double(turn)))
                finished += signals.count { if case .finished = $0 { true } else { false } }
            }
        }
        #expect(finished == 2)
        #expect(store.agents.count == 1)
    }

    @Test func sessionFallsBackToTurnIdThenCodex() {
        let byTurn = CodexAdapter.events(notifyArgument: #"{"type":"agent-turn-complete","turn-id":"7"}"#, environment: [:], now: now)
        #expect(byTurn.first?.session == "7")
        let bare = CodexAdapter.events(notifyArgument: #"{"type":"agent-turn-complete"}"#, environment: [:], now: now)
        #expect(bare.first?.session == "codex")
        #expect(bare.first?.title == nil)
        #expect(bare.last?.summary == nil)
    }

    @Test func cwdFallsBackToPWD() {
        let events = CodexAdapter.events(
            notifyArgument: #"{"type":"agent-turn-complete","thread-id":"t"}"#, environment: ["PWD": "/Users/example/code/web"],
            now: now)
        #expect(events.first?.cwd == "/Users/example/code/web")
    }

    @Test(arguments: [#"{"type":"approval-requested","thread-id":"t"}"#, "not json", "", "[]"])
    func otherPayloadsAreIgnored(argument: String) {
        #expect(CodexAdapter.events(notifyArgument: argument, environment: [:], now: now).isEmpty)
    }
}

@Suite("ClaudeTranscript")
struct ClaudeTranscriptTests {
    @Test func lastAssistantTextJoinsTheBlocksOfTheLastMessage() throws {
        let tail = try Fixtures.text("transcript-tail.jsonl")
        #expect(ClaudeTranscript.lastAssistantText(fromTail: tail) == "Fixed the race in `LoginViewModel`.\n\nAll 128 tests pass.")
    }

    @Test func messagesThatEndWithAToolCallUseTheirText() {
        let tail = """
            {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Earlier."}]}}
            {"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Checking one more thing."}]}}
            {"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]}}
            """
        #expect(ClaudeTranscript.lastAssistantText(fromTail: tail) == "Checking one more thing.")
    }

    @Test func stringContentIsAccepted() {
        let tail = #"{"type":"assistant","message":{"role":"assistant","content":"Plain text reply."}}"#
        #expect(ClaudeTranscript.lastAssistantText(fromTail: tail) == "Plain text reply.")
    }

    @Test(arguments: ["", "partial line without json", #"{"type":"user","message":{"content":"hi"}}"#])
    func tailsWithoutAssistantTextHaveNone(tail: String) {
        #expect(ClaudeTranscript.lastAssistantText(fromTail: tail) == nil)
    }

    @Test func readTailReadsOnlyTheEndOfTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((String(repeating: "x", count: 1000) + "\nlast line\n").utf8).write(to: url)
        #expect(ClaudeTranscript.readTail(atPath: url.path, maxBytes: 11) == "\nlast line\n")
        #expect(ClaudeTranscript.readTail(atPath: url.path)?.count == 1011)
        #expect(ClaudeTranscript.readTail(atPath: url.path + ".missing") == nil)
    }
}

@Suite("HostDetector")
struct HostDetectorTests {
    @Test func combinesTheEnvironmentWithTheProcessTable() {
        let host = HostDetector.detect(environment: ["TERM_PROGRAM": "Apple_Terminal"], parentPID: getpid())
        #expect(host.termProgram == "Apple_Terminal")
        #expect(host.pid == getpid())
    }

    @Test func unknownProcessesKeepTheEnvironmentOnly() {
        let host = HostDetector.detect(environment: ["__CFBundleIdentifier": "com.apple.Terminal"], parentPID: 999_999)
        #expect(host == HostInfo(bundleID: "com.apple.Terminal"))
    }
}
