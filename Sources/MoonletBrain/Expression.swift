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
    /// A tiny fix: a typo, lint, whitespace.
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
    /// No news for a long time, or a finished turn that reports bad news.
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
    /// the mood within it. A finished turn that reports bad news is read as bad
    /// news first, so a failed deploy is never a celebration. Only the first
    /// 500 characters are read.
    public static func read(kind: MomentKind, detail: String) -> CompanionMood {
        let text = String(detail.prefix(500))
        switch kind {
        case .needsYou, .question:
            if risky.matches(text) { return .nervous }
            if kind == .question || text.contains("?") || asksToChoose.matches(text) { return .curious }
            return .asking
        case .failed:
            return waitsForLimit.matches(text) ? .sleepy : .teary
        case .stuck:
            return .worried
        case .finished:
            if badNews.matches(allClear.removing(from: text)) || hitLimit.matches(text) {
                return waitsForLimit.matches(text) ? .sleepy : .worried
            }
            if thanks.matches(text) { return .grateful }
            if shipped.matches(text) { return .celebrate }
            if tiny.matches(text) { return .cheeky }
            if surprising.matches(text) { return .surprised }
            if green.matches(text) { return .proud }
            return .happy
        }
    }

    private static let risky = Pattern(#"rm -rf|\bdelete\b|\bdrop (table|database)\b|--force|force[- ]push|push -f|\bsudo\b|reset --hard|\bwipe\b|\bprod(uction)?\b"#)
    private static let asksToChoose = Pattern(#"^(which|should|do you|would you|can i|may i)\b|\bprefer\b|\bchoose\b"#)
    private static let waitsForLimit = Pattern(#"rate.?limit|usage limit|quota|overloaded|try again later|\bback at\b"#)
    /// A finished turn that ran into a limit: the agent has to wait.
    private static let hitLimit = Pattern(#"\b(hit|reached|exceeded)( the| my| your| a)? (rate|usage) ?limit|\brate.?limited\b|\busage limit\b|\bquota (exceeded|reached)\b|\boverloaded\b|\btry again later\b"#)
    /// Words that mean the turn did not go well, whatever else it says.
    private static let badNews = Pattern(#"\bfail(s|ed|ing|ures?)?\b|\b(could|ca|did|was|is|wo)n['’]?t\b|\bcannot\b|\bunable\b|\bnot (yet )?(deployed|merged|released|shipped|published|passing)\b|\bblocked\b|\berrors?\b|\bregress|\bbroken?\b|\bdropped\b|\bstill (failing|red|broken)\b|\bci is red\b|\bmissing\b|\brefused\b|\bdenied\b|\btimed out\b"#)
    /// Good news phrased with a bad word, set aside before looking for bad news:
    /// `no errors`, `0 failures`, `fixed 3 lint errors`, `added the missing tests`,
    /// `error handling`, `regression tests`.
    private static let allClear = Pattern(#"\b(no|0|zero|without)( new)? (errors?|failures?|regressions?|failing tests?)\b|\b(fix(ed|es)?|resolved|handled?|added)( the| a| an| all| both| \d+)?( \w+)? (errors?|failures?|failing|broken|regressions?|missing)\b|\berror (handling|messages?|states?|pages?|codes?|boundar(y|ies)|logging|reporting)\b|\bregression tests?\b"#)
    private static let thanks = Pattern(#"\bthank"#)
    private static let shipped = Pattern(#"\b(deployed|shipped|released|merged|published)\b|\bis (now )?live\b|\blive on\b"#)
    private static let tiny = Pattern(#"\btypos?\b|\blint\b|\bwhitespace\b|\bone-liner\b|\bnits?\b|\bsmall fix\b|\btiny fix\b"#)
    private static let surprising = Pattern(#"\bfound \d+|unexpected|turns out|surpris"#)
    private static let green = Pattern(#"\bpass(es|ed)?\b|\bgreen\b|\ball \d+\b|100%|\bfaster\b|lighthouse|benchmark|\bclean\b"#)

    /// A case-insensitive pattern, compiled once.
    private struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String) {
            // The patterns are literals, so failing to compile is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }

        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        /// `text` with every match blanked out.
        func removing(from text: String) -> String {
            regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
    }
}
