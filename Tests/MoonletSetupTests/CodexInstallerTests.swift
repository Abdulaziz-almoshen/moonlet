import Foundation
import Testing

@testable import MoonletSetup

@Suite("CodexInstaller")
struct CodexInstallerTests {
    private let moonlet = "/usr/local/bin/moonlet"
    private let ourLine = #"notify = ["/usr/local/bin/moonlet", "hook", "codex"]"#

    private func install(_ text: String, path: String? = nil) throws -> InstallPlan {
        try CodexInstaller.plan(configText: text, moonletPath: path ?? moonlet, action: .install)
    }

    private func uninstall(_ text: String) throws -> InstallPlan {
        try CodexInstaller.plan(configText: text, moonletPath: moonlet, action: .uninstall)
    }

    /// Installs, checks idempotence, uninstalls, and checks the original comes back exactly.
    private func roundTrip(_ original: String, expectInstalled expected: String) throws {
        let installed = try install(original)
        #expect(installed.hasChanges)
        #expect(installed.newText == expected)
        let again = try install(installed.newText)
        #expect(!again.hasChanges)
        #expect(again.newText == installed.newText)
        let removed = try uninstall(installed.newText)
        #expect(removed.hasChanges)
        #expect(removed.newText == original)
        #expect(try !uninstall(removed.newText).hasChanges)
    }

    // MARK: No existing notify

    @Test func insertsAfterTheLastTopLevelSetting() throws {
        let original = """
            model = "gpt-5-codex"
            approval_policy = "on-request"

            [projects."/Users/example/code/payments"]
            trust_level = "trusted"

            """
        let expected = """
            model = "gpt-5-codex"
            approval_policy = "on-request"
            \(ourLine)

            [projects."/Users/example/code/payments"]
            trust_level = "trusted"

            """
        try roundTrip(original, expectInstalled: expected)
        #expect(try install(original).changes == ["Set notify to run /usr/local/bin/moonlet"])
    }

    @Test func insertsIntoAnEmptyFile() throws {
        try roundTrip("", expectInstalled: ourLine + "\n")
    }

    @Test func insertsAboveAFileThatStartsWithATable() throws {
        let original = "[profiles.fast]\nmodel = \"o4-mini\"\n"
        try roundTrip(original, expectInstalled: ourLine + "\n\n" + original)
    }

    @Test func insertsAboveLeadingComments() throws {
        let original = "# Codex settings\n\n[tui]\nnotifications = true\n"
        try roundTrip(original, expectInstalled: ourLine + "\n\n" + original)
    }

    @Test func handlesAFileWithoutATrailingNewline() throws {
        try roundTrip(#"model = "o3""#, expectInstalled: "model = \"o3\"\n" + ourLine)
    }

    @Test func notifyInsideATableIsNotTopLevel() throws {
        let original = """
            [profiles.work]
            notify = ["say", "done"]

            """
        try roundTrip(original, expectInstalled: ourLine + "\n\n" + original)
    }

    @Test func bracketsInsideValuesAreNotTableHeaders() throws {
        let original = """
            instructions = \"\"\"
            [not a table]
            \"\"\"
            matrix = [
              [1, 2],
              [3, 4],
            ]

            [tools]
            web_search = true

            """
        let expected = """
            instructions = \"\"\"
            [not a table]
            \"\"\"
            matrix = [
              [1, 2],
              [3, 4],
            ]
            \(ourLine)

            [tools]
            web_search = true

            """
        try roundTrip(original, expectInstalled: expected)
    }

    // MARK: Chaining

    @Test func chainsAnExistingNotifyWhosePathHasSpaces() throws {
        let client = "/Applications/Example Computer Use.app/Contents/SharedSupport/ExampleClient"
        let original = """
            model = "gpt-5-codex"
            notify = ["\(client)", "turn-ended"]

            [features]
            web_search = true

            """
        let expected = """
            model = "gpt-5-codex"
            # moonlet-original: notify = ["\(client)", "turn-ended"]
            notify = ["/usr/local/bin/moonlet", "hook", "codex", "--then", "\(client)", "turn-ended"]

            [features]
            web_search = true

            """
        try roundTrip(original, expectInstalled: expected)
        #expect(try install(original).changes == ["Chain the existing notify command (\(client)) through /usr/local/bin/moonlet"])
        #expect(try uninstall(expected).changes == ["Restore the original notify command (\(client))"])
        #expect(
            try CodexInstaller.notifyStatus(configText: expected)
                == .installed(executable: moonlet, chained: [client, "turn-ended"]))
    }

    @Test func chainsAMultiLineNotifyWithCommentsAndLiteralStrings() throws {
        let original = """
            notify = [
              'terminal-notifier', # the notifier
              "-title", "Codex",
            ]
            model = "o3"

            """
        let expected = """
            # moonlet-original: notify = [
            # moonlet-original:   'terminal-notifier', # the notifier
            # moonlet-original:   "-title", "Codex",
            # moonlet-original: ]
            notify = ["/usr/local/bin/moonlet", "hook", "codex", "--then", "terminal-notifier", "-title", "Codex"]
            model = "o3"

            """
        try roundTrip(original, expectInstalled: expected)
    }

    @Test func chainsStringsWithEscapes() throws {
        let original = #"notify = ["/tmp/we\"ird\\dir/notify", 'C:\literal', "caf\u00e9"]"# + "\n"
        let installed = try install(original)
        #expect(
            installed.newText.hasSuffix(
                #"notify = ["/usr/local/bin/moonlet", "hook", "codex", "--then", "/tmp/we\"ird\\dir/notify", "C:\\literal", "café"]"# + "\n"))
        #expect(try uninstall(installed.newText).newText == original)
    }

    @Test func replacesAnEmptyNotifyAndRestoresIt() throws {
        let original = "notify = []\n"
        try roundTrip(original, expectInstalled: "# moonlet-original: notify = []\n" + ourLine + "\n")
        #expect(try install(original).changes == ["Replace the empty notify setting"])
    }

    @Test func movingMoonletKeepsTheChain() throws {
        let original = #"notify = ["notify-send", "Codex"]"# + "\n"
        let first = try install(original)
        let moved = try install(first.newText, path: "/opt/homebrew/bin/moonlet")
        #expect(moved.changes == ["Point notify at /opt/homebrew/bin/moonlet"])
        #expect(moved.newText.contains(#"notify = ["/opt/homebrew/bin/moonlet", "hook", "codex", "--then", "notify-send", "Codex"]"#))
        #expect(try uninstall(moved.newText).newText == original)
    }

    @Test func uninstallWithoutTheSavedLinesRestoresTheChainedCommand() throws {
        let installed = #"notify = ["/usr/local/bin/moonlet", "hook", "codex", "--then", "notify-send", "Codex"]"# + "\n"
        #expect(try uninstall(installed).newText == #"notify = ["notify-send", "Codex"]"# + "\n")
    }

    @Test func staleSavedLinesAreDropped() throws {
        let installed = """
            # moonlet-original: notify = ["old-notifier"]
            notify = ["/usr/local/bin/moonlet", "hook", "codex", "--then", "new-notifier"]

            """
        #expect(try uninstall(installed).newText == "notify = [\"new-notifier\"]\n")
    }

    // MARK: Refusals and status

    @Test func uninstallLeavesOtherNotifySettingsAlone() throws {
        for text in [#"notify = ["say", "done"]"#, #"notify = "say done""#, "model = \"o3\"\n"] {
            let plan = try uninstall(text)
            #expect(!plan.hasChanges)
            #expect(plan.newText == text)
        }
    }

    @Test func refusesToInstallOverANotifyItCannotRead() {
        #expect {
            try install(#"notify = "say done""#)
        } throws: { error in
            (error as? InstallError)?.message.contains("isn't an array of strings") == true
        }
    }

    @Test(arguments: [#"model = "unterminated"#, "notify = [\"a\"", "= 1", "model"])
    func refusesFilesItCannotScan(text: String) {
        #expect(throws: InstallError.self) { try install(text) }
    }

    @Test func reportsTheNotifyStatus() throws {
        #expect(try CodexInstaller.notifyStatus(configText: "model = \"o3\"\n") == .notConfigured)
        #expect(try CodexInstaller.notifyStatus(configText: #"notify = ["say", "hi"]"#) == .foreign(["say", "hi"]))
        #expect(
            try CodexInstaller.notifyStatus(configText: ourLine) == .installed(executable: moonlet, chained: []))
    }

    @Test func applyWritesABackupFirstAndDryRunWritesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        let original = #"notify = ["notify-send", "Codex"]"# + "\n"
        try Data(original.utf8).write(to: url)

        let dryRun = try CodexInstaller.apply(configURL: url, moonletPath: moonlet, action: .install, dryRun: true)
        #expect(dryRun.plan.hasChanges && !dryRun.wroteFile)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)

        let result = try CodexInstaller.apply(configURL: url, moonletPath: moonlet, action: .install)
        #expect(try String(contentsOf: try #require(result.backupURL), encoding: .utf8) == original)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("--then"))

        try CodexInstaller.apply(configURL: url, moonletPath: moonlet, action: .uninstall)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }
}

@Suite("TOMLDocument")
struct TOMLDocumentTests {
    @Test(arguments: [
        (#"["a", 'b']"#, ["a", "b"]),
        (#"[ ]"#, []),
        ("[\n  \"a\", # comment\n  \"b\",\n]", ["a", "b"]),
        (#"["tab\tnew\nquote\"slash\\uni\u00e9\U0001F600"]"#, ["tab\tnew\nquote\"slash\\unié😀"]),
        ("[\"\"\"\nfirst \\\n   second\"\"\"]", ["first second"]),
        ("['''\nraw \\n text''']", ["raw \\n text"]),
        (#"["""a""""]"#, ["a\""]),
    ])
    func decodesStringArrays(value: String, expected: [String]) {
        #expect(TOMLDocument.stringArray(Substring(value)) == expected)
    }

    @Test(arguments: [#""a""#, "[1, 2]", #"["a" "b"]"#, #"["a"] x"#, #"["\q"]"#, "["])
    func rejectsOtherValues(value: String) {
        #expect(TOMLDocument.stringArray(Substring(value)) == nil)
    }

    @Test func rendersBasicStrings() {
        #expect(TOMLDocument.render(["a b", "q\"", "back\\", "tab\t", "\u{7F}"]) == #"["a b", "q\"", "back\\", "tab\t", "\u007F"]"#)
    }

    @Test func findsTopLevelKeysOnly() throws {
        let document = try TOMLDocument("a = 1 # note\n\"quoted.key\" = 'x'\nb.c = [\n 1,\n]\n[t]\nd = 2\n")
        #expect(document.topLevel.map(\.key) == ["a", "\"quoted.key\"", "b.c"])
        #expect(document.text[document.topLevel[0].valueRange] == "1")
        #expect(document.text[document.topLevel[2].valueRange] == "[\n 1,\n]")
        #expect(document.topLevel[1].isKey("quoted.key"))
    }
}
