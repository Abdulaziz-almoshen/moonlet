import Foundation

/// A face the companion can make.
public enum Expression: String, Sendable, CaseIterable, Codable {
    case content, delighted, proud, starry, cheeky, blep
    case asking, curious, nervous, surprised, worried, teary
    case oops, sleepy, focused, shy, smitten, pleading
}

/// How the companion feels about what an agent just said. It comes from the
/// message itself, so a deploy, a typo fix, and a failed build each get their
/// own performance.
public enum CompanionMood: String, Sendable, CaseIterable, Codable {
    /// Shipped, deployed, released, merged.
    case celebrate
    /// Tests pass, everything is green, something got faster.
    case proud
    /// Any other good news.
    case happy
    /// A tiny fix: a typo, lint, a rename.
    case cheeky
    /// Unexpected news: found more of something.
    case surprised
    /// A permission request.
    case asking
    /// A question for the user, often with options.
    case curious
    /// A permission request for something destructive.
    case nervous
    /// A failure.
    case teary
    /// No news for a long time.
    case worried
    /// Rate limits, quotas, overload: the agent has to wait.
    case sleepy
    /// The agent thanks the user.
    case grateful

    /// The face the companion makes for this mood.
    public var expression: Expression {
        switch self {
        case .celebrate: .starry
        case .proud: .proud
        case .happy: .delighted
        case .cheeky: .cheeky
        case .surprised: .surprised
        case .asking: .asking
        case .curious: .curious
        case .nervous: .nervous
        case .teary: .teary
        case .worried: .worried
        case .sleepy: .sleepy
        case .grateful: .smitten
        }
    }

    /// Whether the agent waits for the user's answer.
    public var waitsForAnswer: Bool { self == .asking || self == .curious || self == .nervous }

    /// The pointer's color while the companion says this.
    public var tint: PointerTint {
        switch self {
        case .asking, .curious, .nervous: .needsYou
        case .teary, .worried, .sleepy: .problem
        case .celebrate, .proud, .happy, .cheeky, .surprised, .grateful: .info
        }
    }

    /// Reads the mood from what kind of moment it is and what the agent said.
    /// The kind decides the family (asking, bad news, good news); the words pick
    /// the mood within it, so a failure is never read as a celebration.
    public static func read(kind: MomentKind, title: String = "", detail: String) -> CompanionMood {
        let text = detail + " " + title
        switch kind {
        case .needsYou, .question:
            if matches(text, risky) { return .nervous }
            if kind == .question || text.contains("?") || matches(text, asksToChoose) { return .curious }
            return .asking
        case .failed:
            return matches(text, waitsForLimit) ? .sleepy : .teary
        case .stuck:
            return .worried
        case .finished:
            if matches(text, thanks) { return .grateful }
            if matches(text, shipped) { return .celebrate }
            if matches(text, tiny) { return .cheeky }
            if matches(text, surprising) { return .surprised }
            if matches(text, green) { return .proud }
            return .happy
        }
    }

    private static let risky = #"rm -rf|\bdelete\b|\bdrop (table|database)\b|--force|force[- ]push|push -f|\bsudo\b|reset --hard|\bwipe\b|\bprod(uction)?\b"#
    private static let asksToChoose = #"^(which|should|do you|would you|can i|may i)\b|\bprefer\b|\bchoose\b"#
    private static let waitsForLimit = #"rate.?limit|usage limit|quota|overloaded|try again later|\bback at\b"#
    private static let thanks = #"\bthank"#
    private static let shipped = #"\bdeploy|\bshipped\b|\breleased?\b|\bis live\b|\blive on\b|\blaunched\b|\bmerged\b|\bpublished\b"#
    private static let tiny = #"\btypo|\blint\b|whitespace|\brenamed?\b|one-liner|\bnit\b|small fix|tiny"#
    private static let surprising = #"\bfound \d+|unexpected|turns out|surpris"#
    private static let green = #"\bpass(es|ed)?\b|\bgreen\b|\ball \d+\b|100%|\bfaster\b|lighthouse|benchmark|\bclean\b"#

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
