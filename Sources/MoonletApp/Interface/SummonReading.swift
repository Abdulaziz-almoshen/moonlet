import Foundation
import MoonletBrain

/// How the summon view reads the fleet: who comes first, what to say about it,
/// and which face each agent makes.
extension SummonContent {
    /// The agents in the order the summon view lists them: the longest wait
    /// first, then failures (newest first), work closest to done, and finished
    /// work newest first. Ties keep a fixed order, so number keys don't shuffle.
    var ranked: [AgentRow] {
        agents.sorted { a, b in
            if a.activity != b.activity { return a.activity.rank < b.activity.rank }
            if a.activity == .working, a.etaMinutes != b.etaMinutes {
                return (a.etaMinutes ?? .max) < (b.etaMinutes ?? .max)
            }
            if a.since != b.since { return a.activity == .waiting ? a.since < b.since : a.since > b.since }
            return a.id < b.id
        }
    }

    /// The agent the Next up card offers: the top one, when it waits on the user or failed.
    var nextUp: AgentRow? {
        ranked.first.flatMap { $0.activity == .waiting || $0.activity == .failed ? $0 : nil }
    }

    /// One line on what needs the user, such as `api-refactor is waiting on you · 6 min`.
    func headline(now: Date) -> String {
        let waiting = agents.filter { $0.activity == .waiting }
        let failed = ranked.filter { $0.activity == .failed }
        if waiting.count > 1 { return "\(waiting.count) agents are waiting on you" }
        if let agent = waiting.first {
            return "\(agent.label) is waiting on you · " + (SummonTime.span(since: agent.since, now: now) ?? "just now")
        }
        if let agent = failed.first { return "\(agent.label) needs a look" }
        if agents.isEmpty { return "No agents right now" }
        if agents.contains(where: { $0.activity == .working }) { return "Nothing needs you right now" }
        return "All quiet. Everything is done."
    }

    /// The rest of the picture, such as `2 working, all done in ~9 min · 1 finished since you looked`.
    var subline: String {
        let working = agents.filter { $0.activity == .working }
        let finished = agents.filter { $0.activity == .done && $0.isNew }
        let failed = agents.filter { $0.activity == .failed }
        let waits = agents.contains { $0.activity == .waiting }
        var parts: [String] = []
        if !working.isEmpty {
            let etas = working.compactMap(\.etaMinutes)
            parts.append(etas.count == working.count
                ? "\(working.count) working, all done in ~\(etas.max() ?? 1) min"
                : "\(working.count) working")
        }
        if !finished.isEmpty { parts.append("\(finished.count) finished since you looked") }
        // When the headline already names the one failure, don't count it again.
        if failed.count > 1 || (failed.count == 1 && waits) { parts.append("\(failed.count) failed") }
        return parts.joined(separator: " · ")
    }

    /// The face of the companion at the center of the well: it asks while
    /// anyone waits, worries over a failure, and is proud once all is done.
    var hostExpression: Expression {
        if agents.contains(where: { $0.activity == .waiting }) { return .asking }
        if agents.contains(where: { $0.activity == .failed }) { return .worried }
        if agents.contains(where: { $0.activity == .working }) || agents.isEmpty { return .content }
        return .proud
    }
}

extension AgentRow {
    /// Whether the agent asked the user a question rather than for permission.
    /// A request never counts, even with a `?` in its command or URL.
    var asks: Bool {
        guard !SummonQuestion.isRequest(status) else { return false }
        return !options.isEmpty || status.contains("?") || mood == .curious
    }

    /// The status without the question's options: `Which database should the tests use?`.
    var detail: String {
        SummonQuestion.split(status)?.question ?? status
    }

    /// The detail cut to a glance, for the well's speech bubble.
    var words: String {
        detail.count > 60 ? String(detail.prefix(59)) + "…" : detail
    }

    /// How long it has waited, how long it has left, or how long ago it finished:
    /// `waiting 6 min`, `~9 min left`, `3 min ago`, `just now`.
    func when(now: Date) -> String {
        let span = SummonTime.span(since: since, now: now)
        switch activity {
        case .waiting:
            return span.map { "waiting \($0)" } ?? "just now"
        case .working:
            if let eta = etaMinutes { return "~\(eta) min left" }
            return span.map { "working \($0)" } ?? "just now"
        case .done, .failed, .idle:
            return span.map { "\($0) ago" } ?? "just now"
        }
    }

    /// What the agent shows in the well: focused while it works, dozing once it
    /// has been done a while, and otherwise the face of its latest message,
    /// with that mood's props.
    func face(now: Date) -> (expression: Expression, props: [CompanionProp.Kind]) {
        switch activity {
        case .working: return (.focused, [.orbit])
        case .done where now.timeIntervalSince(since) > 12 * 60: return (.sleepy, [.zzz])
        default: break
        }
        let fallback: CompanionMood? = switch activity {
        case .waiting: .asking
        case .failed: .teary
        case .done: .happy
        case .working, .idle: nil
        }
        guard let mood = mood ?? fallback else { return (.content, []) }
        if activity == .waiting, !mood.waitsForAnswer { return (.asking, [.sign("?")]) }
        return (mood.expression, Self.props(of: mood))
    }

    /// What each mood keeps with it in the well. The rain cloud is left out:
    /// at this size it crowds the neighbors.
    private static func props(of mood: CompanionMood) -> [CompanionProp.Kind] {
        switch mood {
        case .asking, .curious: [.sign("?")]
        case .nervous: [.sign("!"), .drop]
        case .teary: [.tear]
        case .celebrate: [.hat]
        case .worried: [.drop]
        case .sleepy: [.zzz]
        case .proud, .happy, .cheeky, .surprised, .grateful: []
        }
    }

    /// How lit its moon is: its task-list progress, full once done.
    var phase: CGFloat {
        activity == .done ? 1 : CGFloat(max(0.12, min(1, progress ?? 1)))
    }
}

extension AgentActivity {
    /// The order of the summon view's list: what needs the user comes first.
    fileprivate var rank: Int {
        switch self {
        case .waiting: 0
        case .failed: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        }
    }
}

/// A question that offers choices, as an agent's message carries them:
/// `Which database should the tests use? SQLite · Postgres`.
enum SummonQuestion {
    /// The question and its options, split at the last `?` before the first
    /// ` · `. Nil unless the message lists options that way, and always nil
    /// for a request, so a `?` in a command, a URL, or a glob never makes one.
    static func split(_ message: String) -> (question: String, options: [String])? {
        guard !isRequest(message), let list = message.range(of: " · "),
              let mark = message[..<list.lowerBound].lastIndex(of: "?") else { return nil }
        let options = message[message.index(after: mark)...]
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (String(message[...mark]), options)
    }

    /// Whether the message asks for permission, such as `Wants to run npm install`,
    /// which is never a question.
    static func isRequest(_ message: String) -> Bool {
        message.hasPrefix("Wants to")
    }
}

/// Short spans of time, as the summon view says them.
enum SummonTime {
    /// `6 min` or `2 h`, rounded; nil under a minute.
    static func span(since date: Date, now: Date) -> String? {
        let minutes = now.timeIntervalSince(date) / 60
        if minutes < 1 { return nil }
        if minutes < 59.5 { return "\(Int(minutes.rounded())) min" }
        return "\(Int((minutes / 60).rounded())) h"
    }

    /// `3 min ago` or `just now`.
    static func ago(_ date: Date, now: Date) -> String {
        span(since: date, now: now).map { "\($0) ago" } ?? "just now"
    }
}
