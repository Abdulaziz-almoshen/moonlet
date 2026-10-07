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

    // MARK: Moonlet inside another notifier

    /// Another app's notifier that took over `notify` and keeps the previous command, JSON
    /// encoded, in its own argument, the way some Codex companions do.
    @Test func recognizesMoonletInsideAnotherNotifiersPreviousCommand() throws {
        let client = "/Applications/Example Companion.app/Contents/MacOS/ExampleClient"
        let previous = #"[\"\\/usr\\/local\\/bin\\/moonlet\",\"hook\",\"codex\",\"--then\",\"\\/usr\\/bin\\/say\",\"done\"]"#
        let config = """
            model = "gpt-5-codex"
            notify = ["\(client)", "turn-ended", "--previous-notify", "\(previous)"]

            """
        #expect(
            try CodexInstaller.notifyStatus(configText: config)
                == .nested(notifier: [client, "turn-ended", "--previous-notify", #"["\/usr\/local\/bin\/moonlet","hook","codex","--then","\/usr\/bin\/say","done"]"#], executable: moonlet))
        // Moonlet never edits another program's notify setting.
        #expect(try !uninstall(config).hasChanges)
    }

    @Test(arguments: [
        [#"/opt/wrapper"#, "--then", "/usr/local/bin/moonlet", "hook", "codex"],
        [#"/opt/wrapper"#, "--exec", "/usr/local/bin/moonlet hook codex"],
        [#"/opt/wrapper"#, "--exec", "'/usr/local/bin/moonlet' hook codex --then say"],
        [#"/opt/wrapper"#, #"["/opt/inner", "--previous", "[\"/usr/local/bin/moonlet\", \"hook\", \"codex\"]"]"#],
    ])
    func recognizesMoonletNestedInOtherShapes(argv: [String]) throws {
        let config = "notify = \(TOMLDocument.render(argv))\n"
        guard case .nested(_, let executable) = try CodexInstaller.notifyStatus(configText: config) else {
            Issue.record("Expected Moonlet to be recognized in \(argv)")
            return
        }
        #expect(executable == moonlet)
    }

    @Test(arguments: [
        ["/opt/wrapper", "--previous-notify", #"["/usr/bin/say","hook","codex"]"#],
        ["/opt/wrapper", "moonlet-notes", "hook"],
        ["/opt/wrapper", "not json [ ]"],
    ])
    func otherNotifiersStayForeign(argv: [String]) throws {
        let config = "notify = \(TOMLDocument.render(argv))\n"
        #expect(try CodexInstaller.notifyStatus(configText: config) == .foreign(argv))
    }

    // MARK: Hooks or notify

    @Test(arguments: [
        ("codex-cli 0.154.0", CodexInstaller.Mechanism.hooks),
        ("codex-cli 0.153.0", .hooks),
        ("codex-cli 1.0.0", .hooks),
        ("codex-cli 0.152.9", .notify),
        ("codex-cli 0.98.0", .notify),
    ] as [(String, CodexInstaller.Mechanism)])
    func theVersionPicksTheMechanism(version: String, expected: CodexInstaller.Mechanism) {
        #expect(CodexInstaller.mechanism(forCodexVersion: version) == expected)
    }

    @Test(arguments: [nil, "", "codex-cli", "WARNING: something"] as [String?])
    func anUnreadableVersionIsUnknown(version: String?) {
        #expect(CodexInstaller.mechanism(forCodexVersion: version) == nil)
    }

    private func plans(
        config: String, hooks: String = "", action: InstallAction = .install, version: String? = "codex-cli 0.154.0"
    ) throws -> CodexInstaller.Plans {
        try CodexInstaller.plans(configText: config, hooksText: hooks, moonletPath: moonlet, action: action, codexVersion: version)
    }

    @Test func withHooksMoonletLeavesNotifyAlone() throws {
        let foreign = #"notify = ["notify-send", "Codex"]"# + "\n"
        let nested = #"notify = ["/opt/wrapper", "--previous-notify", "[\"/old/moonlet\",\"hook\",\"codex\"]"]"# + "\n"
        for config in ["", foreign, nested, ourLine + "\n", #"notify = "not an array""#] {
            let plans = try plans(config: config)
            #expect(plans.mechanism == .hooks)
            #expect(!plans.config.hasChanges)
            #expect(plans.config.newText == config)
            #expect(plans.hooks.hasChanges)
            #expect(plans.hooks.newText.contains("hook codex"))
        }
    }

    @Test func withHooksAnEarlierNotifyChainFollowsMoonlet() throws {
        let chained = try install(#"notify = ["notify-send", "Codex"]"# + "\n").newText
        let plans = try CodexInstaller.plans(
            configText: chained, hooksText: "", moonletPath: "/opt/homebrew/bin/moonlet", action: .install,
            codexVersion: "codex-cli 0.154.0")
        #expect(plans.config.changes == ["Point notify at /opt/homebrew/bin/moonlet"])
        #expect(plans.hooks.newText.contains("/opt/homebrew/bin/moonlet hook codex"))
    }

    @Test func anOlderCodexGetsNotifyAndLosesMoonletsHooks() throws {
        let hooks = try CodexHooksInstaller.plan(hooksText: "", moonletPath: moonlet, action: .install).newText
        let plans = try plans(config: "model = \"o3\"\n", hooks: hooks, version: "codex-cli 0.140.0")
        #expect(plans.mechanism == .notify)
        #expect(plans.config.newText == "model = \"o3\"\n" + ourLine + "\n")
        #expect(plans.hooks.removesFile)
    }

    @Test func anUnknownVersionKeepsWhatIsInstalled() throws {
        let fresh = try plans(config: "", version: nil)
        #expect(fresh.mechanism == .notify)
        #expect(fresh.config.newText == ourLine + "\n")
        #expect(!fresh.hooks.hasChanges)

        let hooks = try CodexHooksInstaller.plan(hooksText: "", moonletPath: moonlet, action: .install).newText
        let hooked = try plans(config: "", hooks: hooks, version: nil)
        #expect(hooked.mechanism == .hooks)
        #expect(!hooked.config.hasChanges && !hooked.hooks.hasChanges)
    }

    // MARK: Another app's notifier that runs Moonlet

    private let companion = "/Applications/Example Companion.app/Contents/MacOS/ExampleClient"

    private var nestedConfig: String {
        "notify = \(TOMLDocument.render([companion, "turn-ended", "--previous-notify", #"["/usr/local/bin/moonlet","hook","codex"]"#]))\n"
    }

    @Test func anOlderCodexKeepsANotifierThatAlreadyRunsMoonlet() throws {
        let plans = try CodexInstaller.plans(
            configText: nestedConfig, hooksText: "", moonletPath: moonlet, action: .install, codexVersion: "codex-cli 0.140.0",
            isExecutable: { $0 == moonlet })
        #expect(plans.mechanism == .notify)
        #expect(!plans.config.hasChanges && plans.config.newText == nestedConfig)
        #expect(plans.notes == ["Moonlet already runs through Example Companion's notify command, so notify stays as it is."])
    }

    @Test func anOlderCodexChainsANotifierWhoseMoonletIsGone() throws {
        let plans = try CodexInstaller.plans(
            configText: nestedConfig, hooksText: "", moonletPath: "/opt/homebrew/bin/moonlet", action: .install,
            codexVersion: "codex-cli 0.140.0", isExecutable: { _ in false })
        #expect(plans.config.changes == ["Chain the existing notify command (\(companion)) through /opt/homebrew/bin/moonlet"])
        #expect(plans.notes.isEmpty)
    }

    @Test func uninstallSaysMoonletStillRunsInsideAnotherNotifier() throws {
        let removed = try plans(config: nestedConfig, action: .uninstall)
        #expect(!removed.config.hasChanges)
        #expect(
            removed.notes == [
                "Moonlet still runs inside Example Companion's notify command, which Moonlet never edits. "
                    + "To stop it, remove /usr/local/bin/moonlet hook codex from that command in config.toml."
            ])
        // Moonlet's own chain comes out without a note.
        let chained = try install(#"notify = ["notify-send", "Codex"]"# + "\n").newText
        #expect(try plans(config: chained, action: .uninstall).notes.isEmpty)
    }

    @Test(arguments: [
        ("/Applications/Example Companion.app/Contents/MacOS/ExampleClient", "Example Companion"),
        ("/opt/wrapper", "wrapper"),
        ("notify-send", "notify-send"),
        ("/Users/example/.app/bin/notify", "notify"),
    ])
    func programsAreNamedAfterTheirApp(path: String, name: String) {
        #expect(CodexInstaller.programName(path) == name)
    }

    // MARK: Hooks on the terminal

    @Test(arguments: [
        ("codex-cli 0.153.0", true), ("codex-cli 0.154.2", true), ("codex-cli 0.155.0", false), ("codex-cli 1.0.0", false),
        ("codex-cli 0.152.0", false), (nil, false),
    ] as [(String?, Bool)])
    func codex153And154RunHooksOnTheTerminal(version: String?, attached: Bool) {
        #expect(CodexInstaller.runsHooksOnTheTerminal(codexVersion: version) == attached)
    }

    @Test func installThenUninstallRestoresBothFiles() throws {
        let config = """
            model = "gpt-5-codex"
            notify = ["/Applications/Example.app/Contents/MacOS/client", "turn-ended"]

            [features]
            web_search = true

            """
        let installed = try plans(config: config)
        let removed = try plans(config: installed.config.newText, hooks: installed.hooks.newText, action: .uninstall)
        #expect(removed.config.newText == config)
        #expect(!removed.config.hasChanges)
        #expect(removed.hooks.removesFile)
    }

    @Test func uninstallAlsoRemovesAnEarlierNotifyChain() throws {
        let original = #"notify = ["notify-send", "Codex"]"# + "\n"
        let chained = try install(original).newText
        let installed = try plans(config: chained)
        #expect(installed.config.newText == chained)  // Kept as a fallback.
        let removed = try plans(config: chained, hooks: installed.hooks.newText, action: .uninstall)
        #expect(removed.config.newText == original)
        #expect(removed.hooks.removesFile)
    }

    @Test func applyWritesHooksAndLeavesTheConfigByteForByte() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "config.toml")
        let hooks = directory.appending(path: "hooks.json")
        let original = "# Codex\nmodel = \"o3\"   # fast\nnotify = [\"say\", \"done\"]\n"
        try Data(original.utf8).write(to: config)

        let dryRun = try CodexInstaller.apply(
            configURL: config, hooksURL: hooks, moonletPath: moonlet, action: .install, codexVersion: "codex-cli 0.154.0",
            dryRun: true)
        #expect(dryRun.mechanism == .hooks && dryRun.hooks.plan.hasChanges && !dryRun.hooks.wroteFile)
        #expect(!FileManager.default.fileExists(atPath: hooks.path))

        let installed = try CodexInstaller.apply(
            configURL: config, hooksURL: hooks, moonletPath: moonlet, action: .install, codexVersion: "codex-cli 0.154.0")
        #expect(installed.hooks.wroteFile && !installed.config.wroteFile)
        #expect(try CodexHooksInstaller.installedHooks(hooksText: String(contentsOf: hooks, encoding: .utf8)).count == 8)
        #expect(try String(contentsOf: config, encoding: .utf8) == original)

        let removed = try CodexInstaller.apply(
            configURL: config, hooksURL: hooks, moonletPath: moonlet, action: .uninstall, codexVersion: nil)
        #expect(removed.hooks.wroteFile)
        #expect(!FileManager.default.fileExists(atPath: hooks.path))
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(leftovers.count == 2 && leftovers[0] == "config.toml" && leftovers[1].hasPrefix("hooks.json.moonlet-backup-"))
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

    @Test func entriesCoverEveryTable() {
        let text = """
            model = "o3" # comment
            [hooks.state."/x/hooks.json:stop:0:0"]
            trusted_hash = "sha256:1"
            [ 'quoted.table' . inner ]
            a.b = { c = 1 }
            list = [
              "x", # still the value
            ]
            [[profiles.list]]
            name = "first"
            """
        let entries = TOMLDocument.entries(in: text)
        #expect(entries.map(\.path) == [
            ["model"], ["hooks", "state", "/x/hooks.json:stop:0:0", "trusted_hash"], ["quoted.table", "inner", "a", "b"],
            ["quoted.table", "inner", "list"], ["profiles", "list", "name"],
        ])
        #expect(entries.map { String($0.value) } == [#""o3""#, #""sha256:1""#, "{ c = 1 }", "[\n  \"x\", # still the value\n]", #""first""#])
    }

    @Test func entriesStopAtTheFirstUnreadableLine() {
        let entries = TOMLDocument.entries(in: "a = 1\n[broken\nb = 2\n")
        #expect(entries.map(\.path) == [["a"]])
    }

    @Test(arguments: [
        ("a", ["a"]), ("a.b", ["a", "b"]), (#" "x.y" . 'z' "#, ["x.y", "z"]), ("bare-key_1", ["bare-key_1"]),
    ])
    func parsesDottedKeys(key: String, expected: [String]) {
        #expect(TOMLDocument.keyPath(Substring(key)) == expected)
    }

    @Test(arguments: ["", "a.", ".a", "a b", "a..b", "ö"])
    func rejectsMalformedKeys(key: String) {
        #expect(TOMLDocument.keyPath(Substring(key)) == nil)
    }

    @Test func findsTopLevelKeysOnly() throws {
        let document = try TOMLDocument("a = 1 # note\n\"quoted.key\" = 'x'\nb.c = [\n 1,\n]\n[t]\nd = 2\n")
        #expect(document.topLevel.map(\.key) == ["a", "\"quoted.key\"", "b.c"])
        #expect(document.text[document.topLevel[0].valueRange] == "1")
        #expect(document.text[document.topLevel[2].valueRange] == "[\n 1,\n]")
        #expect(document.topLevel[1].isKey("quoted.key"))
    }
}
