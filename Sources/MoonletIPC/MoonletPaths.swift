import Foundation

/// Where Moonlet keeps its socket, spool, and logs.
public struct MoonletPaths: Sendable, Equatable {
    /// Environment variable that relocates the support directory, with logs inside it.
    public static let homeEnvironmentKey = "MOONLET_HOME"
    /// The longest socket path the system accepts, in bytes. `sun_path` holds 104 bytes,
    /// including the terminating NUL.
    public static let maxSocketPathLength = 103

    /// A path Moonlet can't use.
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case socketPathTooLong(path: String, length: Int)

        public var description: String {
            switch self {
            case .socketPathTooLong(let path, let length):
                "The socket path \(path) is \(length) bytes, but macOS allows at most "
                    + "\(MoonletPaths.maxSocketPathLength). Point \(MoonletPaths.homeEnvironmentKey) "
                    + "at a shorter directory."
            }
        }
    }

    /// Holds the socket and the spool. Created with mode 0700.
    public let supportDirectory: URL
    /// Holds diagnostic logs.
    public let logsDirectory: URL

    public init(supportDirectory: URL, logsDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory
        self.logsDirectory = logsDirectory ?? supportDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Moonlet` and `~/Library/Logs/Moonlet`, or
    /// `$MOONLET_HOME` and `$MOONLET_HOME/Logs` when that variable is set.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let home = environment[Self.homeEnvironmentKey], !home.isEmpty {
            self.init(supportDirectory: URL(filePath: home, directoryHint: .isDirectory))
        } else {
            let library = Self.userHomeDirectory().appending(path: "Library", directoryHint: .isDirectory)
            self.init(
                supportDirectory: library.appending(path: "Application Support/Moonlet", directoryHint: .isDirectory),
                logsDirectory: library.appending(path: "Logs/Moonlet", directoryHint: .isDirectory))
        }
    }

    /// The app's Unix domain socket.
    public var socketURL: URL {
        supportDirectory.appending(path: "moonlet.sock", directoryHint: .notDirectory)
    }

    /// Events written while the app wasn't running.
    public var spoolURL: URL {
        supportDirectory.appending(path: "spool.jsonl", directoryHint: .notDirectory)
    }

    /// Creates the support directory if needed and restricts it to the current user.
    public func createSupportDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }

    /// Throws `Error.socketPathTooLong` if `socketURL` is too long to bind or connect to.
    public func validateSocketPath() throws {
        let path = socketURL.path
        let length = path.utf8.count
        guard length <= Self.maxSocketPathLength else {
            throw Error.socketPathTooLong(path: path, length: length)
        }
    }

    /// The user's real home directory, even when running inside an App Sandbox container.
    private static func userHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }
}
