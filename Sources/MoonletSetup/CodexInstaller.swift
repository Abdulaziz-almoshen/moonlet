import Foundation

/// Connects Codex to Moonlet: through hooks in `hooks.json` when the installed Codex has
/// them (see `CodexHooksInstaller`), otherwise through the `notify` setting in
/// `config.toml`, which this type edits.
///
/// Codex runs one notify command, so an existing one is chained rather than replaced:
/// `notify = ["<moonlet>", "hook", "codex", "--then", <original argv…>]`. The original
/// lines are kept verbatim in `# moonlet-original:` comments above the setting, so
/// uninstalling restores them byte for byte.
public enum CodexInstaller {
    /// How Moonlet hears from Codex.
    public enum Mechanism: Sendable, Equatable {
        /// Hooks in `hooks.json`: every step, including permission requests.
        case hooks
        /// The `notify` program in `config.toml`: finished turns only.
        case notify
    }

    /// Where the notify setting stands.
    public enum NotifyStatus: Sendable, Equatable {
        /// No top-level `notify` setting.
        case notConfigured
        /// `notify` runs a command other than Moonlet.
        case foreign([String])
        /// `notify` runs Moonlet, then the `chained` command (empty when there's none).
        case installed(executable: String, chained: [String])
        /// `notify` runs another program, which runs Moonlet's notify command in turn, such
        /// as one that keeps the previous setting in a `--previous-notify` argument.
        case nested(notifier: [String], executable: String)
    }

    /// The first Codex version whose hooks Moonlet uses. Hooks exist from 0.124, but before
    /// 0.153 Codex printed every hook run in its transcript.
    public static let minimumHooksVersion = [0, 153, 0]

    /// The mechanism a Codex version string such as `"codex-cli 0.154.0"` supports, or
    /// `nil` when the version is unknown.
    public static func mechanism(forCodexVersion version: String?) -> Mechanism? {
        guard let components = version.flatMap(ClaudeCodeInstaller.versionComponents) else { return nil }
        return components.lexicographicallyPrecedes(minimumHooksVersion) ? .notify : .hooks
    }

    /// The edits to both files.
    public struct Plans: Sendable, Equatable {
        /// The mechanism being installed; for an uninstall, the one that was in use.
        public let mechanism: Mechanism
        public let config: InstallPlan
        public let hooks: InstallPlan
    }

    /// Plans connecting Codex, or disconnecting it.
    ///
    /// Installing for a Codex with hooks adds Moonlet's hooks and doesn't add Moonlet to
    /// `notify`. A notify command that already runs Moonlet stays, as a fallback for
    /// sessions whose hooks don't run (`moonlet hook codex` skips the turns the hooks
    /// reported); only its path to Moonlet is kept current. For an older Codex, Moonlet
    /// chains `notify` instead, and takes its hooks out, since those versions show every
    /// hook run. When the version is unknown, whichever mechanism is already installed
    /// stays; otherwise notify. Uninstalling removes both.
    public static func plans(
        configText: String,
        hooksText: String,
        moonletPath: String,
        action: InstallAction,
        codexVersion: String?
    ) throws -> Plans {
        let hooksInstalled = !(try CodexHooksInstaller.installedHooks(hooksText: hooksText)).isEmpty
        switch action {
        case .uninstall:
            return Plans(
                mechanism: hooksInstalled ? .hooks : .notify,
                config: try plan(configText: configText, moonletPath: moonletPath, action: .uninstall),
                hooks: try CodexHooksInstaller.plan(hooksText: hooksText, moonletPath: moonletPath, action: .uninstall))
        case .install:
            let mechanism = mechanism(forCodexVersion: codexVersion) ?? (hooksInstalled ? .hooks : .notify)
            switch mechanism {
            case .hooks:
                var config = InstallPlan.unchanged(configText)
                if case .installed? = try? notifyStatus(configText: configText) {
                    config = try plan(configText: configText, moonletPath: moonletPath, action: .install)
                }
                return Plans(
                    mechanism: .hooks, config: config,
                    hooks: try CodexHooksInstaller.plan(hooksText: hooksText, moonletPath: moonletPath, action: .install))
            case .notify:
                return Plans(
                    mechanism: .notify,
                    config: try plan(configText: configText, moonletPath: moonletPath, action: .install),
                    hooks: try CodexHooksInstaller.plan(hooksText: hooksText, moonletPath: moonletPath, action: .uninstall))
            }
        }
    }

    /// Plans and, unless `dryRun` is set, applies the edits to `config.toml` and
    /// `hooks.json`, backing up each file it changes.
    public static func apply(
        configURL: URL,
        hooksURL: URL,
        moonletPath: String,
        action: InstallAction,
        codexVersion: String?,
        dryRun: Bool = false,
        now: Date = .now
    ) throws -> (mechanism: Mechanism, config: InstallResult, hooks: InstallResult) {
        let plans = try plans(
            configText: try ConfigFile.read(configURL), hooksText: try ConfigFile.read(hooksURL),
            moonletPath: moonletPath, action: action, codexVersion: codexVersion)
        func applyHooks() throws -> InstallResult {
            try ConfigFile.apply(to: hooksURL, dryRun: dryRun, now: now) { _ in plans.hooks }
        }
        func applyConfig() throws -> InstallResult {
            try ConfigFile.apply(to: configURL, dryRun: dryRun, now: now) { _ in plans.config }
        }
        // Connect before disconnecting the other way, so that failing halfway never leaves
        // Codex reporting through neither.
        if action == .install, plans.mechanism == .notify {
            let config = try applyConfig()
            return (plans.mechanism, config, try applyHooks())
        }
        let hooks = try applyHooks()
        return (plans.mechanism, try applyConfig(), hooks)
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
        if let nested = MoonletNotify.nested(in: argv) {
            return .nested(notifier: argv, executable: nested.executable)
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

    /// Moonlet's command inside another notify command's arguments: as consecutive
    /// arguments, as one argument holding a JSON array (`--previous-notify '["…/moonlet",
    /// "hook","codex"]'`), or as one argument holding a shell command line.
    static func nested(in argv: [String], depth: Int = 0) -> MoonletNotify? {
        guard depth < 4 else { return nil }
        for index in argv.indices.dropFirst() {
            if let ours = MoonletNotify(argv: Array(argv[index...]), moonletPath: nil) {
                return ours
            }
            let argument = argv[index]
            if let array = try? JSONSerialization.jsonObject(with: Data(argument.utf8)) as? [String] {
                if let ours = MoonletNotify(argv: array, moonletPath: nil) ?? nested(in: [""] + array, depth: depth + 1) {
                    return ours
                }
            } else if argument.contains(where: \.isWhitespace) {
                let words = argument.split(whereSeparator: \.isWhitespace).map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                if let ours = MoonletNotify(argv: words, moonletPath: nil) ?? nested(in: [""] + words, depth: depth + 1) {
                    return ours
                }
            }
        }
        return nil
    }
}
