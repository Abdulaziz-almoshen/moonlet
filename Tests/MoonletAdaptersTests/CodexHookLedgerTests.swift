import Foundation
import MoonletCore
import Testing

@testable import MoonletAdapters

@Suite("CodexHookLedger")
struct CodexHookLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let session = Fixtures.codexSession

    /// A ledger in a fresh temporary directory, removed after `body`.
    private func withLedger(_ body: (CodexHookLedger) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "codex-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(CodexHookLedger(directory: directory.appending(path: "codex-hooks")))
    }

    private func notify(thread: String, turn: String, message: String = "Done.") -> String {
        #"{"type":"agent-turn-complete","thread-id":"\#(thread)","turn-id":"\#(turn)","input-messages":["Go"],"last-assistant-message":"\#(message)"}"#
    }

    @Test func remembersSessionsTheirFinishedTurnsAndSubagents() throws {
        try withLedger { ledger in
            #expect(ledger.record(forThread: session) == nil)
            #expect(ledger.lastActivity == nil)

            ledger.write(.init(session: session))
            #expect(ledger.record(forThread: session) == .session(finishedTurn: nil))

            ledger.write(.init(session: session, finishedTurn: "7"))
            #expect(ledger.record(forThread: session) == .session(finishedTurn: "7"))

            // Later events in the session keep the finished turn.
            ledger.write(.init(session: session, subagentThread: "0199b000-sub"))
            #expect(ledger.record(forThread: session) == .session(finishedTurn: "7"))
            #expect(ledger.record(forThread: "0199b000-sub") == .subagent)
            #expect(ledger.lastActivity != nil)

            let attributes = try FileManager.default.attributesOfItem(atPath: ledger.directory.path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
    }

    @Test func aDamagedEntryStillMeansTheSessionReportsThroughHooks() throws {
        try withLedger { ledger in
            ledger.write(.init(session: session))
            let file = ledger.directory.appending(path: CodexHookLedger.fileName(forThread: session))
            try Data().write(to: file)
            #expect(ledger.record(forThread: session) == .session(finishedTurn: nil))
        }
    }

    @Test func pruneRemovesEntriesUntouchedForAWeek() throws {
        try withLedger { ledger in
            ledger.write(.init(session: "old"))
            ledger.write(.init(session: "fresh"))
            let old = ledger.directory.appending(path: "old")
            try FileManager.default.setAttributes(
                [.modificationDate: Date.now.addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: old.path)
            ledger.prune(now: .now)
            #expect(ledger.record(forThread: "old") == nil)
            #expect(ledger.record(forThread: "fresh") == .session(finishedTurn: nil))
        }
    }

    @Test(arguments: [
        ("0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"),
        ("thr_123", "thr_123"),
        ("../../etc/passwd", "id-.._.._etc_passwd"),
        ("a/b c", "a_b_c"),
        ("", "id-"),
        ("café", "caf_"),
    ])
    func fileNamesStayInsideTheDirectory(thread: String, expected: String) {
        #expect(CodexHookLedger.fileName(forThread: thread) == expected)
    }

    @Test func anUnwritableDirectoryIsHarmless() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "not-a-directory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)
        let ledger = CodexHookLedger(directory: file.appending(path: "codex-hooks"))
        ledger.write(.init(session: session, finishedTurn: "1"))
        ledger.prune(now: now)
        #expect(ledger.record(forThread: session) == nil)
        #expect(ledger.lastActivity == nil)
    }

    @Test(arguments: [
        (nil, "7", false),
        (CodexHookLedger.Record.session(finishedTurn: nil), "7", false),
        (.session(finishedTurn: "6"), "7", false),
        (.session(finishedTurn: "7"), "7", true),
        (.session(finishedTurn: "7"), nil, false),
        (.subagent, "7", true),
    ] as [(CodexHookLedger.Record?, String?, Bool)])
    func notifySkipsOnlyWhatTheHooksReported(record: CodexHookLedger.Record?, turn: String?, skipped: Bool) {
        #expect(CodexHookLedger.hooksReported(record, turn: turn) == skipped)
    }

    // MARK: Hooks and notify together

    @Test func aTurnReportedByBothHooksAndNotifyFinishesOnce() throws {
        try withLedger { ledger in
            var store = AgentStore()
            var finished = 0
            func apply(_ events: [MoonletEvent]) {
                for event in events {
                    finished += store.apply(event, now: now).count { if case .finished = $0 { true } else { false } }
                }
            }
            for name in ["session-start.json", "user-prompt-submit.json", "stop.json"] {
                let report = CodexHookAdapter.report(hookInput: try Fixtures.data(name, in: "codex"), environment: [:], now: now)
                ledger.write(try #require(report.note))
                apply(report.events)
            }
            // Codex then runs its notify program for the same turn.
            apply(CodexAdapter.events(notifyArgument: notify(thread: session, turn: "7"), environment: [:], now: now) {
                ledger.record(forThread: $0)
            })
            #expect(finished == 1)
            #expect(store.agents.count == 1)
            #expect(store.agents.first?.summary == "Added retries with exponential backoff to PaymentClient. All 42 tests pass.")
        }
    }

    @Test func notifyStillReportsATurnTheHooksMissed() throws {
        try withLedger { ledger in
            ledger.write(.init(session: session, finishedTurn: "7"))
            let events = CodexAdapter.events(notifyArgument: notify(thread: session, turn: "8"), environment: [:], now: now) {
                ledger.record(forThread: $0)
            }
            #expect(events.map(\.state) == [.working, .done])
            #expect(events.last?.summary == "Done.")
        }
    }

    @Test func notifySkipsASubagentsTurnAndReportsUnknownThreads() throws {
        try withLedger { ledger in
            ledger.write(.init(session: session, subagentThread: "0199b000-sub"))
            let lookup = { (thread: String) in ledger.record(forThread: thread) }
            #expect(CodexAdapter.events(notifyArgument: notify(thread: "0199b000-sub", turn: "1"), environment: [:], now: now, hookRecord: lookup).isEmpty)
            #expect(CodexAdapter.events(notifyArgument: notify(thread: "elsewhere", turn: "1"), environment: [:], now: now, hookRecord: lookup).count == 2)
        }
    }
}
