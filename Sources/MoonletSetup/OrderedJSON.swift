import Foundation

/// A JSON value that keeps object keys in their original order, so config files can be
/// edited without reshuffling them.
///
/// `formatted()` prints like `JSON.stringify(value, null, 2)`, the format Claude Code
/// writes, so a parsed file in that format prints back byte for byte.
public enum OrderedJSON: Sendable, Equatable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// A number, kept exactly as written.
    case number(String)
    case bool(Bool)
    case null

    /// One key-value pair of an object.
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    /// A syntax error, located by 1-based line and column (in UTF-8 bytes).
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public let line: Int
        public let column: Int

        public var description: String {
            "\(message) at line \(line), column \(column)"
        }
    }

    /// Parses a JSON document. A leading byte order mark is ignored.
    public init(parsing text: String) throws {
        var parser = Parser(bytes: Array(text.utf8))
        self = try parser.parseDocument()
    }

    /// The value of the last member named `key`, if this is an object.
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    /// The value printed with two-space indentation and no trailing newline.
    public func formatted() -> String {
        var output = ""
        write(to: &output, indent: "")
        return output
    }

    private func write(to output: inout String, indent: String) {
        switch self {
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += indent + "  " + Self.quoted(member.key) + ": "
                member.value.write(to: &output, indent: indent + "  ")
                output += index < members.count - 1 ? ",\n" : "\n"
            }
            output += indent + "}"
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            output += "[\n"
            for (index, element) in elements.enumerated() {
                output += indent + "  "
                element.write(to: &output, indent: indent + "  ")
                output += index < elements.count - 1 ? ",\n" : "\n"
            }
            output += indent + "]"
        case .string(let string):
            output += Self.quoted(string)
        case .number(let number):
            output += number
        case .bool(let bool):
            output += bool ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    /// A JSON string literal, escaped the way `JSON.stringify` does it.
    static func quoted(_ string: String) -> String {
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
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension [OrderedJSON.Member] {
    /// The value of the last member named `key`.
    subscript(key: String) -> OrderedJSON? {
        last { $0.key == key }?.value
    }
}

/// A recursive-descent JSON parser over UTF-8 bytes.
private struct Parser {
    /// Deep enough for any config file, and shallow enough to stay well within the
    /// 512 KiB stack of a secondary thread.
    private static let maxDepth = 64

    let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> OrderedJSON {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected text after the JSON value") }
        return value
    }

    private mutating func parseValue() throws -> OrderedJSON {
        guard let byte = peek() else { throw error("Unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character")
        }
    }

    private mutating func parseObject() throws -> OrderedJSON {
        try enterContainer()
        defer { depth -= 1 }
        var members: [OrderedJSON.Member] = []
        skipWhitespace()
        if consume(UInt8(ascii: "}")) {
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error("Expected a string key") }
            let key = try parseString()
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw error("Expected ':' after the key") }
            skipWhitespace()
            members.append(OrderedJSON.Member(key, try parseValue()))
            skipWhitespace()
            if consume(UInt8(ascii: "}")) {
                return .object(members)
            }
            guard consume(UInt8(ascii: ",")) else { throw error("Expected ',' or '}'") }
        }
    }

    private mutating func parseArray() throws -> OrderedJSON {
        try enterContainer()
        defer { depth -= 1 }
        var elements: [OrderedJSON] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) {
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            if consume(UInt8(ascii: "]")) {
                return .array(elements)
            }
            guard consume(UInt8(ascii: ",")) else { throw error("Expected ',' or ']'") }
        }
    }

    private mutating func enterContainer() throws {
        guard depth < Self.maxDepth else { throw error("Nesting is too deep") }
        depth += 1
        index += 1
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var utf8: [UInt8] = []
        while let byte = peek() {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try parseEscape(into: &utf8)
            case 0x00..<0x20:
                index -= 1
                throw error("Unescaped control character in a string")
            default:
                utf8.append(byte)
            }
        }
        throw error("Unterminated string")
    }

    private mutating func parseEscape(into utf8: inout [UInt8]) throws {
        guard let byte = peek() else { throw error("Unterminated string") }
        index += 1
        let simple: [UInt8: UInt8] = [
            UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "/"): 0x2F,
            UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): 0x0A,
            UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
        ]
        if let replacement = simple[byte] {
            utf8.append(replacement)
            return
        }
        guard byte == UInt8(ascii: "u") else {
            index -= 1
            throw error("Invalid escape sequence")
        }
        var scalarValue = try parseHexQuad()
        if (0xD800..<0xDC00).contains(scalarValue), bytes[index...].starts(with: Array(#"\u"#.utf8)) {
            let resume = index
            index += 2
            let low = try parseHexQuad()
            if (0xDC00..<0xE000).contains(low) {
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
            } else {
                index = resume
            }
        }
        // Lone surrogates can't live in a Swift string; they become U+FFFD.
        let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
        utf8.append(contentsOf: String(scalar).utf8)
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count,
            bytes[index..<index + 4].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
            let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("Invalid \\u escape") }
        index += 4
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consume(UInt8(ascii: "-"))
        if consume(UInt8(ascii: "0")) {
            // A leading zero stands alone.
        } else {
            guard consumeDigits() else { throw error("Invalid number") }
        }
        if consume(UInt8(ascii: ".")) {
            guard consumeDigits() else { throw error("Invalid number") }
        }
        if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
            _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
            guard consumeDigits() else { throw error("Invalid number") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func consumeDigits() -> Bool {
        let start = index
        while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
            index += 1
        }
        return index > start
    }

    private mutating func parseLiteral(_ literal: String, _ value: OrderedJSON) throws -> OrderedJSON {
        guard bytes[index...].starts(with: literal.utf8) else { throw error("Unexpected character") }
        index += literal.utf8.count
        return value
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            index += 1
        }
    }

    private func error(_ message: String) -> OrderedJSON.ParseError {
        let consumed = bytes[..<min(index, bytes.count)]
        let line = consumed.count { $0 == 0x0A } + 1
        let lineStart = consumed.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        return OrderedJSON.ParseError(message: message, line: line, column: index - lineStart + 1)
    }
}
