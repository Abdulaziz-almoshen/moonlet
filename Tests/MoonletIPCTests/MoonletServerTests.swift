import Foundation
import MoonletCore
import Testing

@testable import MoonletIPC

@Suite("MoonletServer and MoonletClient")
struct MoonletServerTests {
    private func startServer(
        in home: TemporaryHome, events: Recorder<MoonletEvent> = Recorder()
    ) throws -> MoonletServer {
        let server = MoonletServer(paths: home.paths)
        server.onEvent = { events.append($0) }
        try server.start()
        return server
    }

    @Test func clientDeliversEventsToTheHandler() async throws {
        let home = try TemporaryHome()
        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }

        let event = MoonletEvent(source: "claude-code", session: "s1", state: .working, activity: "Reading a.swift", ts: 1)
        let result = await offload { MoonletClient.send(event, paths: home.paths) }
        #expect(result == .delivered)
        #expect(await events.wait(for: 1) == [event])
    }

    @Test func statusReplyReflectsEarlierEvents() async throws {
        let home = try TemporaryHome()
        let store = LockedStore()
        let server = MoonletServer(paths: home.paths)
        server.onEvent = { store.apply($0) }
        server.onStatus = { store.agents }
        try server.start()
        defer { server.stop() }

        let connection = try RawConnection(paths: home.paths)
        defer { connection.close() }
        #expect(connection.write(eventLine(session: "a") + eventLine(session: "b") + #"{"type":"status"}"# + "\n"))
        let reply = try #require(connection.readLine())
        guard case .statusReply(let agents) = try Envelope(line: Data(reply.utf8)) else {
            Issue.record("Expected a status reply, got \(reply)")
            return
        }
        #expect(agents.map(\.id) == ["cli:a", "cli:b"])
    }

    @Test func clientStatusAndSummon() async throws {
        let home = try TemporaryHome()
        let summons = Recorder<Bool>()
        let server = MoonletServer(paths: home.paths)
        let agent = Agent(source: "cli", session: "x", label: "x", firstSeen: Date(timeIntervalSince1970: 5))
        server.onStatus = { [agent] }
        server.onSummon = { summons.append(true) }
        try server.start()
        defer { server.stop() }

        #expect(await offload { MoonletClient.status(paths: home.paths) } == [agent])
        #expect(await offload { MoonletClient.summon(paths: home.paths) })
        #expect(await summons.wait(for: 1).count == 1)
    }

    @Test func handlesManyConcurrentClients() async throws {
        let home = try TemporaryHome()
        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }

        let paths = home.paths
        let results = await offload {
            let results = Recorder<MoonletClient.SendResult>()
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                results.append(MoonletClient.send(MoonletEvent(source: "cli", session: "s\(index)", ts: 1), paths: paths, timeout: 2))
            }
            return results.values
        }
        #expect(results.count == 64)
        #expect(results.allSatisfy { $0 == .delivered })
        let sessions = Set(await events.wait(for: 64).map(\.session))
        #expect(sessions == Set((0..<64).map { "s\($0)" }))
    }

    @Test func reassemblesLinesSplitAcrossWrites() async throws {
        let home = try TemporaryHome()
        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }

        let connection = try RawConnection(paths: home.paths)
        defer { connection.close() }
        let line = eventLine(session: "split")
        let middle = line.index(line.startIndex, offsetBy: line.count / 2)
        #expect(connection.write(String(line[..<middle])))
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.write(String(line[middle...]) + eventLine(session: "next")))
        #expect(await events.wait(for: 2).map(\.session) == ["split", "next"])
    }

    @Test func dropsOversizedAndMalformedLinesButKeepsTheConnection() async throws {
        let home = try TemporaryHome()
        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }

        let connection = try RawConnection(paths: home.paths)
        defer { connection.close() }
        let oversized = Data(repeating: UInt8(ascii: "x"), count: Envelope.maxLineLength + 10_000) + Data("\n".utf8)
        #expect(connection.write(oversized))
        #expect(connection.write("not json\n\n{\"type\":\"teleport\"}\n" + eventLine(session: "after")))
        #expect(await events.wait(for: 1).map(\.session) == ["after"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.values.count == 1)
    }

    @Test func acceptsALineExactlyAtTheLimit() async throws {
        let home = try TemporaryHome()
        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }

        var event = MoonletEvent(source: "cli", session: "big", ts: 1)
        event.summary = ""
        let overhead = try Envelope.event(event).encodedLine().count - 1
        event.summary = String(repeating: "a", count: Envelope.maxLineLength - overhead)
        let line = try Envelope.event(event).encodedLine()
        #expect(line.count - 1 == Envelope.maxLineLength)

        let connection = try RawConnection(paths: home.paths)
        defer { connection.close() }
        #expect(connection.write(line))
        #expect(await events.wait(for: 1).first?.summary?.count == event.summary?.count)
    }

    @Test func answersAClientThatStopsWritingBeforeTheReply() async throws {
        let home = try TemporaryHome()
        let server = MoonletServer(paths: home.paths)
        server.onStatus = {
            try? await Task.sleep(for: .milliseconds(50))
            return []
        }
        try server.start()
        defer { server.stop() }

        let connection = try RawConnection(paths: home.paths)
        defer { connection.close() }
        #expect(connection.write(#"{"type":"status"}"#))
        connection.finishWriting()
        #expect(connection.readLine() == #"{"agents":[],"type":"status"}"#)
    }

    @Test func socketAndDirectoryArePrivate() throws {
        let home = try TemporaryHome()
        let server = try startServer(in: home)
        defer { server.stop() }

        let socket = try FileManager.default.attributesOfItem(atPath: home.paths.socketURL.path)
        #expect(socket[.posixPermissions] as? Int == 0o600)
        #expect(socket[.type] as? FileAttributeType == .typeSocket)
        let directory = try FileManager.default.attributesOfItem(atPath: home.url.path)
        #expect(directory[.posixPermissions] as? Int == 0o700)
    }

    @Test func refusesToStartWhileAnotherServerAnswers() throws {
        let home = try TemporaryHome()
        let first = try startServer(in: home)
        defer { first.stop() }

        #expect(throws: MoonletServer.Error.alreadyRunning) { try MoonletServer(paths: home.paths).start() }
        #expect(first.isRunning)
    }

    @Test func replacesAStaleSocketFile() async throws {
        let home = try TemporaryHome()
        let path = home.paths.socketURL.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let address = try #require(UnixSocket.address(for: path))
        #expect(UnixSocket.withSockaddr(address) { bind(fd, $0, $1) } == 0)
        close(fd)  // Leaves the file behind, like a crashed app.
        #expect(FileManager.default.fileExists(atPath: path))

        let events = Recorder<MoonletEvent>()
        let server = try startServer(in: home, events: events)
        defer { server.stop() }
        #expect(await offload { MoonletClient.send(MoonletEvent(source: "cli", session: "s", ts: 1), paths: home.paths) } == .delivered)
    }

    @Test func stopRemovesTheSocketAndAllowsARestart() async throws {
        let home = try TemporaryHome()
        let server = try startServer(in: home)
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: home.paths.socketURL.path))

        let events = Recorder<MoonletEvent>()
        server.onEvent = { events.append($0) }
        try server.start()
        defer { server.stop() }
        #expect(await offload { MoonletClient.send(MoonletEvent(source: "cli", session: "again", ts: 1), paths: home.paths) } == .delivered)
        #expect(await events.wait(for: 1).map(\.session) == ["again"])
    }

    @Test func rejectsASocketPathThatIsTooLong() throws {
        let home = try TemporaryHome()
        let paths = MoonletPaths(supportDirectory: home.url.appending(path: String(repeating: "d", count: 100)))
        #expect(throws: MoonletPaths.Error.self) { try MoonletServer(paths: paths).start() }
        #expect(!FileManager.default.fileExists(atPath: paths.supportDirectory.path))
    }

    // MARK: Client without a server

    @Test func sendSpoolsWhenTheAppIsNotRunning() throws {
        let home = try TemporaryHome()
        let event = MoonletEvent(source: "codex", session: "t", state: .done, ts: 1)
        #expect(MoonletClient.send(event, paths: home.paths) == .spooled)
        #expect(try Spool(url: home.paths.spoolURL).drain() == [event])
    }

    @Test func sendCanSkipTheSpool() throws {
        let home = try TemporaryHome()
        let event = MoonletEvent(source: "cli", session: "t", ts: 1)
        #expect(MoonletClient.send(event, paths: home.paths, spoolIfUnavailable: false) == .failed)
        #expect(try Spool(url: home.paths.spoolURL).drain().isEmpty)
    }

    @Test func statusAndSummonReportAnAbsentApp() throws {
        let home = try TemporaryHome()
        #expect(MoonletClient.status(paths: home.paths) == nil)
        #expect(!MoonletClient.summon(paths: home.paths))
    }

    @Test func oversizedSummariesAreShortenedToFitALine() throws {
        var event = MoonletEvent(source: "cli", session: "s", state: .done, ts: 1)
        event.summary = String(repeating: "é", count: 100_000)
        let (fitted, line) = try MoonletClient.fitted(event)
        #expect(line.count - 1 <= Envelope.maxLineLength)
        #expect(fitted.summary.map { $0.count < 100_000 && $0.count > 10_000 } == true)
        #expect(try Envelope(line: line) == .event(fitted))
    }
}

/// An `AgentStore` shared between the server's handlers.
private final class LockedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store = AgentStore()

    func apply(_ event: MoonletEvent) {
        lock.withLock { _ = store.apply(event, now: .now) }
    }

    var agents: [Agent] {
        lock.withLock { store.agents }
    }
}
