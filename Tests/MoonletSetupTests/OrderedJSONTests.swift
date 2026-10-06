import Foundation
import Testing

@testable import MoonletSetup

@Suite("OrderedJSON")
struct OrderedJSONTests {
    @Test(arguments: [
        """
        {
          "zeta": 1,
          "alpha": {
            "nested": [
              true,
              false,
              null
            ],
            "empty": {},
            "none": []
          },
          "mid": "text"
        }
        """,
        """
        {
          "env": {
            "PATH_EXTRA": "/opt/tools/bin"
          },
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/.claude/skills/gstack/bin/timeline-stop-hook",
                    "timeout": 10
                  }
                ],
                "_gstack_source": "timeline"
              }
            ]
          }
        }
        """,
        "[]",
        "{}",
        "\"just a string\"",
        "-0.5e+10",
    ])
    func formattedTextRoundTripsByteForByte(text: String) throws {
        #expect(try OrderedJSON(parsing: text).formatted() == text)
    }

    @Test func keepsKeyOrderAndNumberSpelling() throws {
        let value = try OrderedJSON(parsing: #"{"b": 1.50, "a": 1e3, "c": -0, "d": 10}"#)
        guard case .object(let members) = value else {
            Issue.record("Expected an object")
            return
        }
        #expect(members.map(\.key) == ["b", "a", "c", "d"])
        #expect(members.map(\.value) == [.number("1.50"), .number("1e3"), .number("-0"), .number("10")])
    }

    @Test func decodesEscapes() throws {
        let value = try OrderedJSON(parsing: #""quote \" slash \/ back \\ tab \t nl \n e \u00e9 smile \ud83d\ude00""#)
        #expect(value == .string("quote \" slash / back \\ tab \t nl \n e é smile 😀"))
    }

    @Test func escapesLikeJSONStringify() {
        let value = OrderedJSON.string("a\"b\\c\nd\te\u{1B}f/é😀\u{2028}")
        #expect(value.formatted() == #""a\"b\\c\nd\te\u001bf/é😀"# + "\u{2028}\"")
    }

    @Test func loneSurrogatesBecomeReplacementCharacters() throws {
        #expect(try OrderedJSON(parsing: #""\ud800x""#) == .string("\u{FFFD}x"))
    }

    @Test func subscriptReadsTheLastDuplicate() throws {
        let value = try OrderedJSON(parsing: #"{"a": 1, "a": 2}"#)
        #expect(value["a"] == .number("2"))
        #expect(value["missing"] == nil)
        #expect(OrderedJSON.array([])["a"] == nil)
    }

    @Test func ignoresAByteOrderMark() throws {
        #expect(try OrderedJSON(parsing: "\u{FEFF}{\"a\": true}") == .object([OrderedJSON.Member("a", .bool(true))]))
    }

    @Test(arguments: [
        ("{", 1, 2),
        ("{\n  \"a\": tru\n}", 2, 8),
        ("[1,]", 1, 4),
        ("{\"a\" 1}", 1, 6),
        ("01", 1, 2),
        ("1.", 1, 3),
        ("\"tab\there\"", 1, 5),
        ("\"\\x\"", 1, 3),
        ("\"\\u12g4\"", 1, 4),
        ("[] []", 1, 4),
        ("", 1, 1),
    ])
    func reportsWhereSyntaxErrorsAre(text: String, line: Int, column: Int) {
        #expect {
            try OrderedJSON(parsing: text)
        } throws: { error in
            guard let error = error as? OrderedJSON.ParseError else { return false }
            return error.line == line && error.column == column
        }
    }

    @Test func limitsNestingDepth() {
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON(parsing: deep) }
        let fine = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        #expect((try? OrderedJSON(parsing: fine)) != nil)
    }
}
