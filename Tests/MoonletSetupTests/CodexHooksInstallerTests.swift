import Foundation
import Testing

@testable import MoonletSetup

@Suite("CodexHooksInstaller")
struct CodexHooksInstallerTests {
    private let moonlet = "/usr/local/bin/moonlet"
    private let command = "/usr/local/bin/moonlet hook codex"

    /// A hooks.json with another tool's hooks, formatted as `JSON.stringify(_, null, 2)`.
    private let existing = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "^Bash$",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/example/bin/check-command",
                    "timeout": 30,
                    "statusMessage": "Checking the command"
                  }
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/Users/example/bin/notify-me"
                  }
                ]
              }
            ]
          }
        }

        """

    private func install(_ text: String, path: String? = nil) throws -> InstallPlan {
        try CodexHooksInstaller.plan(hooksText: text, moonletPath: path ?? moonlet, action: .install)
    }

    private func uninstall(_ text: String) throws -> InstallPlan {
        try CodexHooksInstaller.plan(hooksText: text, moonletPath: moonlet, action: .uninstall)
    }

    private func entry(_ command: String, timeout: Int) -> OrderedJSON {
        .object([
            OrderedJSON.Member("type", .string("command")),
            OrderedJSON.Member("command", .string(command)),
            OrderedJSON.Member("timeout", .number(String(timeout))),
        ])
    }

    private func ourGroup(timeout: Int = 5) -> OrderedJSON {
        .object([OrderedJSON.Member("hooks", .array([entry(command, timeout: timeout)]))])
    }

    // MARK: Install

    @Test func installCreatesAFileThatSaysWhoAddedIt() throws {
        let plan = try install("")
        #expect(plan.changes == CodexHooksInstaller.allEvents.map { "Add the \($0) hook" })
        #expect(plan.newText.hasSuffix("}\n"))

        let root = try OrderedJSON(parsing: plan.newText)
        guard case .object(let members) = root, case .object(let hooks)? = root["hooks"] else {
            Issue.record("Expected an object with hooks")
            return
        }
        #expect(members.map(\.key) == ["description", "hooks"])
        #expect(root["description"] == .string(CodexHooksInstaller.fileDescription))
        #expect(hooks.map(\.key) == CodexHooksInstaller.allEvents)
        #expect(root["hooks"]?["Stop"] == .array([ourGroup()]))
        // Codex caps these two at three seconds.
        #expect(root["hooks"]?["Interrupt"] == .array([ourGroup(timeout: 2)]))
        #expect(root["hooks"]?["SessionEnd"] == .array([ourGroup(timeout: 2)]))
        #expect(!plan.newText.contains("async"))
        #expect(!plan.newText.contains("matcher"))
    }

    @Test func installIsIdempotent() throws {
        for original in ["", existing] {
            let installed = try install(original)
            let again = try install(installed.newText)
            #expect(!again.hasChanges)
            #expect(again.newText == installed.newText)
        }
    }

    @Test func uninstallDeletesTheFileMoonletCreated() throws {
        let installed = try install("\n")
        let removed = try uninstall(installed.newText)
        #expect(removed.removesFile)
        #expect(removed.newText == "")
        #expect(removed.changes.last == "Delete hooks.json, which only held Moonlet's hooks")
        #expect(removed.changes.dropLast() == CodexHooksInstaller.allEvents.map { "Remove the \($0) hook" })
    }

    @Test func existingHooksKeepTheirPlacesAndComeBackExactly() throws {
        let installed = try install(existing)
        #expect(!installed.newText.contains("description"))
        let root = try OrderedJSON(parsing: installed.newText)
        guard case .array(let preToolUse)? = root["hooks"]?["PreToolUse"], case .array(let stop)? = root["hooks"]?["Stop"]
        else {
            Issue.record("Expected PreToolUse and Stop arrays")
            return
        }
        // The other tool's groups stay first, so Codex's trust in them (keyed by position) holds.
        #expect(preToolUse.count == 2 && preToolUse[1] == ourGroup())
        #expect(stop.count == 2 && stop[1] == ourGroup())
        #expect(preToolUse[0]["matcher"] == .string("^Bash$"))

        let removed = try uninstall(installed.newText)
        #expect(!removed.removesFile)
        #expect(removed.newText == existing)
        #expect(try !uninstall(removed.newText).hasChanges)
    }

    @Test func otherKeysSurviveAndTheFileStaysWhenItHoldsMore() throws {
        let installed = try install("")
        // Someone later adds a hook of their own to the file Moonlet created.
        var root = try OrderedJSON(parsing: installed.newText)
        guard case .object(var members) = root, case .object(var hooks)? = root["hooks"] else { return }
        hooks.append(OrderedJSON.Member("PostCompact", .array([.object([OrderedJSON.Member("hooks", .array([entry("/bin/echo", timeout: 1)]))])])))
        members[members.lastIndex { $0.key == "hooks" }!].value = .object(hooks)
        root = .object(members)

        let removed = try uninstall(root.formatted() + "\n")
        #expect(!removed.removesFile)
        let left = try OrderedJSON(parsing: removed.newText)
        #expect(left["description"] == nil)
        guard case .object(let remaining)? = left["hooks"] else {
            Issue.record("Expected the user's hooks to remain")
            return
        }
        #expect(remaining.map(\.key) == ["PostCompact"])
    }

    @Test func movingMoonletUpdatesItsHooksInPlace() throws {
        let installed = try install(existing)
        let moved = try install(installed.newText, path: "/opt/homebrew/bin/moonlet")
        #expect(moved.changes == CodexHooksInstaller.allEvents.map { "Update the \($0) hook" })
        #expect(!moved.newText.contains("/usr/local/bin/moonlet"))
        #expect(try uninstall(moved.newText).newText == existing)
    }

    /// The hooks.json text with a group of `command` appended to each of `events`.
    private func appendingGroup(_ command: String, to events: [String], in text: String) throws -> String {
        guard case .object(var root) = try OrderedJSON(parsing: text),
            let hooksIndex = root.lastIndex(where: { $0.key == "hooks" }),
            case .object(var hooks) = root[hooksIndex].value
        else { throw InstallError("Expected an object with hooks") }
        for event in events {
            let group = OrderedJSON.object([OrderedJSON.Member("hooks", .array([entry(command, timeout: 10)]))])
            if let index = hooks.firstIndex(where: { $0.key == event }), case .array(let groups) = hooks[index].value {
                hooks[index].value = .array(groups + [group])
            } else {
                hooks.append(OrderedJSON.Member(event, .array([group])))
            }
        }
        root[hooksIndex].value = .object(hooks)
        return OrderedJSON.object(root).formatted() + "\n"
    }

    @Test func uninstallSaysWhichOfYourHooksCodexAsksAboutAgain() throws {
        // You add hooks of your own after Moonlet's: Codex knows them by their position.
        let installed = try install(existing)
        let yours = try appendingGroup("/Users/example/bin/log-tool", to: ["Stop", "PreToolUse", "PostCompact"], in: installed.newText)
        let root = try OrderedJSON(parsing: yours)
        guard case .array(let stop)? = root["hooks"]?["Stop"] else {
            Issue.record("Expected Stop groups")
            return
        }
        #expect(stop.count == 3 && stop[1] == ourGroup())

        // Taking Moonlet's group out moves them up, so Codex asks to trust them again.
        let removed = try uninstall(yours)
        #expect(removed.changes.last == "Codex will ask you to trust 2 of your own hooks again: PreToolUse, Stop")
        #expect(removed.changes.dropLast() == CodexHooksInstaller.allEvents.map { "Remove the \($0) hook" })
        #expect(!removed.removesFile)

        // Only one moved: the note says so in words.
        let one = try uninstall(try appendingGroup("/Users/example/bin/log-tool", to: ["Stop"], in: try install("").newText))
        #expect(one.changes.last == "Codex will ask you to trust one of your own hooks again: Stop")

        // Nothing after Moonlet's groups, nothing to trust again.
        #expect(!(try uninstall(installed.newText)).changes.contains { $0.contains("trust") })
    }

    @Test func reconcilingAGroupMoonletSharesSaysWhoMoves() throws {
        // Moonlet's entry ended up first in a group of yours: it moves to its own group,
        // and your entry after it takes its index.
        let text = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(command)"},{"type":"command","command":"/Users/example/bin/notify-me"}]}]}}
            """
        let plan = try install(text)
        #expect(plan.changes.contains("Codex will ask you to trust one of your own hooks again: Stop"))
        let root = try OrderedJSON(parsing: plan.newText)
        guard case .array(let stop)? = root["hooks"]?["Stop"] else {
            Issue.record("Expected Stop groups")
            return
        }
        #expect(stop.count == 2 && stop[1] == ourGroup())
        #expect(!(try install(plan.newText)).hasChanges)
    }

    @Test func pathsWithSpacesAreQuoted() throws {
        let plan = try install("", path: "/Users/example/My Tools/moonlet")
        #expect(plan.newText.contains(#""command": "'/Users/example/My Tools/moonlet' hook codex""#))
        #expect(try CodexHooksInstaller.installedHooks(hooksText: plan.newText)["Stop"] == "'/Users/example/My Tools/moonlet' hook codex")
    }

    @Test func installedHooksListsMoonletsCommandsOnly() throws {
        #expect(try CodexHooksInstaller.installedHooks(hooksText: existing).isEmpty)
        #expect(try CodexHooksInstaller.installedHooks(hooksText: "").isEmpty)
        let hooks = try CodexHooksInstaller.installedHooks(hooksText: try install(existing).newText)
        #expect(Set(hooks.keys) == Set(CodexHooksInstaller.allEvents))
        #expect(Set(hooks.values) == [command])
    }

    @Test func claudeCodeHooksAreNotMistakenForCodexOnes() throws {
        let text = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/moonlet hook claude-code"}]}]}}"#
        #expect(try CodexHooksInstaller.installedHooks(hooksText: text).isEmpty)
        #expect(try !uninstall(text).hasChanges)
    }

    // MARK: Refusals

    @Test(arguments: ["{", "[]", #"{"hooks": []}"#, #"{"hooks": {"Stop": {}}}"#])
    func refusesFilesItCannotEdit(text: String) {
        #expect(throws: InstallError.self) { try install(text) }
    }

    // MARK: Trust

    @Test func readsTrustFromCodexsConfig() throws {
        let hooksPath = "/Users/example/.codex/hooks.json"
        let hooksText = try install(existing).newText
        // Moonlet's groups sit second for PreToolUse and Stop, first everywhere else.
        let config = """
            model = "gpt-5-codex"

            [hooks.state."/Users/example/.codex/hooks.json:stop:1:0"]
            trusted_hash = "sha256:aaaa"

            [hooks.state."/Users/example/.codex/hooks.json:stop:0:0"]
            trusted_hash = "sha256:bbbb"

            [hooks.state."file:/Users/example/.codex/hooks.json:pre_tool_use:1:0"]
            trusted_hash = "sha256:cccc"

            [hooks.state."/Users/example/.codex/hooks.json:session_end:0:0"]
            trusted_hash = "sha256:dddd"
            enabled = false

            [hooks.state]
            "/Users/example/.codex/hooks.json:session_start:0:0" = { trusted_hash = "sha256:eeee" }
            "/Users/example/other/hooks.json:user_prompt_submit:0:0" = { trusted_hash = "sha256:ffff" }

            [projects."/Users/example/code/payments"]
            trust_level = "trusted"

            """
        let trust = CodexHooksInstaller.trust(hooksText: hooksText, hooksPath: hooksPath, configText: config)
        #expect(trust["Stop"] == .trusted)
        #expect(trust["PreToolUse"] == .trusted)
        #expect(trust["SessionStart"] == .trusted)
        #expect(trust["SessionEnd"] == .disabled)
        #expect(trust["UserPromptSubmit"] == .untrusted)
        #expect(trust["PermissionRequest"] == .untrusted)
        #expect(trust.count == CodexHooksInstaller.allEvents.count)
    }

    @Test func nothingIsTrustedWithoutRecords() throws {
        let trust = CodexHooksInstaller.trust(
            hooksText: try install("").newText, hooksPath: "/Users/example/.codex/hooks.json", configText: "model = \"o3\"\n")
        #expect(Set(trust.values) == [.untrusted])
        #expect(CodexHooksInstaller.trust(hooksText: "", hooksPath: "/x/hooks.json", configText: "").isEmpty)
    }

    // MARK: Health

    private let changed = Date(timeIntervalSince1970: 1_790_000_000)

    private func health(_ trust: CodexHooksInstaller.Trust, except: [String: CodexHooksInstaller.Trust] = [:], lastReport: TimeInterval?)
        -> CodexHooksInstaller.Health
    {
        var records = Dictionary(uniqueKeysWithValues: CodexHooksInstaller.allEvents.map { ($0, trust) })
        records.merge(except) { _, new in new }
        return CodexHooksInstaller.health(
            trust: records, hooksModified: changed, lastReport: lastReport.map { changed.addingTimeInterval($0) })
    }

    @Test func trustedHooksThatReportedSinceTheFileChangedAreHealthy() {
        #expect(health(.trusted, lastReport: 60) == .reporting)
    }

    @Test func trustedHooksThatChangedSinceTheyLastReportedMayBeAskedAboutAgain() {
        // Like Codex's "Modified": the records are there, but for the hooks as they were.
        #expect(health(.trusted, lastReport: -60) == .mayAskAgain)
        #expect(health(.trusted, lastReport: nil) == .mayAskAgain)
        #expect(CodexHooksInstaller.health(trust: [:], hooksModified: nil, lastReport: nil) == .mayAskAgain)
        #expect(CodexHooksInstaller.health(trust: ["Stop": .trusted], hooksModified: nil, lastReport: changed) == .reporting)
    }

    @Test func untrustedHooksWithOldActivityStillNeedTrust() {
        // They reported once, but not since the file changed.
        #expect(health(.untrusted, lastReport: -60) == .untrusted(CodexHooksInstaller.allEvents))
        // Some trusted, some not: the others don't run, whatever reported.
        #expect(health(.trusted, except: ["Stop": .untrusted, "PreToolUse": .untrusted], lastReport: 60) == .untrusted(["PreToolUse", "Stop"]))
    }

    @Test func untrustedHooksThatReportSinceTheFileChangedRunAnyway() {
        // Only hooks Codex runs report, so their records must sit where this check can't read them.
        #expect(health(.untrusted, lastReport: 60) == .reporting)
    }

    @Test func aFreshInstallNeedsTrust() throws {
        let trust = CodexHooksInstaller.trust(
            hooksText: try install("").newText, hooksPath: "/Users/example/.codex/hooks.json", configText: "")
        #expect(CodexHooksInstaller.health(trust: trust, hooksModified: changed, lastReport: nil) == .untrusted(CodexHooksInstaller.allEvents))
        // A reinstall after an earlier session reported.
        #expect(
            CodexHooksInstaller.health(trust: trust, hooksModified: changed, lastReport: changed.addingTimeInterval(-3600))
                == .untrusted(CodexHooksInstaller.allEvents))
    }

    @Test func turnedOffHooksComeFirst() {
        #expect(health(.trusted, except: ["SessionEnd": .disabled, "Stop": .disabled], lastReport: 60) == .disabled(["Stop", "SessionEnd"]))
        #expect(health(.untrusted, except: ["Stop": .disabled], lastReport: nil) == .disabled(["Stop"]))
    }

    @Test(arguments: [
        ("PreToolUse", "pre_tool_use"), ("PermissionRequest", "permission_request"), ("Stop", "stop"),
        ("UserPromptSubmit", "user_prompt_submit"), ("SessionEnd", "session_end"),
    ])
    func eventLabelsMatchCodexsKeys(event: String, label: String) {
        #expect(CodexHooksInstaller.snakeCase(event) == label)
    }

    // MARK: Files

    @Test func applyCreatesBacksUpAndDeletes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "hooks.json")

        let dryRun = try CodexHooksInstaller.apply(hooksURL: url, moonletPath: moonlet, action: .install, dryRun: true)
        #expect(dryRun.plan.hasChanges && !dryRun.wroteFile)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let created = try CodexHooksInstaller.apply(hooksURL: url, moonletPath: moonlet, action: .install)
        #expect(created.wroteFile && created.backupURL == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == created.plan.newText)

        let removed = try CodexHooksInstaller.apply(hooksURL: url, moonletPath: moonlet, action: .uninstall)
        #expect(removed.wroteFile)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: try #require(removed.backupURL), encoding: .utf8) == created.plan.newText)
    }
}
