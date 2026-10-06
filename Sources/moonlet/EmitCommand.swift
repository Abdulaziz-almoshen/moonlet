import Foundation
import MoonletCore
import MoonletIPC

/// `moonlet emit --session ID [fields…]`: report status from a script or a custom agent.
enum EmitCommand {
    static func run(_ arguments: [String], paths: MoonletPaths) throws -> Int32 {
        var arguments = Arguments(arguments)
        guard let session = try arguments.option("--session"), !session.isEmpty else {
            throw UsageError("emit needs --session ID.")
        }
        let source = try arguments.option("--source") ?? "cli"
        let ends = arguments.flag("--end")

        var event = MoonletEvent(source: source, session: session)
        event.label = try arguments.option("--label")
        if let state = try arguments.option("--state") {
            guard let value = AgentState(rawValue: state) else {
                throw UsageError("--state must be one of: \(AgentState.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            event.state = value
        }
        event.title = try arguments.option("--title")
        event.activity = try arguments.option("--activity")
        event.summary = try arguments.option("--summary")
        event.message = try arguments.option("--message")
        event.milestone = try arguments.option("--milestone")
        event.progress = try arguments.option("--progress").map(parseProgress)
        try arguments.finish()

        if ends {
            // An end event carries nothing but the session.
            guard event == MoonletEvent(source: source, session: session, ts: event.ts) else {
                throw UsageError("--end can't be combined with other fields; send them in an update first.")
            }
            event.kind = .end
        } else {
            event.cwd = FileManager.default.currentDirectoryPath
        }

        switch MoonletClient.send(event, paths: paths, timeout: 1) {
        case .delivered:
            return 0
        case .spooled:
            Console.note("Moonlet isn't running, so the event was saved for when it starts.")
            return 0
        case .failed:
            Console.error("couldn't reach Moonlet at \(Console.displayPath(paths.socketURL.path)).")
            return 1
        }
    }

    /// `"3/7"` as 3 done out of 7.
    static func parseProgress(_ text: String) throws -> AgentProgress {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), done >= 0, total >= 0, done <= total
        else { throw UsageError("--progress must look like 3/7 (done/total).") }
        return AgentProgress(done: done, total: total)
    }
}
