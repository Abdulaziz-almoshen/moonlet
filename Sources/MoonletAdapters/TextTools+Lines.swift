import MoonletCore

extension TextTools {
    /// The first non-blank line of `text`, collapsed and shortened to `max` characters.
    static func firstLine(of text: String, max: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        return oneLine(line.map(String.init) ?? "", max: max)
    }
}
