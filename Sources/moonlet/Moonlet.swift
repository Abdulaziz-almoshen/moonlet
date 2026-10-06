import Foundation
import MoonletCore
import MoonletIPC
import MoonletSetup

/// The `moonlet` command-line tool.
///
/// Exit status: 0 on success, 1 when something failed, 2 for a bad command line.
/// `moonlet hook …` always exits 0.
@main
enum Moonlet {
    static let version = "0.1.0"

    static func main() async {
        // A closed socket must surface as a write error, never as a fatal signal.
        signal(SIGPIPE, SIG_IGN)

        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(0)
        }
        let rest = Array(arguments.dropFirst())
        if command == "hook" {
            HookCommand.run(rest)
        }

        let environment = ProcessInfo.processInfo.environment
        let paths = MoonletPaths(environment: environment)
        do {
            let status: Int32
            switch command {
            case "status": status = try StatusCommand.run(rest, paths: paths)
            case "summon": status = try StatusCommand.summon(rest, paths: paths)
            case "emit": status = try EmitCommand.run(rest, paths: paths)
            case "demo": status = try await DemoCommand.run(rest, paths: paths)
            case "install": status = try InstallCommand.run(.install, rest, environment: environment)
            case "uninstall": status = try InstallCommand.run(.uninstall, rest, environment: environment)
            case "doctor": status = try await DoctorCommand.run(rest, paths: paths, environment: environment)
            case "version", "--version":
                print("moonlet \(version) (protocol v\(MoonletEvent.protocolVersion))")
                status = 0
            case "help", "--help", "-h":
                print(usage)
                status = 0
            default:
                throw UsageError("Unknown command '\(command)'.")
            }
            exit(status)
        } catch let error as UsageError {
            Console.error("\(error.message) Run 'moonlet help' for usage.")
            exit(2)
        } catch {
            Console.error("\(error)")
            exit(1)
        }
    }

    static let usage = """
        moonlet: AI agent status at your pointer.

        Usage: moonlet <command> [options]

        Commands:
          status [--json]                List the agents Moonlet is tracking
          summon                         Show every session at the pointer
          emit --session ID [fields]     Report status from a script or a custom agent
          demo [--speed X]               Play a 25-second scenario with three made-up agents
          install claude-code|codex      Connect an agent [--dry-run] [--settings PATH | --config PATH]
          uninstall claude-code|codex    Disconnect an agent (same options)
          doctor                         Check the app, the integrations, and Ollama
          hook claude-code|codex         Entry point for agent hooks; not for direct use
          version                        Print the version
          help                           Show this help

        Fields for emit:
          --source NAME      Producer name (default: cli)
          --label TEXT       Display label (default: the current directory's name)
          --state STATE      idle, working, waiting, done, or failed
          --title TEXT       What the agent was asked
          --activity TEXT    What it's doing now
          --summary TEXT     Its final message
          --message TEXT     What it needs (waiting) or why it failed (failed)
          --milestone TEXT   A notable step, such as "Deployed to staging"
          --progress N/M     Explicit progress
          --end              The session is over (no other fields)

        Environment:
          MOONLET_HOME       Use this directory for the socket, spool, and logs
          MOONLET_DEBUG=1    Log hook errors to ~/Library/Logs/Moonlet/hook.log

        Exit status: 0 on success, 1 on failure, 2 for a bad command line.
        """
}
