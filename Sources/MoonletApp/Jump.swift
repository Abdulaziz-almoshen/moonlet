import AppKit
import MoonletCore

/// Brings an agent's window forward: the exact terminal tab when the agent
/// runs in Terminal or iTerm2, otherwise the app that hosts it.
@MainActor
enum Jump {
    static func open(_ agent: Agent) {
        guard let bundleID = bundleID(for: agent) else { return }
        if let tty = agent.host?.tty, focusTab(bundleID: bundleID, tty: tty) { return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// A short, human name for where the agent runs: iTerm, Terminal, VS Code, Claude.
    static func placeName(for agent: Agent) -> String {
        if let bundleID = bundleID(for: agent),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        switch agent.source {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return agent.source
        }
    }

    static func bundleID(for agent: Agent) -> String? {
        if let bundleID = agent.host?.bundleID { return bundleID }
        switch agent.host?.termProgram {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }

    /// Selects the tab whose terminal is `tty`. Asks for Automation permission the first time.
    private static func focusTab(bundleID: String, tty: String) -> Bool {
        let quotedTTY = tty.replacingOccurrences(of: "\"", with: "")
        let source: String
        switch bundleID {
        case "com.googlecode.iterm2":
            source = """
                tell application id "com.googlecode.iterm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(quotedTTY)" then
                          select w
                          select t
                          select s
                          activate
                          return true
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                return false
                """
        case "com.apple.Terminal":
            source = """
                tell application id "com.apple.Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(quotedTTY)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                      end if
                    end repeat
                  end repeat
                end tell
                return false
                """
        default:
            return false
        }
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue == true
    }
}
