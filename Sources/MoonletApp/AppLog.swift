import Foundation
import MoonletIPC

/// Rare, important events, appended to `app.log` in Moonlet's logs directory so
/// they can be attached to a bug report.
enum AppLog {
    static func write(paths: MoonletPaths, _ message: String) {
        let url = paths.logsDirectory.appending(path: "app.log", directoryHint: .notDirectory)
        try? FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
