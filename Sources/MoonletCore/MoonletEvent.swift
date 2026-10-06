import Foundation

/// One status report about an agent session, sent by a hook, the CLI, or any integration.
///
/// Optional text fields are patches: an omitted field leaves the stored value alone and
/// an empty string clears it. See `docs/PROTOCOL.md` for the wire format.
public struct MoonletEvent: Codable, Sendable, Equatable {
    /// The protocol version this library speaks.
    public static let protocolVersion = 1

    /// What an event does to its agent.
    public enum Kind: String, Codable, Sendable {
        /// Creates the agent if needed, then applies the event's fields.
        case update
        /// Marks the session as over. Other fields are ignored.
        case end
    }

    /// Protocol version; always `protocolVersion`.
    public var v: Int
    public var kind: Kind
    /// The producer, such as `claude-code`, `codex`, or `cli`.
    public var source: String
    /// The producer's session identifier. Together with `source` it identifies the agent.
    public var session: String
    /// Display label; defaults to the basename of `cwd`.
    public var label: String?
    public var state: AgentState?
    /// What the agent was asked.
    public var title: String?
    /// What the agent is doing right now, in 60 characters or fewer.
    public var activity: String?
    /// The agent's final message, unabridged.
    public var summary: String?
    /// What the agent needs (when waiting) or why it failed (when failed).
    public var message: String?
    /// A notable step, such as "Committed changes".
    public var milestone: String?
    /// The full task list, replacing any stored list.
    public var tasks: [TaskItem]?
    /// A single task to insert, update, or (with status `deleted`) remove.
    public var task: TaskItem?
    /// Explicit progress, which takes precedence over task counts. A zero total clears it.
    public var progress: AgentProgress?
    /// The agent's working directory.
    public var cwd: String?
    public var host: HostInfo?
    /// When the event happened, in seconds since 1970.
    public var ts: Double

    public init(
        kind: Kind = .update,
        source: String,
        session: String,
        label: String? = nil,
        state: AgentState? = nil,
        title: String? = nil,
        activity: String? = nil,
        summary: String? = nil,
        message: String? = nil,
        milestone: String? = nil,
        tasks: [TaskItem]? = nil,
        task: TaskItem? = nil,
        progress: AgentProgress? = nil,
        cwd: String? = nil,
        host: HostInfo? = nil,
        ts: Double = Date.now.timeIntervalSince1970
    ) {
        self.v = Self.protocolVersion
        self.kind = kind
        self.source = source
        self.session = session
        self.label = label
        self.state = state
        self.title = title
        self.activity = activity
        self.summary = summary
        self.message = message
        self.milestone = milestone
        self.tasks = tasks
        self.task = task
        self.progress = progress
        self.cwd = cwd
        self.host = host
        self.ts = ts
    }

    /// The identifier of the agent this event addresses.
    public var agentID: String { Agent.id(source: source, session: session) }

    /// The event as one line of JSON, terminated by a newline. This is the spool format.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder.wire().encode(self)
        data.append(0x0A)
        return data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        guard v == Self.protocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .v, in: container,
                debugDescription: "Unsupported protocol version \(v); expected \(Self.protocolVersion).")
        }
        kind = try container.decode(Kind.self, forKey: .kind)
        source = try container.decode(String.self, forKey: .source)
        session = try container.decode(String.self, forKey: .session)
        guard !source.isEmpty, !session.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: source.isEmpty ? .source : .session, in: container,
                debugDescription: "source and session must not be empty.")
        }
        label = try container.decodeIfPresent(String.self, forKey: .label)
        state = try container.decodeIfPresent(AgentState.self, forKey: .state)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        milestone = try container.decodeIfPresent(String.self, forKey: .milestone)
        tasks = try container.decodeIfPresent([TaskItem].self, forKey: .tasks)
        task = try container.decodeIfPresent(TaskItem.self, forKey: .task)
        progress = try container.decodeIfPresent(AgentProgress.self, forKey: .progress)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        host = try container.decodeIfPresent(HostInfo.self, forKey: .host)
        ts = try container.decode(Double.self, forKey: .ts)
    }
}

extension JSONEncoder {
    /// An encoder for the wire format: compact, single-line, with sorted keys and
    /// unescaped slashes.
    static func wire() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
