import Foundation
import Testing

@testable import MoonletSetup

@Suite("ShellStartup")
struct ShellStartupTests {
    private let home = URL(filePath: "/Users/example", directoryHint: .isDirectory)

    // MARK: Files

    @Test func zshenvIsAlwaysRead() {
        #expect(ShellStartup.files(environment: [:], home: home).map(\.path) == ["/Users/example/.zshenv"])
        #expect(ShellStartup.files(environment: ["SHELL": "/bin/sh"], home: home).map(\.path) == ["/Users/example/.zshenv"])
    }

    @Test func zdotdirAddsItsOwnZshenv() {
        let files = ShellStartup.files(environment: ["ZDOTDIR": "~/.config/zsh"], home: home)
        #expect(files.map(\.path) == ["/Users/example/.zshenv", "/Users/example/.config/zsh/.zshenv"])
        // The same file once.
        #expect(ShellStartup.files(environment: ["ZDOTDIR": "/Users/example/"], home: home).count == 1)
    }

    @Test func bashReadsBashEnvForCommands() {
        let files = ShellStartup.files(environment: ["SHELL": "/opt/homebrew/bin/bash", "BASH_ENV": "~/.bashenv"], home: home)
        #expect(files.map(\.path) == ["/Users/example/.zshenv", "/Users/example/.bashenv"])
        // Other shells don't read it.
        #expect(ShellStartup.files(environment: ["SHELL": "/bin/zsh", "BASH_ENV": "~/.bashenv"], home: home).count == 1)
        #expect(ShellStartup.files(environment: ["SHELL": "/bin/bash", "BASH_ENV": " "], home: home).count == 1)
    }

    // MARK: Terminal commands

    @Test(arguments: [
        ("stty -ixon\n", "stty"),
        ("export PATH=\"$HOME/bin:$PATH\"\ntput setaf 2\n", "tput"),
        ("COLUMNS=$(tput cols)\n", "tput"),
        ("tty -s && export HAS_TTY=1\n", "tty -s"),
        ("read -t 1 -k key\n", "read -t"),
        ("read -rq answer\n", "read -rq"),
        ("exec </dev/tty\n", "/dev/tty"),
        ("printf 'hi' > /dev/tty\n", "/dev/tty"),
        ("/bin/stty erase '^?'\n", "stty"),
        ("if [[ -o interactive ]]; then\n  bindkey -e\nfi\nstty -ixon\n", "stty"),
        ("if [[ -o login ]]; then\n  stty -ixon\nfi\n", "stty"),
        // The non-interactive branch of an interactive test, and early returns that leave the rest to non-interactive shells.
        ("if [[ -o interactive ]]; then\n  bindkey -e\nelse\n  stty -ixon\nfi\n", "stty"),
        ("if [[ $- != *i* ]]; then\n  stty -ixon\nfi\n", "stty"),
        ("[[ $- == *i* ]] && return\nstty -ixon\n", "stty"),
        ("[[ -o interactive ]] && return\ntput cols\n", "tput"),
    ])
    func findsCommandsThatUseTheTerminal(text: String, command: String) {
        #expect(ShellStartup.terminalCommand(in: text) == command)
    }

    @Test(arguments: [
        "",
        "export PATH=\"$HOME/bin:$PATH\"\n# stty -ixon\n",
        "export GPG_TTY=$(tty)\n",
        "while read -r line; do path+=($line); done < ~/.paths\n",
        "[[ -o interactive ]] && stty -ixon\n",
        "[ -t 0 ] && stty -ixon\n",
        "if [[ $- == *i* ]]; then\n  stty -ixon\n  if true; then\n    tput setaf 1\n  fi\nfi\n",
        "if [ -n \"$PS1\" ]; then\n  stty -ixon\nfi\n",
        "[[ $- != *i* ]] && return\nstty -ixon\n",
        "[[ -o interactive ]] || return\nstty -ixon\n",
        "if [[ $- != *i* ]]; then\n  export X=1\nelse\n  stty -ixon\nfi\n",
        "case $- in\n  *i*) ;;\n  *) return ;;\nesac\nstty sane\n",
        "export HISTFILE=~/.history # stty is for later\n",
    ])
    func ignoresCommentsAndInteractiveOnlyCommands(text: String) {
        #expect(ShellStartup.terminalCommand(in: text) == nil)
    }

    @Test func reportsTheFirstFileThatUsesTheTerminal() {
        let files = ShellStartup.files(environment: ["ZDOTDIR": "~/.config/zsh"], home: home)
        let texts = [
            "/Users/example/.zshenv": "export EDITOR=vim\n",
            "/Users/example/.config/zsh/.zshenv": "stty -ixon\n",
        ]
        let use = ShellStartup.terminalUse(in: files) { texts[$0.path] }
        #expect(use?.file.path == "/Users/example/.config/zsh/.zshenv")
        #expect(use?.command == "stty")
        // Missing files don't count.
        #expect(ShellStartup.terminalUse(in: files) { _ in nil } == nil)
    }
}
