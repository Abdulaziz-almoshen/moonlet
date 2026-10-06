import AppKit
import MoonletIPC

/// Moonlet runs as a menu bar app with no Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        do {
            try model.start()
            self.model = model
        } catch MoonletServer.Error.alreadyRunning {
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Moonlet couldn't start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
        if CommandLine.arguments.contains("--demo") { model.runDemo() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--render-docs") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "docs/images"
    MainActor.assumeIsolated { DocsRenderer.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-film") {
    let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "/tmp/moonlet-frames"
    MainActor.assumeIsolated { DemoFilm.render(to: URL(fileURLWithPath: directory)) }
    exit(0)
}

// Hand the pointer back even when stopped from a terminal.
signal(SIGTERM) { _ in CGDisplayShowCursor(CGMainDisplayID()); exit(0) }
signal(SIGINT) { _ in CGDisplayShowCursor(CGMainDisplayID()); exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
