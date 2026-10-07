/// Spots git and GitHub CLI commands worth calling out as milestones.
enum ShellMilestone {
    private enum Action: Int, Comparable {
        case commit, push, pullRequest

        static func < (lhs: Action, rhs: Action) -> Bool { lhs.rawValue < rhs.rawValue }

        var milestone: String {
            switch self {
            case .commit: "Committed changes"
            case .push: "Pushed changes"
            case .pullRequest: "Opened a pull request"
            }
        }
    }

    /// The milestone for a shell command, if it commits, pushes, or opens a pull request.
    /// When a command does several, the furthest step wins. For a command known to have
    /// succeeded.
    static func milestone(forCommand command: String) -> String? {
        actions(in: command).max()?.milestone
    }

    /// The milestone for a command whose exit status is unknown, judged from its output:
    /// git's `[branch abc1234] message` line for a commit; a ref update, `Everything
    /// up-to-date`, or `set up to track` for a push; a `/pull/<number>` URL for a pull
    /// request. Output with `error:`, `fatal:`, or a `! [rejected]` ref shows a failure,
    /// and earns nothing. When a command does several, the furthest step it shows wins.
    static func milestone(forCommand command: String, output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.drop { $0.isWhitespace } }
        guard !lines.contains(where: showsFailure) else { return nil }
        return actions(in: command)
            .filter { action in
                switch action {
                case .commit: lines.contains(where: isCommitSummary)
                case .push: lines.contains(where: showsPush)
                case .pullRequest:
                    lines.contains(where: hasPullRequestURL) && !lines.contains { $0.contains("already exists") }
                }
            }
            .max()?.milestone
    }

    // MARK: Output

    /// `error: …` and `fatal: …` lines from git, and refs a push couldn't update
    /// (`! [rejected]`, `! [remote rejected]`).
    private static func showsFailure(_ line: Substring) -> Bool {
        line.hasPrefix("error:") || line.hasPrefix("fatal:") || line.hasPrefix("! [")
    }

    /// `[main 3f2a1b9] Add retries`, `[main (root-commit) 3f2a1b9] Initial commit`, or
    /// `[detached HEAD 3f2a1b9] …`: the line git prints for a commit it made.
    private static func isCommitSummary(_ line: Substring) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return false }
        var words = line[line.index(after: line.startIndex)..<close].split(separator: " ")
        guard let hash = words.popLast(), isHash(hash) else { return false }
        if words.last == "(root-commit)" {
            words.removeLast()
        }
        return !words.isEmpty
    }

    /// A line git prints for a push that went through: a ref update (`   1a2b3c4..5d6e7f8  main -> main`,
    /// `+ 1a2b3c4...5d6e7f8 main -> main (forced update)`, ` * [new branch]      retries -> retries`),
    /// `Everything up-to-date`, or `branch 'retries' set up to track 'origin/retries'.`
    private static func showsPush(_ line: Substring) -> Bool {
        if line.hasPrefix("Everything up-to-date") || line.contains("set up to track") {
            return true
        }
        guard line.contains(" -> ") else { return false }
        var summary = line
        if summary.first == "+" || summary.first == "*" {
            summary = summary.dropFirst().drop { $0.isWhitespace }
        }
        if summary.hasPrefix("[new ") {
            return true
        }
        let commits = summary.prefix { !$0.isWhitespace }
        let ends = commits.split(separator: ".")
        return commits.contains("..") && ends.count == 2 && ends.allSatisfy(isHash)
    }

    /// Whether a line holds a pull request's URL, such as `https://github.com/o/r/pull/42`.
    private static func hasPullRequestURL(_ line: Substring) -> Bool {
        var rest = line
        while let range = rest.firstRange(of: "/pull/") {
            let url = line[..<range.lowerBound].split(whereSeparator: \.isWhitespace).last ?? ""
            if url.hasPrefix("http"), rest[range.upperBound...].first?.isNumber == true {
                return true
            }
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// An abbreviated or full commit hash.
    private static func isHash(_ word: Substring) -> Bool {
        (4...64).contains(word.count) && word.allSatisfy(\.isHexDigit)
    }

    // MARK: Commands

    private static func actions(in command: String) -> [Action] {
        simpleCommands(in: command).compactMap(action(for:))
    }

    /// Splits a command line into the words of each simple command. Quoting is ignored,
    /// which is plenty for spotting `git` and `gh` invocations.
    private static func simpleCommands(in command: String) -> [[Substring]] {
        command
            .split { ";|&()`\n".contains($0) }
            .map { $0.split(whereSeparator: \.isWhitespace) }
    }

    private static let commandPrefixes: Set<Substring> = ["sudo", "command", "env", "exec", "nohup", "time"]

    private static func action(for words: [Substring]) -> Action? {
        let words = words.drop { commandPrefixes.contains($0) || ($0.contains("=") && !$0.hasPrefix("-")) }
        guard let program = words.first?.split(separator: "/").last else { return nil }
        let arguments = words.dropFirst()
        switch program {
        case "git":
            let gitOptionsWithValues: Set<Substring> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace"]
            guard let operand = firstOperand(of: arguments, optionsWithValues: gitOptionsWithValues) else { return nil }
            // A dry run changes nothing. (`git commit -n` skips hooks; it isn't a dry run.)
            let rest = arguments[operand.index...].dropFirst()
            switch operand.word {
            case "commit": return rest.contains("--dry-run") ? nil : .commit
            case "push": return rest.contains("--dry-run") || rest.contains("-n") ? nil : .push
            default: return nil
            }
        case "gh":
            let ghOptionsWithValues: Set<Substring> = ["-R", "--repo"]
            guard let group = firstOperand(of: arguments, optionsWithValues: ghOptionsWithValues),
                group.word == "pr",
                firstOperand(of: arguments[group.index...].dropFirst(), optionsWithValues: ghOptionsWithValues)?
                    .word == "create",
                !arguments.contains("--dry-run")
            else { return nil }
            return .pullRequest
        default:
            return nil
        }
    }

    /// The first word that isn't an option or an option's value.
    private static func firstOperand(
        of words: ArraySlice<Substring>, optionsWithValues: Set<Substring>
    ) -> (word: Substring, index: Int)? {
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            if !word.hasPrefix("-") {
                return (word, index)
            }
            index += optionsWithValues.contains(word) ? 2 : 1
        }
        return nil
    }
}
