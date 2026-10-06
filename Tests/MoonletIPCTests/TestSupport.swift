import Foundation
import MoonletCore

@testable import MoonletIPC

/// A throwaway support directory, short enough for a socket path. Removed on deinit.
final class TemporaryHome: Sendable {
    let url: URL
    let paths: MoonletPaths

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "mlt-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        paths = MoonletPaths(supportDirectory: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Collects values from handlers that run on other threads.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }

    /// Waits until at least `count` values have arrived, or `timeout` passes.
    func wait(for count: Int, timeout: TimeInterval = 3) async -> [Value] {
        let deadline = Date.now.addingTimeInterval(timeout)
        while values.count < count, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return values
    }
}

/// Runs blocking work (the client's socket calls) off the cooperative thread pool.
func offload<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

/// A raw client connection, for exercising the server below the `MoonletClient` level.
struct RawConnection {
    let fd: Int32

    init(paths: MoonletPaths) throws {
        guard case .success(let fd) = UnixSocket.connect(to: paths.socketURL.path, deadline: Deadline(timeout: 1)) else {
            throw SystemCallError("connect", code: ECONNREFUSED)
        }
        self.fd = fd
    }

    func write(_ text: String) -> Bool {
        UnixSocket.send(Data(text.utf8), on: fd, deadline: Deadline(timeout: 1))
    }

    func write(_ data: Data) -> Bool {
        UnixSocket.send(data, on: fd, deadline: Deadline(timeout: 1))
    }

    func readLine() -> String? {
        UnixSocket.receiveLine(on: fd, deadline: Deadline(timeout: 2), limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) }
    }

    func finishWriting() {
        shutdown(fd, SHUT_WR)
    }

    func close() {
        Darwin.close(fd)
    }
}

func eventLine(session: String, state: AgentState = .working) -> String {
    let event = MoonletEvent(source: "cli", session: session, state: state, ts: 1)
    return String(decoding: (try? Envelope.event(event).encodedLine()) ?? Data(), as: UTF8.self)
}
