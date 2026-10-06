import Foundation

/// Points Codex's top-level `notify` setting in `config.toml` at Moonlet, and back.
///
/// Codex runs one notify command, so an existing one is chained rather than replaced:
/// `notify = ["<moonlet>", "hook", "codex", "--then", <original argv…>]`. The original
/// lines are kept verbatim in `# moonlet-original:` comments above the setting, so
/// uninstalling restores them byte for byte.
public enum CodexInstaller {
    /// Where an installation stands.
    public enum NotifyStatus: Sendable, Equatable {
        /// No top-level `notify` setting.
        case notConfigured
        /// `notify` runs a command other than Moonlet.
        case foreign([String])
        /// `notify` runs Moonlet, then the `chained` command (empty when there's none).
        case installed(executable: String, chained: [String])
    }

    /// Prefix of the comment lines that hold a chained setting's original text.
    static let originalMarker = "# moonlet-original: "

    /// Plans pointing `notify` at Moonlet, or restoring what was there before.
    /// Idempotent: planning against the result changes nothing.
    public static func plan(configText: String, moonletPath: String, action: InstallAction) throws -> InstallPlan {
        let document = try scan(configText)
        let setting = document.topLevel.first { $0.isKey("notify") }
        switch action {
        case .install:
            let argv = try setting.map { try arguments(of: $0, in: configText) }
            return install(into: configText, setting: setting, argv: argv, moonletPath: moonletPath)
        case .uninstall:
            // A setting that isn't a string array can't be Moonlet's, so there's nothing to undo.
            let argv = setting.flatMap { TOMLDocument.stringArray(configText[$0.valueRange]) }
            return uninstall(from: configText, setting: setting, argv: argv, moonletPath: moonletPath)
        }
    }

    /// Plans the edit to the config file at `url` and, unless `dryRun` is set, writes it
    /// after saving a timestamped backup beside the file.
    @discardableResult
    public static func apply(
        configURL url: URL,
        moonletPath: String,
        action: InstallAction,
        dryRun: Bool = false,
        now: Date = .now
    ) throws -> InstallResult {
        try ConfigFile.apply(to: url, dryRun: dryRun, now: now) { text in
            try plan(configText: text, moonletPath: moonletPath, action: action)
        }
    }

    /// The state of the `notify` setting in a config file's text.
    public static func notifyStatus(configText: String) throws -> NotifyStatus {
        let document = try scan(configText)
        guard let setting = document.topLevel.first(where: { $0.isKey("notify") }) else { return .notConfigured }
        let argv = try arguments(of: setting, in: configText)
        if let ours = MoonletNotify(argv: argv, moonletPath: nil) {
            return .installed(executable: ours.executable, chained: ours.chained)
        }
        return .foreign(argv)
    }

    // MARK: Install

    private static func install(
        into text: String, setting: TOMLDocument.KeyValue?, argv: [String]?, moonletPath: String
    ) -> InstallPlan {
        guard let setting, let argv else {
            return InstallPlan(
                originalText: text, newText: inserting(notifyLine([moonletPath, "hook", "codex"]), into: text),
                changes: ["Set notify to run \(moonletPath)"])
        }
        if let ours = MoonletNotify(argv: argv, moonletPath: moonletPath) {
            guard ours.executable != moonletPath else { return .unchanged(text) }
            var newText = text
            newText.replaceSubrange(setting.valueRange, with: TOMLDocument.render(ours.argv(executable: moonletPath)))
            return InstallPlan(originalText: text, newText: newText, changes: ["Point notify at \(moonletPath)"])
        }

        // Chain the existing command, keeping its original lines in comments.
        let original = text[setting.range]
        let endsWithNewline = original.hasSuffix("\n")
        let comments = (endsWithNewline ? original.dropLast() : original)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { originalMarker + $0 }
        let chained = MoonletNotify(executable: moonletPath, chained: argv).argv(executable: moonletPath)
        let replacement = (comments + [notifyLine(chained)]).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        var newText = text
        newText.replaceSubrange(setting.range, with: replacement)
        let description = argv.first.map { "Chain the existing notify command (\($0)) through \(moonletPath)" }
        return InstallPlan(
            originalText: text, newText: newText, changes: [description ?? "Replace the empty notify setting"])
    }

    /// Adds a top-level line after the last top-level setting, or at the top of the file
    /// (followed by a blank line) when there's none, so it always precedes the first table.
    private static func inserting(_ line: String, into text: String) -> String {
        let document = try? TOMLDocument(text)
        guard let last = document?.topLevel.last else {
            return text.isEmpty ? line + "\n" : line + "\n\n" + text
        }
        guard last.range.upperBound < text.endIndex || text[last.range].hasSuffix("\n") else {
            return text + "\n" + line
        }
        var newText = text
        newText.insert(contentsOf: line + "\n", at: last.range.upperBound)
        return newText
    }

    // MARK: Uninstall

    private static func uninstall(
        from text: String, setting: TOMLDocument.KeyValue?, argv: [String]?, moonletPath: String
    ) -> InstallPlan {
        guard let setting, let argv, let ours = MoonletNotify(argv: argv, moonletPath: moonletPath) else {
            return .unchanged(text)
        }
        var newText = text
        let comments = originalComments(in: text, before: setting.range.lowerBound)
        guard !ours.chained.isEmpty || comments != nil else {
            newText.removeSubrange(insertedRange(of: setting, in: text))
            return InstallPlan(originalText: text, newText: newText, changes: ["Remove Moonlet's notify setting"])
        }

        let lineBreak = text[setting.range].hasSuffix("\n") ? "\n" : ""
        var restored = notifyLine(ours.chained) + lineBreak
        if let comments {
            let original = comments.lines.joined(separator: "\n") + lineBreak
            // Trust the saved lines only if they still describe the chained command.
            let savedArgv = (try? TOMLDocument(original))?.topLevel.first { $0.isKey("notify") }
                .flatMap { TOMLDocument.stringArray(original[$0.valueRange]) }
            if savedArgv == ours.chained {
                restored = original
            }
        }
        newText.replaceSubrange((comments?.range.lowerBound ?? setting.range.lowerBound)..<setting.range.upperBound, with: restored)
        let description = ours.chained.first.map { "Restore the original notify command (\($0))" }
        return InstallPlan(
            originalText: text, newText: newText, changes: [description ?? "Restore the original notify setting"])
    }

    /// The text to remove for a setting Moonlet inserted, including the line break that
    /// `inserting(_:into:)` added around it.
    private static func insertedRange(of setting: TOMLDocument.KeyValue, in text: String) -> Range<String.Index> {
        var range = setting.range
        if range.lowerBound == text.startIndex, text[range.upperBound...].hasPrefix("\n") {
            range = range.lowerBound..<text.index(after: range.upperBound)
        } else if range.upperBound == text.endIndex, !text[range].hasSuffix("\n"), range.lowerBound > text.startIndex,
            text[text.index(before: range.lowerBound)] == "\n"
        {
            range = text.index(before: range.lowerBound)..<range.upperBound
        }
        return range
    }

    /// The `# moonlet-original:` lines directly above `index`, without their prefix.
    private static func originalComments(
        in text: String, before index: String.Index
    ) -> (range: Range<String.Index>, lines: [Substring])? {
        var start = index
        var lines: [Substring] = []
        while start > text.startIndex {
            let lineBreak = text.index(before: start)
            guard text[lineBreak] == "\n" else { break }
            let lineStart = text[..<lineBreak].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[lineStart..<lineBreak]
            guard line.hasPrefix(originalMarker) else { break }
            lines.insert(line.dropFirst(originalMarker.count), at: 0)
            start = lineStart
        }
        return lines.isEmpty ? nil : (start..<index, lines)
    }

    // MARK: Helpers

    private static func scan(_ text: String) throws -> TOMLDocument {
        do {
            return try TOMLDocument(text)
        } catch let error as TOMLDocument.SyntaxError {
            throw InstallError("config.toml couldn't be read (\(error)), so Moonlet left it alone.")
        }
    }

    private static func arguments(of setting: TOMLDocument.KeyValue, in text: String) throws -> [String] {
        guard let argv = TOMLDocument.stringArray(text[setting.valueRange]) else {
            throw InstallError("notify in config.toml isn't an array of strings, so Moonlet left it alone.")
        }
        return argv
    }

    private static func notifyLine(_ argv: [String]) -> String {
        "notify = \(TOMLDocument.render(argv))"
    }
}

/// Moonlet's notify command: `[<moonlet>, "hook", "codex"]`, optionally followed by
/// `"--then"` and the chained command.
private struct MoonletNotify {
    let executable: String
    let chained: [String]

    init(executable: String, chained: [String]) {
        self.executable = executable
        self.chained = chained
    }

    /// Recognizes Moonlet's command: run through `moonletPath`, or anything named like moonlet.
    init?(argv: [String], moonletPath: String?) {
        guard argv.count >= 3, argv[1] == "hook", argv[2] == "codex",
            argv[0] == moonletPath || argv[0].split(separator: "/").last?.lowercased().contains("moonlet") == true
        else { return nil }
        executable = argv[0]
        chained = argv.count > 3 && argv[3] == "--then" ? Array(argv.dropFirst(4)) : []
    }

    func argv(executable: String) -> [String] {
        [executable, "hook", "codex"] + (chained.isEmpty ? [] : ["--then"] + chained)
    }
}
