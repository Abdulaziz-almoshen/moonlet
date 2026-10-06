import Foundation
import MoonletIPC

/// Starting other programs.
enum Processes {
    /// Starts a program in its own process group without waiting for it. A bare name is
    /// looked up on `PATH`.
    static func spawnDetached(_ argv: [String]) throws {
        guard let program = argv.first else { return }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let cArguments = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid = pid_t()
        let status = posix_spawnp(&pid, program, nil, &attributes, cArguments, environ)
        guard status == 0 else { throw SystemCallError("posix_spawnp \(program)", code: status) }
    }

    /// The first line of a program's standard output, or `nil` if it fails or takes longer
    /// than `timeout`.
    static func firstLine(of executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date.now.addingTimeInterval(timeout)
        while process.isRunning, Date.now < deadline {
            usleep(10_000)
        }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// The installed Claude Code version, such as `"2.1.290 (Claude Code)"`.
    static func claudeVersion(environment: [String: String]) -> String? {
        Locations.claudeExecutable(environment: environment)
            .flatMap { firstLine(of: $0, arguments: ["--version"], timeout: 3) }
    }
}
