import Foundation

/// Spots final messages that are really questions for the user, so an agent
/// that "finished" while waiting on an answer is treated as needing the user.
public enum QuestionDetector {
    /// Polite closers that end with a question but don't need an answer.
    static let closers = [
        "anything else", "any other questions", "any questions", "need anything else",
        "let me know if you need", "let me know if you have", "happy to help",
    ]
    /// Phrases that ask for a decision even without a question mark.
    static let asks = [
        "should i ", "shall i ", "do you want me to", "would you like me to", "want me to ",
        "which would you prefer", "which option", "which approach", "please confirm",
        "can you confirm", "could you confirm", "waiting for your", "let me know which",
        "let me know whether", "how would you like",
    ]

    /// Whether the end of `text` asks the user something that needs an answer.
    public static func asksUser(_ text: String) -> Bool {
        let tail = lastSentences(of: text, count: 2).lowercased()
        guard !tail.isEmpty else { return false }
        if closers.contains(where: tail.contains) { return false }
        if tail.hasSuffix("?") { return true }
        return asks.contains(where: tail.contains)
    }

    static func lastSentences(of text: String, count: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var sentences: [String] = []
        cleaned.enumerateSubstrings(in: cleaned.startIndex..., options: [.bySentences, .reverse]) { sentence, _, _, stop in
            if let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty {
                sentences.insert(sentence, at: 0)
            }
            if sentences.count >= count { stop = true }
        }
        return sentences.joined(separator: " ")
    }
}

/// Flags working agents that have gone quiet for too long, once per silence.
public struct StuckDetector: Sendable {
    public var threshold: TimeInterval = 600
    private var flagged: [String: Date] = [:]

    public init() {}

    /// Agents that just crossed the silence threshold. `lastUpdate` is the time of
    /// each working agent's latest event; agents not listed are forgotten.
    public mutating func newlyStuck(working: [(agentID: String, lastUpdate: Date)], now: Date) -> [String] {
        let ids = Set(working.map(\.agentID))
        flagged = flagged.filter { ids.contains($0.key) }
        var result: [String] = []
        for agent in working where now.timeIntervalSince(agent.lastUpdate) >= threshold {
            // Flag again only after the agent has produced news since the last flag.
            if let flaggedAt = flagged[agent.agentID], flaggedAt >= agent.lastUpdate { continue }
            flagged[agent.agentID] = now
            result.append(agent.agentID)
        }
        return result
    }
}

/// Learns which projects' finished cards the user always waves away, and
/// suggests batching them. Suggestions are offered, never applied silently.
public struct EngagementTracker: Sendable, Codable, Equatable {
    public enum Reaction: String, Sendable, Codable {
        /// Clicked away within a moment of appearing.
        case dismissedQuickly
        /// Opened the agent from Moonlet.
        case opened
    }

    struct Entry: Sendable, Codable, Equatable {
        var reaction: Reaction
        var at: Date
    }

    public var window: TimeInterval = 7 * 24 * 3600
    public var dismissalsBeforeSuggesting = 5
    private var entries: [String: [Entry]] = [:]
    private var declined: Set<String> = []

    public init() {}

    public mutating func record(_ reaction: Reaction, project: String, now: Date) {
        entries[project, default: []].append(Entry(reaction: reaction, at: now))
        entries[project]?.removeAll { now.timeIntervalSince($0.at) > window }
    }

    /// The user said no; never suggest batching this project again.
    public mutating func decline(project: String) {
        declined.insert(project)
    }

    /// Projects worth suggesting for batching: often dismissed quickly, never opened.
    public func suggestions(excluding batched: Set<String>, now: Date) -> [String] {
        entries.compactMap { project, list in
            guard !declined.contains(project), !batched.contains(project) else { return nil }
            let recent = list.filter { now.timeIntervalSince($0.at) <= window }
            let dismissed = recent.filter { $0.reaction == .dismissedQuickly }.count
            let opened = recent.contains { $0.reaction == .opened }
            return dismissed >= dismissalsBeforeSuggesting && !opened ? project : nil
        }.sorted()
    }
}
