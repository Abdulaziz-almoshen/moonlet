import Foundation
import MoonletCore
import Testing

@testable import MoonletIPC

@Suite("Spool")
struct SpoolTests {
    private func event(_ index: Int) -> MoonletEvent {
        MoonletEvent(source: "cli", session: "s\(index)", state: .working, activity: "Step \(index)", ts: Double(index))
    }

    @Test func drainReturnsEventsInOrderAndEmptiesTheSpool() throws {
        let home = try TemporaryHome()
        let spool = Spool(url: home.paths.spoolURL)
        for index in 0..<3 {
            try spool.append(event(index))
        }
        #expect(try spool.drain() == (0..<3).map(event))
        #expect(try spool.drain().isEmpty)
    }

    @Test func drainOfAMissingSpoolIsEmpty() throws {
        let home = try TemporaryHome()
        #expect(try Spool(url: home.url.appending(path: "nested/spool.jsonl")).drain().isEmpty)
    }

    @Test func appendCreatesAPrivateFile() throws {
        let home = try TemporaryHome()
        let url = home.url.appending(path: "fresh/spool.jsonl")
        try Spool(url: url).append(event(1))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func drainSkipsLinesThatDoNotDecode() throws {
        let home = try TemporaryHome()
        let spool = Spool(url: home.paths.spoolURL)
        try spool.append(event(1))
        let handle = try FileHandle(forWritingTo: spool.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":9}\ngarbage\n".utf8))
        try handle.close()
        try spool.append(event(2))
        #expect(try spool.drain() == [event(1), event(2)])
    }

    @Test func staysBoundedByKeepingTheNewestHalf() throws {
        let home = try TemporaryHome()
        let spool = Spool(url: home.paths.spoolURL, limit: 4096)
        for index in 0..<200 {
            try spool.append(event(index))
        }
        let size = try #require(FileManager.default.attributesOfItem(atPath: spool.url.path)[.size] as? Int)
        #expect(size <= 4096)
        let drained = try spool.drain()
        #expect(drained.last == event(199))
        #expect(drained.count > 10)
        #expect(drained.map(\.ts) == drained.map(\.ts).sorted())
        #expect(drained.first.map { $0.ts > 100 } == true)
    }

    @Test func defaultLimitIs256KiB() {
        #expect(Spool.defaultLimit == 256 * 1024)
    }

    @Test func concurrentAppendsAreAllKept() throws {
        let home = try TemporaryHome()
        let spool = Spool(url: home.paths.spoolURL)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<25 {
                try? spool.append(event(worker * 100 + index))
            }
        }
        #expect(Set(try spool.drain().map(\.session)).count == 200)
    }
}

@Suite("MoonletPaths")
struct MoonletPathsTests {
    @Test func defaultsToApplicationSupportAndLogs() {
        let paths = MoonletPaths(environment: [:])
        #expect(paths.supportDirectory.path.hasSuffix("/Library/Application Support/Moonlet"))
        #expect(paths.logsDirectory.path.hasSuffix("/Library/Logs/Moonlet"))
        #expect(paths.socketURL.lastPathComponent == "moonlet.sock")
        #expect(paths.spoolURL.lastPathComponent == "spool.jsonl")
        #expect(paths.socketURL.deletingLastPathComponent().path == paths.supportDirectory.path)
    }

    @Test func moonletHomeOverridesEverything() {
        let paths = MoonletPaths(environment: ["MOONLET_HOME": "/tmp/mh"])
        #expect(paths.socketURL.path == "/tmp/mh/moonlet.sock")
        #expect(paths.spoolURL.path == "/tmp/mh/spool.jsonl")
        #expect(paths.logsDirectory.path == "/tmp/mh/Logs")
    }

    @Test func socketPathLengthLimit() throws {
        let fits = MoonletPaths(supportDirectory: URL(filePath: "/" + String(repeating: "a", count: 89), directoryHint: .isDirectory))
        #expect(fits.socketURL.path.utf8.count == 103)
        try fits.validateSocketPath()

        let tooLong = MoonletPaths(supportDirectory: URL(filePath: "/" + String(repeating: "a", count: 90), directoryHint: .isDirectory))
        #expect(throws: MoonletPaths.Error.socketPathTooLong(path: tooLong.socketURL.path, length: 104)) {
            try tooLong.validateSocketPath()
        }
    }

    @Test func createSupportDirectoryRestrictsPermissions() throws {
        let home = try TemporaryHome()
        let paths = MoonletPaths(supportDirectory: home.url.appending(path: "a/b", directoryHint: .isDirectory))
        try paths.createSupportDirectory()
        try paths.createSupportDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.supportDirectory.path)
        #expect(attributes[.posixPermissions] as? Int == 0o700)
    }
}
