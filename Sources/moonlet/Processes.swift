import Foundation
import MoonletIPC
import MoonletSetup

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
        output(of: executable, arguments: arguments, timeout: timeout)?
            .split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// A program's standard output, or `nil` if it fails or takes longer than `timeout`.
    /// `environment` replaces this process's environment when given.
    static func output(
        of executable: String, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
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
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The installed Claude Code version, such as `"2.1.290 (Claude Code)"`.
    static func claudeVersion(environment: [String: String]) -> String? {
        Locations.claudeExecutable(environment: environment)
            .flatMap { firstLine(of: $0, arguments: ["--version"], timeout: 3) }
    }

    /// The installed Codex version, such as `"codex-cli 0.154.0"`.
    static func codexVersion(environment: [String: String]) -> String? {
        guard let codex = Locations.codexExecutable(environment: environment) else { return nil }
        // npm installs codex as a Node script (`#!/usr/bin/env node`), so make sure `node`
        // is found: it sits beside the link, or in Homebrew's directory.
        var environment = environment
        let directory = URL(filePath: codex).deletingLastPathComponent().path
        let path = [directory, environment["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = path.filter { !$0.isEmpty }.joined(separator: ":")
        let text = output(of: codex, arguments: ["--version"], environment: environment, timeout: 5)
        return text?.split(whereSeparator: \.isNewline).map(String.init)
            .first { CodexInstaller.mechanism(forCodexVersion: $0) != nil }
    }
}
