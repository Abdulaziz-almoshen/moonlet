import Foundation

/// Helpers for squeezing agent text into a short, glanceable line.
public enum TextTools {
    /// The first sentence of a Markdown message, as plain text.
    ///
    /// Drops fenced code, headings (unless nothing else is left), list markers, emphasis,
    /// and inline code ticks, and turns `[text](url)` into `text`. Whitespace is collapsed
    /// and the text is cut at the first sentence end. A result longer than `maxLength`
    /// is shortened at a word boundary and ends with "…".
    public static func firstSentence(_ markdown: String, maxLength: Int = 120) -> String {
        let blocks = MarkdownBlocks.parse(markdown)
        guard let block = blocks.first(where: { !$0.isHeading }) ?? blocks.first else { return "" }
        let text = collapsed(MarkdownInline.plainText(block.text))
        return truncated(sentencePrefix(of: text), to: maxLength)
    }

    /// `text` on one line with whitespace collapsed, shortened to at most `max` characters
    /// (ending with "…" when shortened).
    public static func oneLine(_ text: String, max: Int) -> String {
        truncated(collapsed(text), to: max)
    }

    /// A short label for a working directory: its last path component.
    public static func label(fromCwd cwd: String) -> String {
        let path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    // MARK: Internals

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Shortens `text` to at most `limit` characters, preferring a word boundary, and
    /// appends "…" when anything was cut.
    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return limit == 1 ? "…" : "" }
        var cut = String(text.prefix(limit - 1))
        let endsAtWordBoundary = text.dropFirst(limit - 1).first?.isWhitespace == true
        if !endsAtWordBoundary, let space = cut.lastIndex(of: " "),
            cut.distance(from: cut.startIndex, to: space) >= limit / 2
        {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last.isWhitespace || ",;:-–—".contains(last) {
            cut.removeLast()
        }
        return cut + "…"
    }

    /// The text up to and including its first sentence end, or all of it if there's none.
    static func sentencePrefix(of text: String) -> String {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard ".!?…".contains(character) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, ".!?…".contains(characters[end]) {
                end += 1
            }
            while end < characters.count, "\"'”’)]".contains(characters[end]) {
                end += 1
            }
            let atBoundary = end == characters.count || characters[end].isWhitespace
            if atBoundary, !(character == "." && endsWithAbbreviation(characters, dotIndex: index)) {
                return String(characters[..<end])
            }
            index = end
        }
        return text
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr"]

    private static func endsWithAbbreviation(_ characters: [Character], dotIndex: Int) -> Bool {
        var start = dotIndex
        while start > 0, !characters[start - 1].isWhitespace, characters[start - 1] != "(" {
            start -= 1
        }
        return abbreviations.contains(String(characters[start..<dotIndex]).lowercased())
    }
}

/// Splits Markdown into paragraphs, list items, and headings, dropping code and rules.
private enum MarkdownBlocks {
    struct Block {
        var text: String
        var isHeading: Bool
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var openFence: String?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(Block(text: paragraph.joined(separator: " "), isHeading: false))
                paragraph.removeAll()
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = openFence {
                if line.hasPrefix(fence) {
                    openFence = nil
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                openFence = String(line.prefix(3))
            } else if line.isEmpty || isRule(line) || isTableDivider(line) {
                flush()
            } else if let heading = headingText(line) {
                flush()
                blocks.append(Block(text: heading, isHeading: true))
            } else if let item = listItemText(line) {
                flush()
                paragraph.append(item)
            } else {
                paragraph.append(quoteStripped(line))
            }
        }
        flush()
        return blocks
    }

    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func listItemText(_ line: String) -> String? {
        var rest: Substring
        if let marker = line.first, "-*+".contains(marker) {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { return nil }
            rest = line.dropFirst(digits.count)
            guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.first?.isWhitespace == true else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
            text.removeFirst(box.count)
        }
        return text
    }

    private static func quoteStripped(_ line: String) -> String {
        guard line.hasPrefix(">") else { return line }
        return String(line.drop { $0 == ">" || $0 == " " })
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        line.contains("|") && line.contains("-") && line.allSatisfy { "|:- ".contains($0) }
    }
}

/// Strips inline Markdown, keeping the content of code spans verbatim.
private enum MarkdownInline {
    static func plainText(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let tickStart = rest.firstIndex(of: "`") {
            result += stripMarkup(String(rest[..<tickStart]))
            let afterTicks = rest[tickStart...].drop { $0 == "`" }
            let fence = String(rest[tickStart..<afterTicks.startIndex])
            if let close = afterTicks.range(of: fence) {
                result += afterTicks[..<close.lowerBound]
                rest = afterTicks[close.upperBound...]
            } else {
                rest = afterTicks
            }
        }
        return result + stripMarkup(String(rest))
    }

    private struct Rewrite: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String) {
            // The patterns are literals, so failing to compile is a programming error.
            regex = try! NSRegularExpression(pattern: pattern)
            self.template = template
        }
    }

    private static let rewrites: [Rewrite] = [
        Rewrite(#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),  // images
        Rewrite(#"\[([^\]]+)\]\([^)]*\)"#, "$1"),  // inline links
        Rewrite(#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),  // reference links
        Rewrite(#"<(https?://[^>\s]+)>"#, "$1"),  // autolinks
        Rewrite(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2"),  // bold
        Rewrite(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1"),  // *italic*
        Rewrite(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1"),  // _italic_
        Rewrite(#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),  // strikethrough
    ]

    private static func stripMarkup(_ text: String) -> String {
        rewrites.reduce(text) { text, rewrite in
            rewrite.regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rewrite.template)
        }
    }
}
