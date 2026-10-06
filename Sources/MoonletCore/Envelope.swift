import Foundation

/// One line of the Moonlet wire protocol.
public enum Envelope: Sendable, Equatable {
    /// A fire-and-forget event: `{"type":"event","event":{…}}`.
    case event(MoonletEvent)
    /// A request for every agent: `{"type":"status"}`.
    case statusRequest
    /// The app's answer to `statusRequest`: `{"type":"status","agents":[…]}`.
    case statusReply([Agent])
    /// A request to show the summon view: `{"type":"summon"}`.
    case summon

    /// The longest line, in bytes and excluding the newline, that the app accepts.
    public static let maxLineLength = 64 * 1024

    /// The envelope as one line of JSON, terminated by a newline.
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder.wire().encode(self)
        data.append(0x0A)
        return data
    }

    /// Decodes one line, with or without its trailing newline.
    public init(line: Data) throws {
        self = try JSONDecoder().decode(Envelope.self, from: line)
    }
}

extension Envelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, event, agents
    }

    private enum Kind: String, Codable {
        case event, status, summon
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .event:
            self = .event(try container.decode(MoonletEvent.self, forKey: .event))
        case .status:
            if let agents = try container.decodeIfPresent([Agent].self, forKey: .agents) {
                self = .statusReply(agents)
            } else {
                self = .statusRequest
            }
        case .summon:
            self = .summon
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode(Kind.event, forKey: .type)
            try container.encode(event, forKey: .event)
        case .statusRequest:
            try container.encode(Kind.status, forKey: .type)
        case .statusReply(let agents):
            try container.encode(Kind.status, forKey: .type)
            try container.encode(agents, forKey: .agents)
        case .summon:
            try container.encode(Kind.summon, forKey: .type)
        }
    }
}
