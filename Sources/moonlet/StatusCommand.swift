import Foundation
import MoonletCore
import MoonletIPC

/// `moonlet status [--json]` and `moonlet summon`.
enum StatusCommand {
    static func run(_ arguments: [String], paths: MoonletPaths) throws -> Int32 {
        var arguments = Arguments(arguments)
        let json = arguments.flag("--json")
        try arguments.finish()

        guard let agents = MoonletClient.status(paths: paths, timeout: 2) else {
            Console.error("Moonlet isn't running (nothing answered at \(Console.displayPath(paths.socketURL.path))).")
            return 1
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(agents), as: UTF8.self))
        } else if agents.isEmpty {
            print("No agents.")
        } else {
            let now = Date.now
            let rows = agents.map { agent in
                [
                    agent.label,
                    agent.ended ? "\(agent.state.rawValue), ended" : agent.state.rawValue,
                    agent.progress.map { "\($0.done)/\($0.total)" } ?? "",
                    Console.age(since: agent.lastUpdate, now: now),
                    TextTools.oneLine(detail(for: agent), max: 60),
                ]
            }
            print(Console.table([["AGENT", "STATE", "PROGRESS", "UPDATED", "DETAIL"]] + rows))
        }
        return 0
    }

    static func summon(_ arguments: [String], paths: MoonletPaths) throws -> Int32 {
        try Arguments(arguments).finish()
        guard MoonletClient.summon(paths: paths, timeout: 1) else {
            Console.error("Moonlet isn't running (nothing answered at \(Console.displayPath(paths.socketURL.path))).")
            return 1
        }
        return 0
    }

    /// The most useful line about an agent in its current state.
    private static func detail(for agent: Agent) -> String {
        switch agent.state {
        case .waiting, .failed:
            agent.message ?? agent.title ?? ""
        case .done:
            agent.summary.map { TextTools.firstSentence($0) } ?? agent.title ?? ""
        case .working:
            agent.activity ?? agent.title ?? ""
        case .idle:
            agent.title ?? ""
        }
    }
}
