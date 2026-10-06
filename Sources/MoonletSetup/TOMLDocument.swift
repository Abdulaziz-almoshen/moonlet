import Foundation

/// Just enough TOML to find and rewrite top-level `key = value` lines while leaving every
/// other byte of the file alone.
struct TOMLDocument {
    /// A top-level key-value pair.
    struct KeyValue {
        /// The key as written, without surrounding whitespace.
        let key: String
        /// From the start of the key's line through the line break that ends the value
        /// (or the end of the text).
        let range: Range<String.Index>
        /// The value as written.
        let valueRange: Range<String.Index>

        /// Whether the key is `name`, bare or quoted.
        func isKey(_ name: String) -> Bool {
            key == name || key == "\"\(name)\"" || key == "'\(name)'"
        }
    }

    /// Why a file couldn't be scanned, with a 1-based line number.
    struct SyntaxError: Error, CustomStringConvertible {
        let message: String
        let line: Int

        var description: String { "\(message) on line \(line)" }
    }

    let text: String
    /// The key-value pairs before the first table header.
    let topLevel: [KeyValue]

    init(_ text: String) throws {
        self.text = text
        var cursor = Cursor(text)
        var topLevel: [KeyValue] = []
        while let character = cursor.skipBlanks() {
            let lineStart = cursor.lineStart
            switch character {
            case "\n", "\r":
                cursor.advance()
            case "#":
                cursor.skipComment()
            case "[":
                // The first table header: everything from here on belongs to tables.
                self.topLevel = topLevel
                return
            default:
                let keyStart = cursor.index
                try cursor.scanKey()
                let key = text[keyStart..<cursor.index].trimmingCharacters(in: .whitespaces)
                cursor.advance()  // "="
                _ = cursor.skipBlanks()
                let valueStart = cursor.index
                try cursor.scanValue()
                let valueEnd = cursor.index
                try cursor.finishLine()
                let value = text[valueStart..<valueEnd]
                let trimmedEnd = value.lastIndex { $0 != " " && $0 != "\t" }.map { value.index(after: $0) } ?? valueStart
                topLevel.append(KeyValue(key: key, range: lineStart..<cursor.index, valueRange: valueStart..<trimmedEnd))
            }
        }
        self.topLevel = topLevel
    }

    // MARK: String arrays

    /// The strings of an array value such as `["a", 'b']`, or `nil` if the value is
    /// anything else.
    static func stringArray(_ value: Substring) -> [String]? {
        var cursor = Cursor(String(value))
        guard cursor.current == "[" else { return nil }
        cursor.advance()
        var strings: [String] = []
        while true {
            cursor.skipWhitespaceAndComments()
            if cursor.current == "]" {
                cursor.advance()
                break
            }
            guard let string = try? cursor.parseString() else { return nil }
            strings.append(string)
            cursor.skipWhitespaceAndComments()
            if cursor.current == "," {
                cursor.advance()
            } else if cursor.current == "]" {
                cursor.advance()
                break
            } else {
                return nil
            }
        }
        cursor.skipWhitespaceAndComments()
        return cursor.current == nil ? strings : nil
    }

    /// An inline array of basic strings, such as `["a", "b"]`.
    static func render(_ strings: [String]) -> String {
        "[" + strings.map(basicString).joined(separator: ", ") + "]"
    }

    private static func basicString(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

/// Walks TOML text one Unicode scalar at a time.
private struct Cursor {
    private let text: String
    private let scalars: String.UnicodeScalarView
    private(set) var index: String.Index
    /// The start of the line holding `index`.
    private(set) var lineStart: String.Index

    init(_ text: String) {
        self.text = text
        scalars = text.unicodeScalars
        index = scalars.startIndex
        lineStart = index
    }

    var current: Unicode.Scalar? {
        index < scalars.endIndex ? scalars[index] : nil
    }

    private func hasPrefix(_ prefix: String) -> Bool {
        scalars[index...].starts(with: prefix.unicodeScalars)
    }

    mutating func advance(by count: Int = 1) {
        for _ in 0..<count where index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if scalar == "\n" {
                lineStart = index
            }
        }
    }

    /// Skips spaces and tabs, returning the scalar after them.
    mutating func skipBlanks() -> Unicode.Scalar? {
        while current == " " || current == "\t" {
            advance()
        }
        return current
    }

    /// Skips to the end of the line, stopping before its line break.
    mutating func skipComment() {
        while let scalar = current, scalar != "\n" {
            advance()
        }
    }

    mutating func skipWhitespaceAndComments() {
        while let scalar = current {
            if scalar == "#" {
                skipComment()
            } else if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                advance()
            } else {
                return
            }
        }
    }

    /// Moves to the `=` that ends a key, stepping over quoted parts.
    mutating func scanKey() throws {
        let start = index
        while let scalar = current {
            switch scalar {
            case "=":
                guard text[start..<index].contains(where: { !$0.isWhitespace }) else { throw error("Expected a key") }
                return
            case "\"", "'":
                try skipString()
            case "\n", "\r":
                throw error("Expected '=' after a key")
            default:
                advance()
            }
        }
        throw error("Expected '=' after a key")
    }

    /// Moves past a value: through the end of any string, array, or inline table, and up
    /// to the comment or line break that follows it.
    mutating func scanValue() throws {
        var depth = 0
        while let scalar = current {
            switch scalar {
            case "\"", "'":
                try skipString()
            case "[", "{":
                depth += 1
                advance()
            case "]", "}":
                depth -= 1
                guard depth >= 0 else { throw error("Unbalanced '\(scalar)'") }
                advance()
            case "#":
                guard depth > 0 else { return }
                skipComment()
            case "\n", "\r":
                guard depth > 0 else { return }
                advance()
            default:
                advance()
            }
        }
        guard depth == 0 else { throw error("Unterminated array or inline table") }
    }

    /// Consumes trailing blanks, an optional comment, and the line break.
    mutating func finishLine() throws {
        if skipBlanks() == "#" {
            skipComment()
        }
        if current == "\r" {
            advance()
        }
        if current == "\n" {
            advance()
        } else if current != nil {
            throw error("Unexpected text after a value")
        }
    }

    private mutating func skipString() throws {
        _ = try parseString()
    }

    /// Parses any of TOML's four string forms and returns its value.
    mutating func parseString() throws -> String {
        guard let quote = current, quote == "\"" || quote == "'" else { throw error("Expected a string") }
        let isBasic = quote == "\""
        let delimiter = String(repeating: Character(quote), count: 3)
        var result = ""
        if hasPrefix(delimiter) {
            advance(by: 3)
            // A line break right after the opening delimiter isn't part of the string.
            if current == "\r" {
                advance()
            }
            if current == "\n" {
                advance()
            }
            while current != nil {
                if hasPrefix(delimiter) {
                    advance(by: 3)
                    // Up to two more quotes belong to the content ("""a"""" is `a"`).
                    for _ in 0..<2 where current == quote {
                        result.unicodeScalars.append(quote)
                        advance()
                    }
                    return result
                }
                if isBasic, current == "\\" {
                    try parseEscape(into: &result, multiline: true)
                } else if let scalar = current {
                    result.unicodeScalars.append(scalar)
                    advance()
                }
            }
            throw error("Unterminated multi-line string")
        }
        advance()
        while let scalar = current {
            switch scalar {
            case quote:
                advance()
                return result
            case "\n", "\r":
                throw error("Unterminated string")
            case "\\" where isBasic:
                try parseEscape(into: &result, multiline: false)
            default:
                result.unicodeScalars.append(scalar)
                advance()
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseEscape(into result: inout String, multiline: Bool) throws {
        advance()  // backslash
        guard let scalar = current else { throw error("Unterminated string") }
        let simple: [Unicode.Scalar: Unicode.Scalar] = [
            "b": "\u{08}", "t": "\t", "n": "\n", "f": "\u{0C}", "r": "\r", "e": "\u{1B}", "\"": "\"", "\\": "\\",
        ]
        if let replacement = simple[scalar] {
            result.unicodeScalars.append(replacement)
            advance()
        } else if scalar == "u" || scalar == "U" {
            let length = scalar == "u" ? 4 : 8
            advance()
            var hex = ""
            for _ in 0..<length {
                guard let digit = current, Character(digit).isHexDigit else { throw error("Invalid unicode escape") }
                hex.unicodeScalars.append(digit)
                advance()
            }
            guard let value = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(value) else {
                throw error("Invalid unicode escape")
            }
            result.unicodeScalars.append(unicode)
        } else if multiline, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            // A line-ending backslash trims the line break and the whitespace after it.
            while let next = current, next == " " || next == "\t" || next == "\n" || next == "\r" {
                advance()
            }
        } else {
            throw error("Invalid escape sequence")
        }
    }

    private func error(_ message: String) -> TOMLDocument.SyntaxError {
        let line = text.unicodeScalars[..<index].count { $0 == "\n" } + 1
        return TOMLDocument.SyntaxError(message: message, line: line)
    }
}
