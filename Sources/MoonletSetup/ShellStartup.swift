import Foundation

/// Finds terminal commands in the shell startup files that a hook's shell reads.
///
/// Codex 0.153 and 0.154 start hooks without detaching them from the terminal (see
/// `CodexInstaller.runsHooksOnTheTerminal(codexVersion:)`). A shell that runs `stty` or
/// reads the terminal from a startup file can then be stopped by the system, and Codex
/// waits for the hook until its timeout. Read only: nothing here changes a file.
public enum ShellStartup {
    /// The startup files a non-interactive `<shell> -c` may read: `~/.zshenv` and
    /// `$ZDOTDIR/.zshenv`, which every zsh reads, and `$BASH_ENV` when the login shell is
    /// bash. `sh -c` reads none.
    public static func files(environment: [String: String], home: URL) -> [URL] {
        var files = [home.appending(path: ".zshenv", directoryHint: .notDirectory)]
        if let directory = nonEmpty(environment["ZDOTDIR"]) {
            files.append(url(forPath: directory, home: home).appending(path: ".zshenv", directoryHint: .notDirectory))
        }
        let shell = environment["SHELL"].flatMap { $0.split(separator: "/").last }
        if shell == "bash", let file = nonEmpty(environment["BASH_ENV"]) {
            files.append(url(forPath: file, home: home))
        }
        var seen: Set<String> = []
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The first of `files` whose text uses the terminal, with the command that does;
    /// `nil` when none does or none can be read.
    ///
    /// - Parameter read: The text of a file, or `nil` if it can't be read.
    public static func terminalUse(in files: [URL], read: (URL) -> String?) -> (file: URL, command: String)? {
        for file in files {
            if let text = read(file), let command = terminalCommand(in: text) {
                return (file, command)
            }
        }
        return nil
    }

    /// The first command in a startup file's text that uses the terminal: `stty`, `tput`,
    /// `tty -s`, `read` with `-t`, `-k`, or `-q`, or a redirection from or to `/dev/tty`.
    /// Comments don't count, and neither do commands that only run in interactive shells:
    /// behind a test such as `[[ -o interactive ]]`, `$-`, `$PS1`, or `[[ -t 0 ]]`, on the
    /// same line or in the `if` or `case` it opens, or after such a test returns early.
    public static func terminalCommand(in text: String) -> String? {
        var depth = 0
        var guardedDepth: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let commands = simpleCommands(in: code(in: line))
            let testsInteractive = testsForInteractiveShell(Array(commands.joined()))
            for words in commands {
                let keyword = words.first
                if keyword == "if" || keyword == "case" {
                    depth += 1
                    if testsInteractive, guardedDepth == nil {
                        guardedDepth = depth
                    }
                } else if keyword == "fi" || keyword == "esac" {
                    if guardedDepth == depth {
                        guardedDepth = nil
                    }
                    depth = max(depth - 1, 0)
                }
                if testsInteractive || guardedDepth != nil {
                    // `[[ -o interactive ]] || return`, or `*) return ;;` in `case $- in`:
                    // the rest of the file runs only in interactive shells.
                    if words.contains(where: { $0 == "return" || $0 == "exit" }) {
                        return nil
                    }
                    continue
                }
                if let command = terminalCommand(words) {
                    return command
                }
            }
        }
        return nil
    }

    // MARK: Internals

    private static func terminalCommand(_ words: [Substring]) -> String? {
        for (index, word) in words.enumerated() {
            // `</dev/tty`, `2>/dev/tty`, or `< /dev/tty`.
            let target = word.drop { "<>0123456789".contains($0) }
            let redirects = target != word && (word.contains("<") || word.contains(">"))
                || index > 0 && (words[index - 1].hasSuffix("<") || words[index - 1].hasSuffix(">"))
            if target == "/dev/tty", redirects {
                return "/dev/tty"
            }
        }
        let skipped: Set<Substring> = [
            "if", "then", "else", "elif", "while", "until", "do", "!", "command", "builtin", "exec", "noglob", "nocorrect",
            "time", "env", "sudo",
        ]
        let command = words.drop { skipped.contains($0) || ($0.contains("=") && !$0.hasPrefix("-")) }
        guard let program = command.first?.split(separator: "/").last else { return nil }
        let arguments = command.dropFirst()
        switch program {
        case "stty", "tput":
            return String(program)
        case "tty" where arguments.contains("-s"):
            return "tty -s"
        case "read":
            let option = arguments.first { $0.hasPrefix("-") && $0.dropFirst().contains { "tkq".contains($0) } }
            return option.map { "read \($0)" }
        default:
            return nil
        }
    }

    /// Whether a line tests for an interactive shell or a terminal on standard input or output.
    private static func testsForInteractiveShell(_ words: [Substring]) -> Bool {
        words.contains { $0.contains("interactive") || $0.contains("$-") || $0.contains("${-") || $0.contains("PS1") }
            || zip(words, words.dropFirst()).contains { ["[[", "[", "test"].contains($0) && $1 == "-t" }
    }

    /// A line without its comment: from a `#` that starts a word. Quoting is ignored.
    private static func code(in line: Substring) -> Substring {
        var previous: Character = " "
        for index in line.indices {
            if line[index] == "#", previous.isWhitespace {
                return line[..<index]
            }
            previous = line[index]
        }
        return line
    }

    /// The words of each simple command on a line, split at `;`, `|`, `&`, parentheses,
    /// braces, and backquotes. Quoting is ignored, which is plenty for spotting commands.
    private static func simpleCommands(in line: Substring) -> [[Substring]] {
        line.split { ";|&(){}`".contains($0) }
            .map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    private static func url(forPath path: String, home: URL) -> URL {
        if path == "~" || path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2)), directoryHint: .notDirectory)
        }
        return URL(filePath: path, directoryHint: .notDirectory)
    }
}
