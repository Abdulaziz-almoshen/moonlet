import Foundation
import MoonletCore

/// Turns Codex `notify` payloads into Moonlet events.
///
/// Codex runs the `notify` command with one JSON argument after each turn:
/// `{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…,
/// "input-messages":[…],"last-assistant-message":…}`. Codex versions with hooks report
/// through `CodexHookAdapter` instead; notify stays the fallback for sessions whose hooks
/// don't run.
public enum CodexAdapter {
    /// The `source` of every event this adapter and `CodexHookAdapter` produce.
    public static let source = "codex"

    /// The events for one notify payload; empty unless it's an `agent-turn-complete` that
    /// the hooks haven't already reported.
    ///
    /// Notify reports nothing until a turn ends, so a completed turn becomes two events:
    /// a `working` update carrying the request as `title`, then `done` with the reply as
    /// `summary`. That way every turn finishes from a working state, and the store
    /// signals each one.
    ///
    /// - Parameter hookRecord: What `CodexHookLedger` knows about a thread id. A turn the
    ///   hooks already finished, or a subagent's turn, produces no events.
    public static func events(
        notifyArgument: String,
        environment: [String: String],
        now: Date,
        host: HostInfo? = nil,
        hookRecord: (String) -> CodexHookLedger.Record? = { _ in nil }
    ) -> [MoonletEvent] {
        guard let payload = JSONFields(data: Data(notifyArgument.utf8)),
            payload.string("type") == "agent-turn-complete"
        else { return [] }

        if let thread = payload.nonEmptyString("thread-id"),
            CodexHookLedger.hooksReported(hookRecord(thread), turn: payload.nonEmptyString("turn-id"))
        {
            return []
        }

        let session = payload.nonEmptyString("thread-id") ?? payload.nonEmptyString("turn-id") ?? "codex"
        let host = host ?? HostInfo(environment: environment)
        let cwd = payload.nonEmptyString("cwd") ?? environment["PWD"].flatMap { $0.isEmpty ? nil : $0 }
        let request = (payload.array("input-messages") as? [String])?.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var started = MoonletEvent(
            source: source, session: session, state: .working, cwd: cwd,
            host: host.isEmpty ? nil : host, ts: now.timeIntervalSince1970)
        started.title = request.map { TextTools.firstLine(of: $0, max: 80) }

        var finished = MoonletEvent(source: source, session: session, state: .done, ts: now.timeIntervalSince1970)
        finished.summary = payload.nonEmptyString("last-assistant-message")
        return [started, finished]
    }
}
