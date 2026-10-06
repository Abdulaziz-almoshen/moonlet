import Foundation

/// A finished agent's final message, boiled down for a card.
public struct Summary: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// What the agent accomplished or ran into.
        case outcome
        /// The agent ended by asking the user something.
        case question
    }

    public var kind: Kind
    /// At most a handful of words.
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Builds prompts for a small local model and turns its reply into a ``Summary``,
/// with a plain fallback when no model is available.
public enum SummaryWriter {
    public static let systemPrompt = """
        You write the status line of a tiny notification about a coding agent. \
        Reply with at most 6 words: the outcome, with numbers when present. \
        No trailing punctuation, no quotes, no emoji. \
        If the message ends by asking the user a question or for a decision, \
        reply 'ASK: ' plus that question in at most 6 words.
        """

    /// Longest reply kept, in characters.
    public static let maximumLength = 60

    /// The user message for the model: the start and the end of the final
    /// message, where agents state what they did and what they need.
    public static func prompt(for finalMessage: String, budget: Int = 1800) -> String {
        let text = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > budget else { return "Agent's final message:\n\(text)" }
        let head = text.prefix(budget / 4)
        let tail = text.suffix(budget - budget / 4)
        return "Agent's final message:\n\(head)\n…\n\(tail)"
    }

    /// Parses a model reply. Returns nil for empty or rambling replies, so the
    /// caller can fall back.
    public static func parse(_ reply: String) -> Summary? {
        var text = reply
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = text.split(whereSeparator: \.isNewline).first { text = String(firstLine) }
        var kind = Summary.Kind.outcome
        if text.uppercased().hasPrefix("ASK:") {
            kind = .question
            text = String(text.dropFirst(4))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*"))
        if kind == .outcome {
            while let last = text.last, ".!;:,".contains(last) { text.removeLast() }
        }
        // A reply that explains itself instead of answering is useless on a card.
        let words = text.split(separator: " ")
        guard !text.isEmpty, words.count <= 10, !text.lowercased().hasPrefix("we are given") else { return nil }
        return Summary(kind: kind, text: String(text.prefix(maximumLength)))
    }

    /// Summary without a model: the first sentence, trimmed, and a question
    /// check on the ending.
    public static func fallback(for finalMessage: String) -> Summary {
        let asks = QuestionDetector.asksUser(finalMessage)
        let source = asks ? QuestionDetector.lastSentences(of: finalMessage, count: 1) : firstSentence(of: finalMessage)
        return Summary(kind: asks ? .question : .outcome, text: shorten(source))
    }

    static func firstSentence(of text: String) -> String {
        let cleaned = QuestionDetector.lastSentences(of: text, count: Int.max)
        var first = ""
        cleaned.enumerateSubstrings(in: cleaned.startIndex..., options: .bySentences) { sentence, _, _, stop in
            first = sentence?.trimmingCharacters(in: .whitespaces) ?? ""
            stop = true
        }
        return first
    }

    /// `text` cut to ``maximumLength`` at a word boundary, without a final period.
    public static func shorten(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix(".") { result.removeLast() }
        guard result.count > maximumLength else { return result }
        let cut = result.prefix(maximumLength - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}
