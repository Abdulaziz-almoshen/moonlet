import Foundation

/// Reads Claude Code session transcripts: JSONL files with one entry per line.
public enum ClaudeTranscript {
    /// How much of a transcript's end to read: 512 KiB.
    public static let tailLength = 512 * 1024

    /// The last `maxBytes` of the file at `path`, or `nil` if it can't be read.
    /// The first line may be partial.
    public static func readTail(atPath path: String, maxBytes: Int = tailLength) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size - min(size, UInt64(maxBytes)))
            // Never more than `maxBytes`, even while the agent appends to the file.
            return String(decoding: try handle.read(upToCount: maxBytes) ?? Data(), as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// The text of the last assistant message in the end of a transcript.
    ///
    /// Claude Code writes each content block of a message as its own entry, so the text
    /// blocks of the last message that has any text are joined with blank lines. Subagent
    /// (sidechain) entries, API error entries, and unparseable lines (such as a partial
    /// first line) are skipped.
    public static func lastAssistantText(fromTail tail: String) -> String? {
        var messageID: String?
        var texts: [String] = []
        for line in tail.split(whereSeparator: \.isNewline).reversed() {
            // Cheap pre-check: escaped JSON inside other entries can't contain this.
            guard line.contains(#""assistant""#),
                let entry = JSONFields(data: Data(line.utf8)),
                entry.string("type") == "assistant",
                entry.bool("isSidechain") != true,
                entry.bool("isApiErrorMessage") != true,
                let message = entry.object("message")
            else { continue }

            let id = message.string("id")
            let blocks = textBlocks(message["content"])
            if let target = messageID {
                guard id == target else { break }
                texts.insert(contentsOf: blocks, at: 0)
            } else if !blocks.isEmpty {
                texts = blocks
                guard let id else { break }
                messageID = id
            }
        }
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func textBlocks(_ content: Any?) -> [String] {
        if let text = content as? String {
            return [text]
        }
        return (content as? [Any] ?? []).compactMap { block in
            guard let block = JSONFields(block), block.string("type") == "text" else { return nil }
            return block.nonEmptyString("text")
        }
    }
}
