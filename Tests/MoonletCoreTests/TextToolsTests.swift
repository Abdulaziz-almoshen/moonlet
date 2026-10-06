import Testing

@testable import MoonletCore

@Suite("TextTools")
struct TextToolsTests {
    @Test(arguments: [
        ("I fixed the bug. Then I ran the tests.", "I fixed the bug."),
        ("## Summary\n\nRefactored the **parser** to handle `null` values. Tests pass.",
         "Refactored the parser to handle null values."),
        ("Here's the fix:\n\n```swift\nlet x = 1\n```\n\nIt works now.", "Here's the fix:"),
        ("- Updated [the docs](https://example.com/docs) and _README_\n- Added tests", "Updated the docs and README"),
        ("Bumped to v1.2.3 in Parser.swift, e.g. the tokenizer. Done!", "Bumped to v1.2.3 in Parser.swift, e.g. the tokenizer."),
        ("Is it ready? Yes.", "Is it ready?"),
        ("Wow!! That worked.", "Wow!!"),
        ("He said \"done.\" Then he left.", "He said \"done.\""),
        ("1. First step\n2. Second step", "First step"),
        ("- [x] Ship it\n- [ ] Announce it", "Ship it"),
        ("> Quoted line. More.", "Quoted line."),
        ("snake_case_name stays intact.", "snake_case_name stays intact."),
        ("`__init__` is special. Ok.", "__init__ is special."),
        ("Wrapped line one\ncontinues here. Next.", "Wrapped line one continues here."),
        ("~~Old~~ new approach works.", "Old new approach works."),
        ("![diagram](flow.png) shows the flow.", "diagram shows the flow."),
        ("See <https://example.com> for details.", "See https://example.com for details."),
        ("Tables:\n\n| a | b |\n|---|---|\n| 1 | 2 |", "Tables:"),
        ("---\n\nAfter a rule.", "After a rule."),
        ("# Only a heading", "Only a heading"),
        ("```\ncode only\n```", ""),
        ("", ""),
    ])
    func firstSentence(markdown: String, expected: String) {
        #expect(TextTools.firstSentence(markdown) == expected)
    }

    @Test func firstSentenceTruncatesAtAWordBoundary() {
        let text = "This sentence keeps going and going well past the limit that we set for it"
        #expect(TextTools.firstSentence(text, maxLength: 30) == "This sentence keeps going and…")
        #expect(TextTools.firstSentence(text, maxLength: 28) == "This sentence keeps going…")
        #expect(TextTools.firstSentence(text, maxLength: 120) == text)
    }

    @Test func oneLineCollapsesWhitespace() {
        #expect(TextTools.oneLine("  Running\n\t npm   test  ", max: 60) == "Running npm test")
    }

    @Test func oneLineShortensWithAnEllipsis() {
        #expect(TextTools.oneLine("abcdefghij", max: 5) == "abcd…")
        #expect(TextTools.oneLine("hello world again", max: 12) == "hello world…")
        #expect(TextTools.oneLine("Ends with a comma, then more words", max: 19) == "Ends with a comma…")
        #expect(TextTools.oneLine("abc", max: 3) == "abc")
        #expect(TextTools.oneLine("abc", max: 1) == "…")
        #expect(TextTools.oneLine("abc", max: 0) == "")
    }

    @Test func oneLineCountsCharactersNotBytes() {
        #expect(TextTools.oneLine("héllo wörld 🎉🎉", max: 14) == "héllo wörld 🎉🎉")
        #expect(TextTools.oneLine("🎉🎉🎉🎉", max: 3) == "🎉🎉…")
    }

    @Test(arguments: [
        ("/Users/example/code/api", "api"),
        ("/Users/example/code/api/", "api"),
        ("relative/dir", "dir"),
        (" /x/padded \n", "padded"),
        ("/", "/"),
        ("", ""),
    ])
    func labelFromCwd(cwd: String, expected: String) {
        #expect(TextTools.label(fromCwd: cwd) == expected)
    }
}
