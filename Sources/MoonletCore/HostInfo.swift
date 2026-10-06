/// Where an agent runs, so the app can bring the right window forward.
public struct HostInfo: Codable, Sendable, Equatable {
    /// Bundle identifier of the app hosting the agent, from `__CFBundleIdentifier`
    /// (for example `com.googlecode.iterm2`).
    public var bundleID: String?
    /// The terminal program, from `TERM_PROGRAM` (for example `Apple_Terminal`).
    public var termProgram: String?
    /// The agent's controlling terminal (for example `/dev/ttys003`).
    public var tty: String?
    /// The agent's process identifier.
    public var pid: Int32?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case termProgram = "term_program"
        case tty
        case pid
    }

    public init(bundleID: String? = nil, termProgram: String? = nil, tty: String? = nil, pid: Int32? = nil) {
        self.bundleID = bundleID
        self.termProgram = termProgram
        self.tty = tty
        self.pid = pid
    }

    /// Reads `__CFBundleIdentifier` and `TERM_PROGRAM` from an environment.
    public init(environment: [String: String]) {
        self.init(
            bundleID: environment["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 },
            termProgram: environment["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Whether every field is `nil`.
    public var isEmpty: Bool {
        bundleID == nil && termProgram == nil && tty == nil && pid == nil
    }
}
