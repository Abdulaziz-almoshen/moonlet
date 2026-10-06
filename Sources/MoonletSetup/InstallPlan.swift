import Foundation

/// Whether to add or remove Moonlet's integration.
public enum InstallAction: Sendable {
    case install
    case uninstall
}

/// A planned edit to a config file.
public struct InstallPlan: Sendable, Equatable {
    /// The file's contents before the edit.
    public let originalText: String
    /// The file's contents after the edit; equal to `originalText` when nothing changes.
    public let newText: String
    /// One line per change, for people. Empty when the file is already as wanted.
    public let changes: [String]

    public init(originalText: String, newText: String, changes: [String]) {
        self.originalText = originalText
        self.newText = newText
        self.changes = changes
    }

    /// A plan that leaves `text` alone.
    static func unchanged(_ text: String) -> InstallPlan {
        InstallPlan(originalText: text, newText: text, changes: [])
    }

    public var hasChanges: Bool { !changes.isEmpty }
}

/// What applying a plan did.
public struct InstallResult: Sendable, Equatable {
    public let plan: InstallPlan
    /// Whether the file was written. False for dry runs and for plans without changes.
    public let wroteFile: Bool
    /// Where the previous version of the file was saved. `nil` when nothing was written
    /// or the file didn't exist yet.
    public let backupURL: URL?
}

/// A config file Moonlet refuses to edit, with the reason.
public struct InstallError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
