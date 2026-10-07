import AppKit
import Carbon.HIToolbox
import MoonletBrain
import MoonletCore
import MoonletIPC

/// Moonlet's coordinator: agent events come in through the local socket,
/// and cards, the pointer's look, and the menu bar moon come out.
///
/// The flow is one-directional: `AgentStore` turns events into signals, the
/// signals become moments (summarized by the local model when available),
/// `AttentionEngine` decides when the user sees them, and its effects drive
/// the interface.
@MainActor
final class AppModel {
    let settings: Settings
    let paths = MoonletPaths()
    private let server: MoonletServer
    private(set) var store = AgentStore()
    private var engine: AttentionEngine
    private var pointer = PointerPolicy()
    private var stuck = StuckDetector()
    private var engagement: EngagementTracker
    private var gestures: GestureRecognizer
    private let presence = PresenceMonitor()
    private let input = InputMonitor()
    let skin = PointerSkin()
    private let cards = CardPanel()
    private lazy var companion = CompanionDirector(cards: cards)
    private let summon = SummonPanel()
    private let moon = StatusMoon()
    private let model: LocalModel
    private var hotkey: Hotkey?
    private var timer: Timer?
    private var demo: Demo?
    private(set) var pausedUntil: Date?
    private var turnStarted: [String: Date] = [:]
    private var outcomes: [String: String] = [:]
    private var cardShownAt: [UUID: Date] = [:]
    private var lastStuckCheck = Date.distantPast
    private var lastSummonContent: SummonContent?
    /// When the user last opened the summon view, and the time before that,
    /// which decides what counts as new.
    private var lastLookedAt = Date.distantPast
    private var lookedSince = Date.distantPast
    /// Agents whose final message looks like a question, while the model writes the summary.
    private var pendingQuestions: Set<String> = []
    private var lastWarmUp = Date.distantPast
    /// The newest hardware click or scroll already checked for delivery, in seconds since startup.
    private var lastCheckedPress: TimeInterval = 0
    /// When the drawn pointer last started showing, in seconds since startup.
    private var drawingSince: TimeInterval?
    /// Clicks and scrolls that reached an app while the drawn pointer showed, and those that didn't.
    private var pressesWhileDrawing = 0
    private var missedWhileDrawing = 0
    private var lastPressReport = Date()
    private var wasDrawing = false
    private var lastSkinReason: String?
    private var undeliveredPresses: [Date] = []
    /// When a scroll last landed on the parked card, in seconds since startup.
    private var lastScrollOnCard: TimeInterval = -1

    init() {
        let settings = Settings()
        self.settings = settings
        server = MoonletServer(paths: paths)
        engine = AttentionEngine(config: settings.attentionConfig)
        engagement = settings.engagement
        gestures = GestureRecognizer(config: settings.gestureConfig)
        model = LocalModel(model: settings.summaryModel)
        presence.detectsCalls = settings.holdDuringCalls
        cards.flightsLeft = settings.homeFlightsLeft
    }

    // MARK: - Lifecycle

    func start() throws {
        server.onEvent = { [weak self] event in await self?.receive(event) }
        server.onStatus = { [weak self] in await self?.store.agents ?? [] }
        server.onSummon = { [weak self] in await self?.openSummon(at: nil) }
        try server.start()
        replaySpool()

        cards.homeLocation = { [weak self] in self?.moon.screenLocation }
        companion.isEnabled = settings.companion
        companion.onOpen = { [weak self] id, card in self?.openFromCard(id, card: card) }
        companion.placeName = { [weak self] id in self?.store.agent(id: id).map { Jump.placeName(for: $0) } }
        summon.onOpen = { [weak self] id in self?.openAgent(id) }
        summon.onBatch = { [weak self] project, accept in self?.answerBatchSuggestion(project, accept: accept) }
        moon.buildMenu = { [weak self] menu in self?.buildMenu(menu) }
        input.onMove = { [weak self] point, time, buttons in self?.pointerMoved(point, time: time, buttonsDown: buttons) }
        input.onClick = { [weak self] window in self?.clicked(on: window) }
        input.onLocalPress = { [weak self] event in self?.guardAgainstCapturedInput(event) }
        input.onPress = { [weak self] in
            guard let self, self.skin.isDrawing else { return }
            self.pressesWhileDrawing += 1
        }
        input.start()
        hotkey = Hotkey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) { [weak self] in self?.toggleSummon() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Hands the pointer back and stops listening. Called when Moonlet quits.
    func shutdown() {
        timer?.invalidate()
        input.stop()
        hotkey?.unregister()
        skin.shutdown()
        server.stop()
        settings.engagement = engagement
        settings.homeFlightsLeft = cards.flightsLeft
    }

    /// Events that arrived while Moonlet wasn't running. Recent ones still
    /// surface; older ones only restore state.
    private func replaySpool() {
        guard let backlog = try? Spool(url: paths.spoolURL).drain() else { return }
        for event in backlog.sorted(by: { $0.ts < $1.ts }) {
            receive(event, at: Date(timeIntervalSince1970: event.ts))
        }
    }

    // MARK: - Agent events

    func receive(_ event: MoonletEvent) {
        receive(event, at: Date())
    }

    private func receive(_ event: MoonletEvent, at time: Date) {
        let id = Agent.id(source: event.source, session: event.session)
        let previous = store.agent(id: id)?.state
        let signals = store.apply(event, now: time)
        if let agent = store.agent(id: id) {
            if agent.state == .working, previous != .working {
                turnStarted[id] = time
                pendingQuestions.remove(id)
                warmUpModelIfNeeded()
            }
            // An agent that works again isn't blocked on the user, even after a question.
            // The companion hears first, so it knows to thank rather than just fade.
            if agent.state == .working || agent.state == .idle {
                companion.resolved(agentID: id, ended: agent.ended)
                apply(engine.resolve(agentID: id, now: time))
            }
        }
        let fresh = Date().timeIntervalSince(time) < 600
        for signal in signals where fresh {
            Self.debug("signal \(signal)")
            handle(signal)
        }
        refresh()
    }

    private func handle(_ signal: Signal) {
        let now = Date()
        guard let agent = store.agent(id: signal.agentID) else {
            companion.resolved(agentID: signal.agentID, ended: true)
            apply(engine.resolve(agentID: signal.agentID, now: now))
            return
        }
        switch signal {
        case .needsYou(_, let message):
            // Requests and questions get two lines on the card, so options fit.
            let detail = message.flatMap { $0.isEmpty ? nil : TextTools.oneLine($0, max: 110) }
            deliver(moment(agent, .needsYou, detail ?? "Waiting for you"))
        case .resolved(let id), .ended(let id):
            // A session that ended fades quietly; only an answer gets thanks.
            companion.resolved(agentID: id, ended: agent.ended)
            apply(engine.resolve(agentID: id, now: now))
        case .finished(_, let summary):
            // A turn under a minute you could have watched. Codex reports a turn's start
            // and end together, so near-zero durations mean "unknown", not "quick".
            let quick = turnStarted[agent.id].map { (1..<60).contains(now.timeIntervalSince($0)) } ?? false
            // The plain check is instant, so the pointer turns amber right away for a question.
            if SummaryWriter.fallback(for: summary ?? "").kind == .question { pendingQuestions.insert(agent.id) }
            Task {
                let result = await summarize(summary ?? "")
                pendingQuestions.remove(agent.id)
                outcomes[agent.id] = result.text
                var moment = moment(agent, result.kind == .question ? .question : .finished,
                                    result.text.isEmpty ? "Finished" : result.text)
                // Only a quick task in the app in front counts as already watched.
                if !quick { moment.hostBundleID = nil }
                deliver(moment)
            }
        case .failed(_, let message):
            deliver(moment(agent, .failed, short(message) ?? "Stopped with an error"))
        case .milestone, .progressChanged, .appeared:
            break
        }
    }

    private func summarize(_ text: String) async -> Summary {
        guard settings.localSummaries else { return SummaryWriter.fallback(for: text) }
        return await model.summarize(text)
    }

    /// Loads the summary model while agents work, so the first summary isn't slow.
    private func warmUpModelIfNeeded() {
        guard settings.localSummaries, Date().timeIntervalSince(lastWarmUp) > 20 * 60 else { return }
        lastWarmUp = Date()
        Task { await model.warmUp() }
    }

    private func moment(_ agent: Agent, _ kind: MomentKind, _ detail: String) -> Moment {
        Moment(agentID: agent.id, agentLabel: agent.label, project: project(of: agent), kind: kind,
               detail: detail, createdAt: Date(), hostBundleID: Jump.bundleID(for: agent))
    }

    private func project(of agent: Agent) -> String {
        agent.cwd.map { TextTools.label(fromCwd: $0) } ?? agent.label
    }

    private func short(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return SummaryWriter.shorten(TextTools.oneLine(text, max: 200))
    }

    private func deliver(_ moment: Moment) {
        apply(engine.receive(moment, presence: currentPresence(), now: Date()))
    }

    // MARK: - Attention

    private func currentPresence() -> PresenceSnapshot {
        var snapshot = presence.snapshot()
        // A pause holds cards exactly like a call does, and summarizes on resume.
        if let pausedUntil, Date() < pausedUntil { snapshot.inCall = true }
        return snapshot
    }

    private func apply(_ effects: [AttentionEffect]) {
        let now = Date()
        for effect in effects {
            Self.debug("\(effect)")
            switch effect {
            case .show(let card):
                cardShownAt[card.id] = now
                companion.show(card)
            case .hide(let card, let reason):
                companion.hide(card, reason: reason)
                if reason == .clicked, card.tone == .finished, let shown = cardShownAt[card.id],
                   now.timeIntervalSince(shown) < 1.5 {
                    for moment in card.moments { engagement.record(.dismissedQuickly, project: moment.project, now: now) }
                }
                cardShownAt[card.id] = nil
            case .flash(let kind):
                pointer.flash(PointerTint(kind), now: now)
            }
        }
    }

    private func tick() {
        let now = Date()
        if let pausedUntil, now >= pausedUntil { self.pausedUntil = nil }
        _ = store.prune(now: now)
        apply(engine.tick(presence: currentPresence(), now: now))
        checkThatInputStillFlows(now: now)
        reportPressesIfDue(now: now)
        noteSkinChanges()
        if now.timeIntervalSince(lastStuckCheck) >= 5 {
            lastStuckCheck = now
            let working = store.agents.filter { $0.state == .working && !$0.ended }.map { ($0.id, $0.lastUpdate) }
            for id in stuck.newlyStuck(working: working, now: now) {
                guard let agent = store.agent(id: id) else { continue }
                let minutes = Int(now.timeIntervalSince(agent.lastUpdate) / 60)
                deliver(moment(agent, .stuck, "No news for \(minutes) min"))
            }
        }
        refresh(now: now)
    }

    private func refresh(now: Date = Date()) {
        let blocked = Set(engine.blockedAgents.map(\.agentID))
        skin.isEnabled = settings.pointerSkin
        // The pointer speaks only while an agent talks to you: the card at the pointer
        // sets its color, and an unanswered question keeps it yellow. Silent work never changes it.
        // A question keeps the pointer yellow for up to 10 minutes; after that only its
        // reminder cards bring the color back, so an ignored question can't hold it forever.
        let recentWait = engine.blockedAgents.contains { now.timeIntervalSince($0.since) < 600 }
        let waitingOnUser = recentWait || !pendingQuestions.isEmpty
        let tint = pointer.tint(card: engine.current?.tone, waitingOnUser: waitingOnUser, now: now)
        if tint != skin.tint { Self.debug("pointer \(tint.rawValue)") }
        skin.tint = tint
        moon.setDot(dotColor(blocked: blocked))
        if summon.isOpen {
            let content = summonContent()
            if content != lastSummonContent {
                lastSummonContent = content
                summon.update(content)
            }
        }
    }

    private func activity(of agent: Agent, blocked: Set<String>) -> AgentActivity {
        if blocked.contains(agent.id) || pendingQuestions.contains(agent.id) { return .waiting }
        switch agent.state {
        case .idle: return .idle
        case .working: return .working
        case .waiting: return .waiting
        case .done: return .done
        case .failed: return .failed
        }
    }

    private func dotColor(blocked: Set<String>) -> NSColor? {
        if !blocked.isEmpty { return Palette.needsYou }
        let unseen = engine.queue.map(\.moment) + engine.inbox
        if unseen.contains(where: { $0.kind == .failed || $0.kind == .stuck }) { return Palette.problem }
        return unseen.isEmpty ? nil : Palette.info
    }

    // MARK: - Input safety

    /// Moonlet's click-through windows must never receive input. If one does, the
    /// drawn pointer is in the way, so it turns itself off immediately.
    private func guardAgainstCapturedInput(_ event: NSEvent) {
        if cards.owns(event.window) {
            // A parked card takes input on purpose while the pointer rests on it. That
            // covers a click queued behind the first, made before the card went
            // click-through, and the rest of a scroll gesture macOS keeps on the
            // window where it began.
            let restOfScroll = event.type == .scrollWheel && event.timestamp - lastScrollOnCard < 0.3
            if cards.tookInput(at: event.timestamp) || restOfScroll {
                // A scroll was meant for the app below: the card lets go at once.
                if event.type == .scrollWheel {
                    lastScrollOnCard = event.timestamp
                    cards.setTakesInput(false)
                }
                return
            }
        }
        guard skin.owns(event.window) || companion.owns(event.window) || cards.owns(event.window) else { return }
        suspendSkin("A click or scroll landed on Moonlet's pointer instead of your app")
    }

    /// Clicks and scrolls the hardware registered must reach some app. If two go
    /// missing while the drawn pointer shows, the pointer turns itself off.
    private func checkThatInputStillFlows(now: Date) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard skin.isDrawing else {
            drawingSince = nil
            undeliveredPresses.removeAll()
            return
        }
        // Only presses made while the pointer is drawn count, never older ones.
        let since = drawingSince ?? uptime
        drawingSince = since
        let state = CGEventSourceStateID.combinedSessionState
        let latestPress = [CGEventType.leftMouseDown, .rightMouseDown, .scrollWheel]
            .map { uptime - CGEventSource.secondsSinceLastEventType(state, eventType: $0) }
            .max() ?? 0
        // Readings of one press jitter by microseconds, so a new press must be clearly newer.
        // Give delivery a moment before judging it.
        guard latestPress > since + 0.05, latestPress > lastCheckedPress + 0.05, uptime - latestPress > 0.4 else { return }
        lastCheckedPress = latestPress
        guard input.lastDeliveredPress < latestPress - 0.05 else { return }
        missedWhileDrawing += 1
        undeliveredPresses.append(now)
        undeliveredPresses.removeAll { now.timeIntervalSince($0) > 15 }
        Self.debug("press at \(latestPress) never reached an app (\(undeliveredPresses.count) recently)")
        if undeliveredPresses.count >= 2 { suspendSkin("Clicks stopped reaching your apps while Moonlet's pointer showed") }
    }

    /// Logs when the drawn pointer starts or stops showing, for bug reports.
    private func noteSkinChanges() {
        let reason = skin.whyNotDrawing
        guard reason != lastSkinReason || skin.isDrawing != wasDrawing else { return }
        wasDrawing = skin.isDrawing
        lastSkinReason = reason
        AppLog.write(paths: paths, reason.map { "Pointer skin hidden: \($0)" } ?? "Pointer skin showing (\(skin.tint.rawValue))")
    }

    /// Notes in the log, at most every 30 seconds, whether input flowed while the pointer showed.
    private func reportPressesIfDue(now: Date) {
        guard now.timeIntervalSince(lastPressReport) >= 30, pressesWhileDrawing + missedWhileDrawing > 0 else { return }
        AppLog.write(paths: paths, "While Moonlet's pointer showed: \(pressesWhileDrawing) clicks and scrolls reached your apps, \(missedWhileDrawing) didn't")
        pressesWhileDrawing = 0
        missedWhileDrawing = 0
        lastPressReport = now
    }

    private func suspendSkin(_ reason: String) {
        guard skin.suspendedReason == nil else { return }
        skin.suspend(reason: reason)
        AppLog.write(paths: paths, "Pointer skin turned off: \(reason)")
        Self.debug("pointer skin suspended: \(reason)")
    }

    // MARK: - Pointer and summon

    private func pointerMoved(_ point: CGPoint, time: TimeInterval, buttonsDown: Bool) {
        skin.pointerMoved()
        companion.pointerMoved()
        if summon.isOpen {
            summon.pointerMoved(to: point)
            return
        }
        switch gestures.add(point, at: time, buttonsDown: buttonsDown) {
        case .circle(let center): openSummon(at: center, by: "a circle")
        case nil: break
        }
    }

    /// A mouse button went down; `window` is the Moonlet window it landed on, if any.
    private func clicked(on window: NSWindow?) {
        if summon.isOpen, !summon.contains(NSEvent.mouseLocation) { summon.close() }
        // A click on the parked card is the card's own: its tap opens the agent.
        // Counting it as a click elsewhere would take the card away first.
        if cards.owns(window) { return }
        apply(engine.click(now: Date()))
    }

    /// The user clicked a parked request card: the card counts as seen, and the
    /// agent's tab comes forward.
    private func openFromCard(_ id: String, card: Card) {
        if engine.current?.id == card.id { apply(engine.click(now: Date())) }
        openAgent(id)
    }

    func openSummon(at point: CGPoint?, by trigger: String = "the shortcut or menu") {
        AppLog.write(paths: paths, "Summon view opened by \(trigger)")
        apply(engine.summoned(now: Date()))
        companion.summonOpened()
        lookedSince = lastLookedAt
        lastLookedAt = Date()
        let content = summonContent()
        lastSummonContent = content
        summon.open(at: point ?? NSEvent.mouseLocation, content: content)
        refresh()
    }

    func toggleSummon() {
        if summon.isOpen { summon.close() } else { openSummon(at: nil) }
    }

    private func summonContent() -> SummonContent {
        let now = Date()
        let blocked = Set(engine.blockedAgents.map(\.agentID))
        let rank: [AgentActivity: Int] = [.waiting: 0, .failed: 1, .working: 2, .done: 3, .idle: 4]
        let rows = store.agents
            .filter { !$0.ended || $0.state.isFinished }
            .map { agent in
                let activity = activity(of: agent, blocked: blocked)
                let status = status(of: agent)
                return AgentRow(id: agent.id, label: agent.label, place: Jump.placeName(for: agent),
                                activity: activity, progress: agent.progress?.fraction, status: status,
                                since: agent.stateChangedAt, mood: mood(of: agent, activity: activity),
                                options: activity == .waiting ? Self.options(in: agent.message ?? "") : [],
                                etaMinutes: activity == .working ? eta(of: agent, now: now) : nil,
                                isNew: activity != .working && activity != .idle && agent.stateChangedAt > lookedSince)
            }
            .sorted { (rank[$0.activity] ?? 9, -$0.since.timeIntervalSince1970) < (rank[$1.activity] ?? 9, -$1.since.timeIntervalSince1970) }
        let suggestion = settings.learns
            ? engagement.suggestions(excluding: settings.batchedProjects, now: now).first : nil
        return SummonContent(agents: rows, events: timeline(now: now), earlier: Array(engine.history.prefix(3)), suggestion: suggestion)
    }

    /// How an agent's latest words felt, for its face in the summon view.
    private func mood(of agent: Agent, activity: AgentActivity) -> CompanionMood? {
        switch activity {
        case .waiting: CompanionMood.read(kind: .needsYou, detail: agent.message ?? "")
        case .failed: CompanionMood.read(kind: .failed, detail: agent.message ?? "")
        case .done: CompanionMood.read(kind: .finished, detail: outcomes[agent.id] ?? agent.summary ?? "")
        case .working, .idle: nil
        }
    }

    /// The choices in a question card's text, such as `Which database? SQLite · Postgres`.
    static func options(in message: String) -> [String] {
        guard let mark = message.firstIndex(of: "?") else { return [] }
        return message[message.index(after: mark)...]
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Minutes until a working agent is likely done, from how fast it has been
    /// checking off its own task list this turn.
    private func eta(of agent: Agent, now: Date) -> Int? {
        guard let fraction = agent.progress?.fraction, fraction > 0, fraction < 1,
              let started = turnStarted[agent.id] else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed > 30 else { return nil }
        return max(1, Int((elapsed * (1 - fraction) / fraction / 60).rounded()))
    }

    /// The last hour of moments, oldest first.
    private func timeline(now: Date) -> [TimelineEvent] {
        var seen = Set<UUID>()
        let moments = (engine.history + engine.queue.map(\.moment) + engine.inbox)
            .filter { now.timeIntervalSince($0.createdAt) < 3600 && seen.insert($0.id).inserted }
        return moments
            .sorted { $0.createdAt < $1.createdAt }
            .map { TimelineEvent(id: $0.id, at: $0.createdAt, kind: $0.kind,
                                 mood: CompanionMood.read(kind: $0.kind, detail: $0.detail),
                                 label: "\($0.agentLabel) · \($0.detail)") }
    }

    private func status(of agent: Agent) -> String {
        let text: String? = switch agent.state {
        case .waiting: agent.message ?? "Waiting for you"
        case .working: agent.activity ?? agent.title
        case .done: outcomes[agent.id] ?? agent.title
        case .failed: agent.message
        case .idle: agent.title
        }
        return text.map { TextTools.oneLine($0, max: 60) } ?? ""
    }

    func openAgent(_ id: String) {
        guard let agent = store.agent(id: id) else { return }
        summon.close()
        Jump.open(agent)
        engagement.record(.opened, project: project(of: agent), now: Date())
        settings.engagement = engagement
    }

    private func answerBatchSuggestion(_ project: String, accept: Bool) {
        if accept {
            settings.batchedProjects.insert(project)
            engine.config.batchedProjects = settings.batchedProjects
        } else {
            engagement.decline(project: project)
        }
        settings.engagement = engagement
        lastSummonContent = nil
        refresh()
    }

    // MARK: - Settings that need live updates

    func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) }
        // A pause holds cards like a call: the card at the pointer goes now, not on the next tick.
        apply(engine.tick(presence: currentPresence(), now: Date()))
        refresh()
    }

    func applySettings() {
        engine.config = settings.attentionConfig
        companion.isEnabled = settings.companion
        gestures.config = settings.gestureConfig
        presence.detectsCalls = settings.holdDuringCalls
        Task { await model.setModel(settings.summaryModel) }
        refresh()
    }

    func installedModels() async -> [String] {
        await model.installedModels()
    }

    func activeModel() async -> String? {
        settings.localSummaries ? await model.activeModel() : nil
    }

    /// With `MOONLET_DEBUG` set, logs decisions to standard output.
    static let debugging = ProcessInfo.processInfo.environment["MOONLET_DEBUG"] != nil

    static func debug(_ message: @autoclosure () -> String) {
        guard debugging else { return }
        print("[\(Date().formatted(date: .omitted, time: .standard))] \(message())")
    }

    /// Shows the Moonlet pointer for `seconds` through a stand-in agent, so you can
    /// see it and check that clicks and scrolls still reach your apps.
    func previewPointer(for seconds: TimeInterval = 20) {
        let session = "pointer-preview"
        receive(MoonletEvent(source: "moonlet", session: session, label: "Pointer preview", state: .working,
                             activity: "Click and scroll as usual"))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.receive(MoonletEvent(kind: .end, source: "moonlet", session: session))
            }
        }
    }

    /// Plays a short scripted scenario through the real pipeline.
    func runDemo() {
        demo?.cancel()
        let demo = Demo { [weak self] event in self?.receive(event) }
        self.demo = demo
        demo.start()
    }
}
