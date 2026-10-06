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
    /// When a command does several, the furthest step wins.
    static func milestone(forCommand command: String) -> String? {
        simpleCommands(in: command).compactMap(action(for:)).max()?.milestone
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
            switch firstOperand(of: arguments, optionsWithValues: gitOptionsWithValues)?.word {
            case "commit": return .commit
            case "push": return .push
            default: return nil
            }
        case "gh":
            let ghOptionsWithValues: Set<Substring> = ["-R", "--repo"]
            guard let group = firstOperand(of: arguments, optionsWithValues: ghOptionsWithValues),
                group.word == "pr",
                firstOperand(of: arguments[group.index...].dropFirst(), optionsWithValues: ghOptionsWithValues)?
                    .word == "create"
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
