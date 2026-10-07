import Foundation

/// Reads Codex session transcripts (rollout files): JSONL with one item per line,
/// `{"timestamp":…,"type":…,"payload":{…}}`.
public enum CodexTranscript {
    /// How much of a transcript's end to read: 256 KiB.
    public static let tailLength = 256 * 1024

    /// The `approvals_reviewer` that hands approval requests to Codex's automatic reviewer
    /// instead of the user.
    static let automaticReviewer = "auto_review"

    /// The last `tailLength` bytes of the transcript at `path`, or `nil` if it can't be
    /// read. The first line may be partial.
    public static func readTail(atPath path: String) -> String? {
        ClaudeTranscript.readTail(atPath: path, maxBytes: tailLength)
    }

    /// Who answers approval requests, from the last `turn_context` item in the end of a
    /// transcript: `"auto_review"` or `"user"`. `nil` when the tail holds no readable
    /// `turn_context`, or it doesn't say.
    static func approvalsReviewer(fromTail tail: String) -> String? {
        for line in tail.split(whereSeparator: \.isNewline).reversed() where line.contains(#""turn_context""#) {
            guard let item = JSONFields(data: Data(line.utf8)), item.string("type") == "turn_context" else { continue }
            return item.object("payload")?.string("approvals_reviewer")
        }
        return nil
    }
}
