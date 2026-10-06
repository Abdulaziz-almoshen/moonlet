import Foundation

/// Where the agents keep their configuration, and where the executables live.
enum Locations {
    /// `$CLAUDE_CONFIG_DIR/settings.json`, or `~/.claude/settings.json`.
    static func claudeSettings(environment: [String: String]) -> URL {
        directory(environment["CLAUDE_CONFIG_DIR"], default: ".claude")
            .appending(path: "settings.json", directoryHint: .notDirectory)
    }

    /// `$CODEX_HOME/config.toml`, or `~/.codex/config.toml`.
    static func codexConfig(environment: [String: String]) -> URL {
        directory(environment["CODEX_HOME"], default: ".codex")
            .appending(path: "config.toml", directoryHint: .notDirectory)
    }

    /// A path from the command line, with `~` expanded and made absolute.
    static func url(forUserPath path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .notDirectory).standardizedFileURL
    }

    /// The path this moonlet was started from. A symlink found on `PATH` is kept as is,
    /// so hooks survive upgrades that move the real binary.
    static func moonletExecutable(environment: [String: String]) -> String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") {
            return url(forUserPath: invoked).path
        }
        return executable(named: invoked, environment: environment) ?? Bundle.main.executablePath ?? invoked
    }

    /// The `claude` executable on `PATH` or in its usual install locations.
    static func claudeExecutable(environment: [String: String]) -> String? {
        if let found = executable(named: "claude", environment: environment) {
            return found
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func executable(named name: String, environment: [String: String]) -> String? {
        (environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func directory(_ override: String?, default name: String) -> URL {
        if let override, !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: name, directoryHint: .isDirectory)
    }
}
