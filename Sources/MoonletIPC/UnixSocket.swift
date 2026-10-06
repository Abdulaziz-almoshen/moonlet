import Foundation

/// A system call that failed, with its `errno`.
public struct SystemCallError: Error, Equatable, CustomStringConvertible {
    public let call: String
    public let code: Int32

    public init(_ call: String, code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    public var description: String {
        "\(call) failed: \(String(cString: strerror(code)))"
    }
}

/// A point in time that bounds blocking socket work.
struct Deadline {
    private let uptimeNanoseconds: UInt64

    init(timeout: TimeInterval) {
        let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + nanoseconds
    }

    /// Milliseconds left, rounded up; zero once the deadline has passed.
    var remainingMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else { return 0 }
        return Int32(clamping: (uptimeNanoseconds - now + 999_999) / 1_000_000)
    }
}

/// Thin, non-blocking wrappers over the POSIX Unix domain socket calls.
enum UnixSocket {
    enum ConnectFailure: Error, Equatable {
        /// Nothing is listening at the path.
        case unavailable
        case timedOut
        case failed(Int32)
    }

    /// The socket address for `path`, or `nil` if the path doesn't fit.
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withSockaddr<Result>(
        _ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Marks a descriptor close-on-exec and stops writes to a closed peer from raising SIGPIPE.
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Connects to the socket at `path` without blocking past `deadline`.
    /// The returned descriptor is non-blocking.
    static func connect(to path: String, deadline: Deadline) -> Result<Int32, ConnectFailure> {
        guard let address = address(for: path) else { return .failure(.failed(ENAMETOOLONG)) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.failed(errno)) }
        configure(fd)
        guard setNonBlocking(fd) else {
            let code = errno
            close(fd)
            return .failure(.failed(code))
        }
        if withSockaddr(address, { Darwin.connect(fd, $0, $1) }) == 0 {
            return .success(fd)
        }
        var code = errno
        if code == EINPROGRESS || code == EINTR {
            guard wait(fd, for: POLLOUT, deadline: deadline) else {
                close(fd)
                return .failure(.timedOut)
            }
            var pending: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length)
            if pending == 0 {
                return .success(fd)
            }
            code = pending
        }
        close(fd)
        return .failure(code == ENOENT || code == ECONNREFUSED ? .unavailable : .failed(code))
    }

    /// Whether something answers at `path`.
    static func isAnswering(at path: String) -> Bool {
        switch connect(to: path, deadline: Deadline(timeout: 0.25)) {
        case .success(let fd):
            close(fd)
            return true
        case .failure(.timedOut):
            return true
        case .failure:
            return false
        }
    }

    /// Writes all of `data` to a non-blocking descriptor before `deadline`.
    static func send(_ data: Data, on fd: Int32, deadline: Deadline) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    guard wait(fd, for: POLLOUT, deadline: deadline) else { return false }
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Reads one newline-terminated line (returned without the newline) from a
    /// non-blocking descriptor before `deadline`. Returns `nil` on timeout, error, EOF
    /// before any data, or a line longer than `limit` bytes.
    static func receiveLine(on fd: Int32, deadline: Deadline, limit: Int) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let newline = line.firstIndex(of: 0x0A) {
                return Data(line[..<newline])
            }
            guard line.count <= limit else { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                line.append(contentsOf: chunk[..<count])
            } else if count == 0 {
                return line.isEmpty ? nil : line
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                guard wait(fd, for: POLLIN, deadline: deadline) else { return nil }
            } else {
                return nil
            }
        }
    }

    /// Waits until `fd` is ready for `events` (`POLLIN` or `POLLOUT`) or `deadline` passes.
    static func wait(_ fd: Int32, for events: Int32, deadline: Deadline) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        while true {
            let timeout = deadline.remainingMilliseconds
            guard timeout > 0 else { return false }
            let ready = poll(&descriptor, 1, timeout)
            if ready > 0 {
                return true
            }
            if ready == 0 || errno != EINTR {
                return false
            }
        }
    }
}
