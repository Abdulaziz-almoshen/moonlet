import AppKit
import MoonletCore
import ServiceManagement

extension AppModel {
    /// The menu bar moon's menu, rebuilt each time it opens.
    func buildMenu(_ menu: NSMenu) {
        let agents = store.agents.filter { !$0.ended || $0.state.isFinished }
        let counts = store.counts
        let parts = [(counts.waiting, "need you"), (counts.working, "working"), (counts.failed, "failed"), (counts.done, "done")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 && $0.1 == "need you" ? "needs you" : $0.1)" }
        menu.addItem(.header(parts.isEmpty ? "No agents right now" : parts.joined(separator: " · ")))
        for agent in agents.prefix(10) {
            let item = MenuItem("\(agent.label) — \(Self.stateWord(agent.state))") { [weak self] in self?.openAgent(agent.id) }
            item.toolTip = agent.title
            menu.addItem(item)
        }
        menu.addItem(MenuItem("Show all agents", key: "m", modifiers: [.control, .option]) { [weak self] in
            self?.openSummon(at: nil)
        })
        menu.addItem(.separator())

        if let pausedUntil, pausedUntil > Date() {
            let time = pausedUntil.formatted(date: .omitted, time: .shortened)
            menu.addItem(MenuItem("Resume cards (paused until \(time))") { [weak self] in self?.pause(for: nil) })
        } else {
            let pause = NSMenuItem(title: "Pause cards", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(MenuItem("For 30 minutes") { [weak self] in self?.pause(for: 30 * 60) })
            submenu.addItem(MenuItem("For 1 hour") { [weak self] in self?.pause(for: 3600) })
            submenu.addItem(MenuItem("Until tomorrow") { [weak self] in
                let morning = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 8), matchingPolicy: .nextTime)
                self?.pause(for: (morning ?? Date().addingTimeInterval(12 * 3600)).timeIntervalSinceNow)
            })
            pause.submenu = submenu
            menu.addItem(pause)
        }

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu()
        menu.addItem(settingsItem)
        menu.addItem(MenuItem(Integrations.isClaudeCodeConnected ? "Claude Code connected" : "Connect Claude Code…",
                              enabled: !Integrations.isClaudeCodeConnected) { Integrations.connectClaudeCode() })
        menu.addItem(MenuItem(Integrations.isCodexConnected ? "Codex connected" : "Connect Codex…",
                              enabled: !Integrations.isCodexConnected) { Integrations.connectCodex() })
        menu.addItem(MenuItem("Preview the pointer (20 seconds)") { [weak self] in self?.previewPointer() })
        menu.addItem(MenuItem("Play a demo") { [weak self] in self?.runDemo() })
        menu.addItem(.separator())
        menu.addItem(MenuItem("Quit Moonlet", key: "q") { NSApp.terminate(nil) })
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(toggle("Moonlet pointer while agents work", \.pointerSkin))
        menu.addItem(toggle("Companion brings the cards", \.companion))
        if let reason = skin.suspendedReason {
            menu.addItem(.header("Pointer paused: \(reason)"))
            menu.addItem(MenuItem("Turn the pointer back on") { [weak self] in self?.skin.resume() })
        }
        let hold = NSMenuItem(title: "Card stays", action: nil, keyEquivalent: "")
        let holdMenu = NSMenu()
        for seconds in [2.0, 4, 5] {
            let item = MenuItem("\(Int(seconds)) seconds while you're active") { [weak self] in
                self?.settings.holdSeconds = seconds
                self?.applySettings()
            }
            item.state = settings.holdSeconds == seconds ? .on : .off
            holdMenu.addItem(item)
        }
        hold.submenu = holdMenu
        menu.addItem(hold)
        menu.addItem(.separator())
        menu.addItem(toggle("Summon with a small circle", \.summonWithCircle))
        menu.addItem(toggle("Hold cards during calls", \.holdDuringCalls))
        menu.addItem(toggle("Flash instead of a card for quick tasks you watched", \.skipWhenWatching))
        menu.addItem(toggle("Learn which projects I skip", \.learns))
        menu.addItem(.separator())
        menu.addItem(toggle("Short summaries with a local model", \.localSummaries))
        let models = NSMenuItem(title: "Summary model", action: nil, keyEquivalent: "")
        let modelsMenu = NSMenu()
        modelsMenu.addItem(.header("Looking for Ollama models…"))
        models.submenu = modelsMenu
        menu.addItem(models)
        Task { [weak self] in
            guard let self else { return }
            let installed = await self.installedModels()
            let active = await self.activeModel()
            modelsMenu.removeAllItems()
            let automatic = MenuItem("Automatic\(active.map { " (\($0))" } ?? "")") { [weak self] in
                self?.settings.summaryModel = nil
                self?.applySettings()
            }
            automatic.state = self.settings.summaryModel == nil ? .on : .off
            modelsMenu.addItem(automatic)
            if installed.isEmpty { modelsMenu.addItem(.header("Ollama isn't running")) }
            for name in installed {
                let item = MenuItem(name) { [weak self] in
                    self?.settings.summaryModel = name
                    self?.applySettings()
                }
                item.state = self.settings.summaryModel == name ? .on : .off
                modelsMenu.addItem(item)
            }
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            menu.addItem(.separator())
            let login = MenuItem("Open at login") {
                let service = SMAppService.mainApp
                if service.status == .enabled { try? service.unregister() } else { try? service.register() }
            }
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        return menu
    }

    private func toggle(_ title: String, _ key: ReferenceWritableKeyPath<Settings, Bool>) -> NSMenuItem {
        let item = MenuItem(title) { [weak self] in
            guard let self else { return }
            self.settings[keyPath: key].toggle()
            self.applySettings()
        }
        item.state = settings[keyPath: key] ? .on : .off
        return item
    }

    static func stateWord(_ state: AgentState) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .waiting: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

/// A menu item that runs a closure.
final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

private extension NSMenuItem {
    static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
