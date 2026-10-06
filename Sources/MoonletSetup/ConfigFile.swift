import Foundation

/// Reads and rewrites the config files Moonlet edits, keeping a backup of each version.
enum ConfigFile {
    /// The file's text, or an empty string if it doesn't exist.
    static func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        }
    }

    /// Plans an edit to the file at `url` and, unless `dryRun` is set, applies it.
    static func apply(
        to url: URL, dryRun: Bool, now: Date, plan makePlan: (String) throws -> InstallPlan
    ) throws -> InstallResult {
        let plan = try makePlan(read(url))
        guard plan.hasChanges, !dryRun else {
            return InstallResult(plan: plan, wroteFile: false, backupURL: nil)
        }
        let backupURL = try replace(url, with: plan.newText, now: now)
        return InstallResult(plan: plan, wroteFile: true, backupURL: backupURL)
    }

    /// Atomically replaces the file's contents, after copying the current version to a
    /// timestamped backup beside it. Symlinks are followed, so a linked dotfile stays
    /// linked, and the file keeps its permissions. Returns the backup's location, or `nil`
    /// if the file didn't exist.
    static func replace(_ url: URL, with text: String, now: Date) throws -> URL? {
        let manager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var backupURL: URL?
        var permissions: Int?
        if manager.fileExists(atPath: target.path) {
            permissions = (try manager.attributesOfItem(atPath: target.path))[.posixPermissions] as? Int
            let backup = availableBackupURL(for: target, now: now)
            try manager.copyItem(at: target, to: backup)
            backupURL = backup
        } else {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(text.utf8).write(to: target, options: .atomic)
        if let permissions {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return backupURL
    }

    /// `<name>.moonlet-backup-<yyyyMMdd-HHmmss>`, with a counter if that's taken.
    private static func availableBackupURL(for url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).moonlet-backup-\(formatter.string(from: now))"
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appending(path: base, directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(base)-\(counter)", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }
}

/// Quotes words for `/bin/sh`.
enum ShellQuote {
    /// The word as is when it's made of safe characters, otherwise single-quoted.
    static func quote(_ word: String) -> String {
        let isSafe = !word.isEmpty && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+,:@%=".contains($0)) }
        return isSafe ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
