import Foundation
import MoonletCore

/// Turns Codex `notify` payloads into Moonlet events.
///
/// Codex runs the `notify` command with one JSON argument after each turn:
/// `{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…,
/// "input-messages":[…],"last-assistant-message":…}`.
public enum CodexAdapter {
    /// The `source` of every event this adapter produces.
    public static let source = "codex"

    /// The events for one notify payload; empty unless it's an `agent-turn-complete`.
    ///
    /// Codex reports nothing until a turn ends, so a completed turn becomes two events:
    /// a `working` update carrying the request as `title`, then `done` with the reply as
    /// `summary`. That way every turn finishes from a working state, and the store
    /// signals each one.
    public static func events(
        notifyArgument: String,
        environment: [String: String],
        now: Date,
        host: HostInfo? = nil
    ) -> [MoonletEvent] {
        guard let payload = JSONFields(data: Data(notifyArgument.utf8)),
            payload.string("type") == "agent-turn-complete"
        else { return [] }

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
