import Foundation
import MoonletCore

/// Events written while the app wasn't running, one JSON object per line.
///
/// Many processes may append at once and the app drains it at launch, so every operation
/// holds an exclusive `flock` on a sibling `.lock` file.
public struct Spool: Sendable {
    /// The default size cap: 256 KiB.
    public static let defaultLimit = 256 * 1024

    public let url: URL
    /// When the file grows past this many bytes, only its newest half is kept.
    public let limit: Int

    public init(url: URL, limit: Int = Spool.defaultLimit) {
        self.url = url
        self.limit = limit
    }

    /// Appends an event, then trims the file to its newest half if it's over `limit`.
    public func append(_ event: MoonletEvent) throws {
        let line = try event.encodedLine()
        try withExclusiveLock {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SystemCallError("open") }
            defer { close(fd) }
            try line.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, base + offset, buffer.count - offset)
                    if written < 0 {
                        guard errno == EINTR else { throw SystemCallError("write") }
                        continue
                    }
                    offset += written
                }
            }
            var info = stat()
            if fstat(fd, &info) == 0, Int(info.st_size) > limit {
                try keepNewestHalf()
            }
        }
    }

    /// Returns every spooled event, oldest first, and empties the spool.
    /// Lines that don't decode are skipped.
    public func drain() throws -> [MoonletEvent] {
        let data: Data = try withExclusiveLock {
            guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else {
                return Data()
            }
            guard truncate(url.path, 0) == 0 else { throw SystemCallError("truncate") }
            return data
        }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(MoonletEvent.self, from: $0) }
    }

    /// Rewrites the file with the complete lines in its last `limit / 2` bytes.
    private func keepNewestHalf() throws {
        let data = try Data(contentsOf: url)
        var tail = data.suffix(limit / 2)
        if tail.startIndex > data.startIndex, data[tail.startIndex - 1] != 0x0A,
            let newline = tail.firstIndex(of: 0x0A)
        {
            tail = tail[(newline + 1)...]
        }
        try Data(tail).write(to: url, options: .atomic)
        _ = chmod(url.path, 0o600)
    }

    private func withExclusiveLock<Result>(_ body: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SystemCallError("open") }
        defer { close(fd) }  // Closing the descriptor releases the lock.
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SystemCallError("flock") }
        }
        return try body()
    }
}
