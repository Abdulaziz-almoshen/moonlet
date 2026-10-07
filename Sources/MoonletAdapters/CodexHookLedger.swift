import Foundation

/// Remembers which Codex sessions report through hooks, so that `moonlet hook codex`
/// running as Codex's notify program doesn't report their turns a second time.
///
/// Codex runs its `Stop` hooks, and waits for them, before it starts the notify program for
/// the same turn, and both carry the same session and turn ids. So the `Stop` hook writes
/// the finished turn here, and the notify call skips a turn it finds already finished. A
/// session without an entry (hooks not trusted yet, or a Codex without hooks) keeps
/// reporting through notify.
///
/// One small file per thread, named after its id, in a directory only the user can read.
/// Writes are atomic, and a missing or unreadable directory only means notify reports.
public struct CodexHookLedger: Sendable {
    /// What a hook payload tells the ledger.
    public struct Note: Sendable, Equatable {
        /// The root session, which the hooks report.
        public var session: String
        /// The subagent thread the payload came from, if any. Hooks report a subagent's
        /// work as its root session's, so notify should skip the subagent's own turns.
        public var subagentThread: String?
        /// The turn a root `Stop` hook just finished.
        public var finishedTurn: String?

        public init(session: String, subagentThread: String? = nil, finishedTurn: String? = nil) {
            self.session = session
            self.subagentThread = subagentThread
            self.finishedTurn = finishedTurn
        }
    }

    /// What the ledger knows about a thread.
    public enum Record: Sendable, Equatable {
        /// A root session that reports through hooks; `finishedTurn` is the last turn its
        /// `Stop` hook reported.
        case session(finishedTurn: String?)
        /// A subagent's thread, reported as part of its root session.
        case subagent
    }

    /// Entries untouched for this long are pruned: a week.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Writing

    /// Records what a hook payload showed. Errors are ignored: the worst outcome is a turn
    /// that notify reports too.
    public func write(_ note: Note) {
        guard prepareDirectory() else { return }
        if let turn = note.finishedTurn {
            try? Data("session\n\(turn)\n".utf8).write(to: url(forThread: note.session), options: .atomic)
        } else {
            touch(url(forThread: note.session), creatingWith: "session\n")
        }
        if let subagent = note.subagentThread, subagent != note.session {
            touch(url(forThread: subagent), creatingWith: "subagent\n")
        }
    }

    /// Removes entries untouched for longer than `age`.
    public func prune(now: Date, olderThan age: TimeInterval = retention) {
        for (url, modified) in entries() where now.timeIntervalSince(modified) > age {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Reading

    /// What the ledger knows about a thread, or `nil` if the hooks never reported it.
    public func record(forThread thread: String) -> Record? {
        guard let data = FileManager.default.contents(atPath: url(forThread: thread).path) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first == "subagent" {
            return .subagent
        }
        // An entry cut short by a crash still shows the session reports through hooks.
        let turn = lines.count > 1 && lines.first == "session" && !lines[1].isEmpty ? String(lines[1]) : nil
        return .session(finishedTurn: turn)
    }

    /// Whether notify should skip a turn: the hooks already finished it, or it belongs to
    /// a subagent the hooks report as part of its root session.
    public static func hooksReported(_ record: Record?, turn: String?) -> Bool {
        switch record {
        case .subagent?: true
        case .session(let finished?)?: finished == turn
        case .session(nil)?, nil: false
        }
    }

    /// When a hook last wrote to the ledger, or `nil` if none ever did.
    public var lastActivity: Date? {
        entries().map(\.modified).max()
    }

    // MARK: Files

    /// A file name for a thread id: its letters, digits, `-`, `_`, and `.`, with anything
    /// else replaced by `_`, never hidden and never empty.
    static func fileName(forThread thread: String) -> String {
        let safe = String(thread.unicodeScalars.prefix(200).map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
                ? Character(scalar) : "_"
        })
        return safe.isEmpty || safe.hasPrefix(".") ? "id-" + safe : safe
    }

    private func url(forThread thread: String) -> URL {
        directory.appending(path: Self.fileName(forThread: thread), directoryHint: .notDirectory)
    }

    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }

    /// Creates the file with `contents` if it's missing; otherwise marks it as just used.
    private func touch(_ url: URL, creatingWith contents: String) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            _ = contents.utf8CString.withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count - 1)
            }
            close(fd)
        } else if errno == EEXIST {
            utimes(url.path, nil)
        }
    }

    private func entries() -> [(url: URL, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true, let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }
    }
}
