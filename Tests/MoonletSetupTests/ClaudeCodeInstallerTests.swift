import Foundation
import Testing

@testable import MoonletSetup

@Suite("ClaudeCodeInstaller")
struct ClaudeCodeInstallerTests {
    private let moonlet = "/usr/local/bin/moonlet"

    /// Settings as Claude Code writes them, with another tool's Stop hook already present.
    private let settings = """
        {
          "env": {
            "EXAMPLE_FLAG": "1"
          },
          "permissions": {
            "allow": [
              "Bash(swift build:*)"
            ]
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
          },
          "theme": "dark"
        }

        """

    private let foreignStopGroup = OrderedJSON.object([
        OrderedJSON.Member(
            "hooks",
            .array([
                .object([
                    OrderedJSON.Member("type", .string("command")),
                    OrderedJSON.Member("command", .string("~/.claude/skills/gstack/bin/timeline-stop-hook")),
                    OrderedJSON.Member("timeout", .number("10")),
                ])
            ])),
        OrderedJSON.Member("_gstack_source", .string("timeline")),
    ])

    private func install(_ text: String, path: String? = nil, events: [String] = ClaudeCodeInstaller.allEvents) throws
        -> InstallPlan
    {
        try ClaudeCodeInstaller.plan(settingsText: text, moonletPath: path ?? moonlet, action: .install, events: events)
    }

    private func uninstall(_ text: String) throws -> InstallPlan {
        try ClaudeCodeInstaller.plan(settingsText: text, moonletPath: moonlet, action: .uninstall)
    }

    private func hooks(_ text: String) throws -> OrderedJSON {
        try #require(try OrderedJSON(parsing: text)["hooks"])
    }

    // MARK: Install

    @Test func installAddsOneGroupPerEvent() throws {
        let plan = try install(settings)
        #expect(plan.changes == ClaudeCodeInstaller.allEvents.map { "Add the \($0) hook" })

        let hooks = try hooks(plan.newText)
        let command = OrderedJSON.object([
            OrderedJSON.Member("type", .string("command")),
            OrderedJSON.Member("command", .string("/usr/local/bin/moonlet hook claude-code")),
            OrderedJSON.Member("timeout", .number("5")),
        ])
        #expect(
            hooks["PreToolUse"]
                == .array([
                    .object([OrderedJSON.Member("matcher", .string("*")), OrderedJSON.Member("hooks", .array([command]))])
                ]))
        #expect(hooks["SessionStart"] == .array([.object([OrderedJSON.Member("hooks", .array([command]))])]))
        #expect(hooks["PostToolUse"]?.formatted().contains(#""matcher": "*""#) == true)
        #expect(hooks["Notification"]?.formatted().contains("matcher") == false)
    }

    @Test func installLeavesEverythingElseAlone() throws {
        let plan = try install(settings)
        let root = try OrderedJSON(parsing: plan.newText)
        guard case .object(let members) = root else {
            Issue.record("Expected an object")
            return
        }
        #expect(members.map(\.key) == ["env", "permissions", "hooks", "theme"])
        #expect(root["env"] == (try OrderedJSON(parsing: settings))["env"])

        guard case .array(let stopGroups)? = try hooks(plan.newText)["Stop"] else {
            Issue.record("Expected Stop groups")
            return
        }
        #expect(stopGroups.count == 2)
        #expect(stopGroups.first == foreignStopGroup)
        #expect(plan.newText.hasSuffix("}\n"))
    }

    @Test func installIsIdempotent() throws {
        let first = try install(settings)
        let second = try install(first.newText)
        #expect(!second.hasChanges)
        #expect(second.newText == first.newText)
    }

    @Test func uninstallRestoresTheOriginalByteForByte() throws {
        let installed = try install(settings)
        let removed = try uninstall(installed.newText)
        #expect(removed.changes == ClaudeCodeInstaller.allEvents.map { "Remove the \($0) hook" })
        #expect(removed.newText == settings)
    }

    @Test func uninstallRemovesTheHooksKeyMoonletCreated() throws {
        let original = "{\n  \"theme\": \"light\"\n}\n"
        let installed = try install(original)
        #expect(try uninstall(installed.newText).newText == original)
    }

    @Test func uninstallWithoutMoonletChangesNothing() throws {
        let plan = try uninstall(settings)
        #expect(!plan.hasChanges)
        #expect(plan.newText == settings)
    }

    @Test(arguments: ["", "   \n"])
    func installIntoAMissingOrBlankFile(text: String) throws {
        let plan = try install(text)
        #expect(plan.hasChanges)
        #expect(plan.newText.hasPrefix("{\n  \"hooks\": {\n    \"SessionStart\": ["))
        #expect(plan.newText.hasSuffix("}\n"))
        #expect(try uninstall(plan.newText).newText == "{}\n")
    }

    @Test func keepsAMissingTrailingNewlineMissing() throws {
        let plan = try install(#"{"theme": "dark"}"#)
        #expect(plan.newText.hasSuffix("}"))
    }

    @Test func movingMoonletUpdatesEveryCommandInPlace() throws {
        let first = try install(settings)
        let moved = try install(first.newText, path: "/opt/homebrew/bin/moonlet")
        #expect(moved.changes == ClaudeCodeInstaller.allEvents.map { "Update the \($0) hook" })
        #expect(!moved.newText.contains("/usr/local/bin/moonlet"))
        #expect(moved.newText.components(separatedBy: "/opt/homebrew/bin/moonlet hook claude-code").count - 1 == 9)
    }

    @Test func pathsWithSpacesAreQuotedForTheShell() throws {
        let plan = try install("{}", path: "/Users/Jane Doe/bin/moon'let")
        #expect(plan.newText.contains(#""command": "'/Users/Jane Doe/bin/moon'\\''let' hook claude-code""#))
        #expect(try install(plan.newText, path: "/Users/Jane Doe/bin/moon'let").hasChanges == false)
    }

    @Test func eventsNoLongerWantedAreRemoved() throws {
        let all = try install(settings)
        let fewer = try install(all.newText, events: ClaudeCodeInstaller.allEvents.filter { $0 != "StopFailure" })
        #expect(fewer.changes == ["Remove the StopFailure hook"])
        #expect(try hooks(fewer.newText)["StopFailure"] == nil)
    }

    @Test func duplicatesAndMixedGroupsAreCleanedUp() throws {
        let messy = """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {"type": "command", "command": "/old/moonlet hook claude-code"},
                      {"type": "command", "command": "say done"}
                    ]
                  },
                  {"hooks": [{"type": "command", "command": "/usr/local/bin/moonlet hook claude-code", "timeout": 5}]},
                  {"hooks": [{"type": "command", "command": "/usr/local/bin/moonlet hook claude-code", "timeout": 5}]}
                ]
              }
            }
            """
        let plan = try install(messy, events: ["Stop"])
        #expect(plan.changes == ["Update the Stop hook"])
        guard case .array(let groups)? = try hooks(plan.newText)["Stop"] else {
            Issue.record("Expected Stop groups")
            return
        }
        #expect(groups.count == 2)
        #expect(groups[0].formatted().contains("say done"))
        #expect(!groups[0].formatted().contains("moonlet"))
        #expect(groups[1] == ClaudeCodeInstaller.group(for: "Stop", command: "/usr/local/bin/moonlet hook claude-code"))
        #expect(try !install(plan.newText, events: ["Stop"]).hasChanges)
    }

    @Test(arguments: [
        ("{", "isn't valid JSON"),
        ("[1, 2]", "doesn't hold a JSON object"),
        (#"{"hooks": []}"#, "\"hooks\" in settings.json isn't an object"),
        (#"{"hooks": {"Stop": {"oops": true}}}"#, "hooks.Stop in settings.json isn't an array"),
    ])
    func refusesSettingsItCannotEditSafely(text: String, reason: String) {
        #expect {
            try install(text)
        } throws: { error in
            (error as? InstallError)?.message.contains(reason) == true
        }
    }

    @Test func malformedEntriesForOtherEventsAreLeftAlone() throws {
        let text = #"{"hooks": {"Custom": "not an array"}}"#
        let plan = try install(text, events: ["Stop"])
        #expect(try hooks(plan.newText)["Custom"] == .string("not an array"))
    }

    // MARK: Versions and inspection

    @Test(arguments: [
        ("2.1.290 (Claude Code)", ClaudeCodeInstaller.allEvents),
        ("2.1.78", ClaudeCodeInstaller.allEvents),
        ("2.1.77 (Claude Code)", ClaudeCodeInstaller.allEvents.filter { $0 != "StopFailure" }),
        ("2.0.45", ClaudeCodeInstaller.allEvents.filter { $0 != "StopFailure" }),
        ("2.0.44", ClaudeCodeInstaller.allEvents.filter { $0 != "StopFailure" && $0 != "PermissionRequest" }),
        ("1.0.128 (Claude Code)", ClaudeCodeInstaller.allEvents.filter { $0 != "StopFailure" && $0 != "PermissionRequest" }),
        ("not a version", ClaudeCodeInstaller.allEvents),
    ])
    func eventsDependOnTheClaudeCodeVersion(version: String, expected: [String]) {
        #expect(ClaudeCodeInstaller.events(forClaudeVersion: version) == expected)
    }

    @Test func unknownVersionGetsEveryEvent() {
        #expect(ClaudeCodeInstaller.events(forClaudeVersion: nil) == ClaudeCodeInstaller.allEvents)
    }

    @Test func installedHooksListsMoonletsCommands() throws {
        #expect(try ClaudeCodeInstaller.installedHooks(settingsText: settings).isEmpty)
        let plan = try install(settings, events: ["Stop", "PreToolUse"])
        #expect(
            try ClaudeCodeInstaller.installedHooks(settingsText: plan.newText)
                == ["Stop": "/usr/local/bin/moonlet hook claude-code", "PreToolUse": "/usr/local/bin/moonlet hook claude-code"])
    }

    // MARK: Files

    @Test func applyWritesABackupFirstAndDryRunWritesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "settings.json")
        try Data(settings.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let dryRun = try ClaudeCodeInstaller.apply(settingsURL: url, moonletPath: moonlet, action: .install, dryRun: true, now: now)
        #expect(dryRun.plan.hasChanges)
        #expect(!dryRun.wroteFile)
        #expect(try String(contentsOf: url, encoding: .utf8) == settings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])

        let result = try ClaudeCodeInstaller.apply(settingsURL: url, moonletPath: moonlet, action: .install, now: now)
        #expect(result.wroteFile)
        let backup = try #require(result.backupURL)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.moonlet-backup-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == settings)
        #expect(try String(contentsOf: url, encoding: .utf8) == result.plan.newText)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640)

        let again = try ClaudeCodeInstaller.apply(settingsURL: url, moonletPath: moonlet, action: .install, now: now)
        #expect(!again.wroteFile)
        #expect(again.backupURL == nil)

        let removed = try ClaudeCodeInstaller.apply(settingsURL: url, moonletPath: moonlet, action: .uninstall, now: now)
        #expect(removed.backupURL?.lastPathComponent.hasSuffix("-2") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == settings)
    }

    @Test func applyCreatesAMissingFileWithoutABackup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "new/settings.json")
        let result = try ClaudeCodeInstaller.apply(settingsURL: url, moonletPath: moonlet, action: .install)
        #expect(result.wroteFile)
        #expect(result.backupURL == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func applyWritesThroughASymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "dotfiles-settings.json")
        let link = directory.appending(path: "settings.json")
        try Data(settings.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeCodeInstaller.apply(settingsURL: link, moonletPath: moonlet, action: .install)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("hook claude-code"))
    }
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "moonlet-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
