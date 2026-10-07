import Foundation
import MoonletAdapters
import MoonletCore
import MoonletIPC

/// `moonlet hook claude-code`, `moonlet hook codex`, and
/// `moonlet hook codex [--then <cmd> <args…>] <json>`.
///
/// `hook claude-code` and a bare `hook codex` are hooks: they read one JSON payload from
/// stdin. `hook codex` followed by arguments is Codex's notify program, which gets its
/// payload as the last argument. Agents run these on every step, so they never write to
/// stdout (an agent may read it as instructions), always exit 0 (a failure must never
/// block the agent), and give up on the app well within a third of a second.
enum HookCommand {
    /// Total time allowed for delivering events, measured from launch.
    private static let budget: TimeInterval = 0.28

    static func run(_ arguments: [String]) -> Never {
        let start = Date.now
        let environment = ProcessInfo.processInfo.environment
        let paths = MoonletPaths(environment: environment)
        let log = HookLog(paths: paths, enabled: environment["MOONLET_DEBUG"] == "1")
        let host = HostDetector.detect(environment: environment)

        let events: [MoonletEvent]
        switch arguments.first {
        case "claude-code":
            let input = StandardInput.read(limit: 64 * 1024 * 1024, timeout: 1)
            events = ClaudeCodeAdapter.events(hookInput: input, environment: environment, now: .now, host: host) {
                ClaudeTranscript.readTail(atPath: $0)
            }
            if events.isEmpty, (try? JSONSerialization.jsonObject(with: input)) == nil {
                log.write("claude-code: stdin isn't a JSON payload (\(input.count) bytes)")
            }
        case "codex" where arguments.count == 1:
            events = codexHookEvents(environment: environment, host: host, paths: paths, log: log)
        case "codex":
            events = codexNotifyEvents(Array(arguments.dropFirst()), environment: environment, host: host, paths: paths, log: log)
        default:
            log.write("Unknown hook \(arguments.first.map { "'\($0)'" } ?? "(none)")")
            events = []
        }

        for event in events {
            let remaining = max(budget - Date.now.timeIntervalSince(start), 0.02)
            if MoonletClient.send(event, paths: paths, timeout: remaining) == .failed {
                log.write("Couldn't deliver or spool a \(event.kind.rawValue) event for \(event.agentID)")
            }
        }
        exit(0)
    }

    /// A Codex hook: the payload arrives on stdin. The ledger notes the session first, so
    /// the notify call that follows a `Stop` finds the turn already reported.
    private static func codexHookEvents(
        environment: [String: String], host: HostInfo, paths: MoonletPaths, log: HookLog
    ) -> [MoonletEvent] {
        let input = StandardInput.read(limit: 64 * 1024 * 1024, timeout: 1)
        let report = CodexHookAdapter.report(hookInput: input, environment: environment, now: .now, host: host)
        guard let note = report.note else {
            log.write("codex: stdin isn't a hook payload (\(input.count) bytes)")
            return []
        }
        let ledger = CodexHookLedger(directory: paths.codexHooksDirectory)
        ledger.write(note)
        if report.hookEvent == "SessionStart" {
            ledger.prune(now: .now)
        }
        return report.events
    }

    /// Codex's notify program: the payload is the last argument. A chained notify command
    /// is started first, with the same payload, so Moonlet never delays it. Turns the
    /// hooks already reported are skipped.
    private static func codexNotifyEvents(
        _ arguments: [String], environment: [String: String], host: HostInfo, paths: MoonletPaths, log: HookLog
    ) -> [MoonletEvent] {
        guard let payload = arguments.last else {
            log.write("codex: no JSON payload argument")
            return []
        }
        if arguments.first == "--then", arguments.count > 2 {
            let chained = Array(arguments[1..<(arguments.count - 1)])
            do {
                try Processes.spawnDetached(chained + [payload])
            } catch {
                log.write("codex: couldn't start the chained notify command: \(error)")
            }
        }
        let ledger = CodexHookLedger(directory: paths.codexHooksDirectory)
        return CodexAdapter.events(notifyArgument: payload, environment: environment, now: .now, host: host) {
            ledger.record(forThread: $0)
        }
    }
}

/// Reads a hook's stdin without hanging when it's a terminal or never closed.
enum StandardInput {
    static func read(limit: Int, timeout: TimeInterval) -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        let deadline = Date.now.addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while data.count < limit {
            let milliseconds = Int32(max(deadline.timeIntervalSinceNow, 0) * 1000)
            guard milliseconds > 0 else { break }
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR {
                continue
            }
            guard ready > 0 else { break }
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break
            }
        }
        return data
    }
}

/// Hook diagnostics, written only when `MOONLET_DEBUG=1`, to `hook.log` in the logs
/// directory. The log keeps its newest half once it passes 256 KiB.
struct HookLog {
    private static let limit = 256 * 1024
    private let url: URL?

    init(paths: MoonletPaths, enabled: Bool) {
        url = enabled ? paths.logsDirectory.appending(path: "hook.log", directoryHint: .notDirectory) : nil
    }

    func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date.now.ISO8601Format()) [\(getpid())] \(message)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = (try? FileHandle(forWritingTo: url)) ?? createFile(at: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        try? handle.write(contentsOf: Data(line.utf8))
        if Int(size) + line.utf8.count > Self.limit, let data = try? Data(contentsOf: url) {
            let tail = data.suffix(Self.limit / 2)
            let wholeLines = tail.firstIndex(of: 0x0A).map { tail[($0 + 1)...] } ?? tail
            try? Data(wholeLines).write(to: url, options: .atomic)
        }
    }

    private func createFile(at url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return try? FileHandle(forWritingTo: url)
    }
}
