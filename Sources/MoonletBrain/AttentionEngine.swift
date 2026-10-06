import Foundation

/// Tunables for ``AttentionEngine``. Defaults follow Moonlet's design: hidden
/// until something matters, never shown mid-sentence, never lost.
public struct AttentionConfig: Sendable, Equatable {
    public var presence = PresencePolicy()
    /// How long a card stays when the user is active while it shows.
    public var hold: TimeInterval = 4
    /// How long a card for a blocked agent (a permission request or a question) stays
    /// while the user is active. Longer, because the agent can't continue without them.
    public var blockingHold: TimeInterval = 8
    /// How long a card lingers once the user returns to a card that waited for them.
    public var glance: TimeInterval = 3
    /// Longest wait for a typing pause, per kind, before a card shows anyway.
    public var typingPatience: [MomentKind: TimeInterval] = [
        .needsYou: 3, .question: 3, .failed: 8, .stuck: 10, .finished: 10,
    ]
    /// Moments of the same kind arriving this close together share one card.
    public var batchWindow: TimeInterval = 1.5
    /// Offsets from the start of a wait at which a blocked agent is mentioned again.
    public var reminderOffsets: [TimeInterval] = [120, 600, 1800]
    /// Skip the card for a finished agent whose app is already in front; flash the pointer instead.
    public var skipWhenWatching = true
    /// Projects whose finished moments go quietly to the inbox instead of a card.
    public var batchedProjects: Set<String> = []
    /// How many seen moments to keep for the summon view.
    public var historyLimit = 20

    public init() {}
}

/// A card shown at the user's pointer.
public struct Card: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// A few words: `api-refactor done`, `2 agents done`, `While you were away`.
    public var title: String
    /// One short line: an outcome, a request, or a tally.
    public var detail: String
    /// The most urgent kind on the card; drives its color.
    public var tone: MomentKind
    public var moments: [Moment]
    public var shownAt: Date
    public var isDigest: Bool
    /// When the card will leave. `nil` while it waits for the user to come back.
    public internal(set) var deadline: Date?
    /// Whether the user typed, clicked, or moved while the card showed.
    public internal(set) var sawInput: Bool
}

/// Why a card left.
public enum HideReason: Sendable, Equatable {
    /// The user clicked: an explicit "got it".
    case clicked
    /// The card stayed its time while the user was there to see it.
    case seen
    /// The agent no longer needs the user, so the card is obsolete.
    case resolved
    /// The user summoned the full view, which covers everything.
    case summoned
    /// The user left before seeing it; it returns in the welcome-back summary.
    case wentAway
    /// A call started; the card returns when the call ends.
    case callStarted
    /// More urgent news took the pointer; the card returns later unless it already had its time.
    case preempted
}

/// What the app should do in response to an engine update.
public enum AttentionEffect: Sendable, Equatable {
    case show(Card)
    case hide(Card, HideReason)
    /// Briefly tint the pointer instead of showing a card.
    case flash(MomentKind)
}

/// Decides when a moment reaches the user's pointer, how long it stays, and
/// what happens to anything the user might have missed.
///
/// The engine is a pure value type: feed it moments, presence snapshots, and
/// user actions, then apply the effects it returns. It never reads the clock.
public struct AttentionEngine: Sendable {
    /// A moment waiting to be shown.
    public struct Pending: Sendable, Equatable {
        public var moment: Moment
        /// Arrived while the user was away or on a call; eligible for the welcome-back summary.
        public var arrivedWhileAbsent: Bool
        /// When delivery first waited for a typing pause.
        var deferredSince: Date?
    }

    struct Wait: Sendable, Equatable {
        var moment: Moment
        var since: Date
        var nextReminder: Int
    }

    public var config: AttentionConfig
    /// The card at the pointer, if any.
    public private(set) var current: Card?
    /// Moments waiting for the right moment.
    public private(set) var queue: [Pending] = []
    /// Moments kept quietly for the summon view (batched projects).
    public private(set) var inbox: [Moment] = []
    /// Recently seen moments, newest first, for the summon view.
    public private(set) var history: [Moment] = []
    private var waits: [String: Wait] = [:]

    public init(config: AttentionConfig = AttentionConfig()) {
        self.config = config
    }

    /// Moments the user hasn't seen yet. Drives the dot on the menu bar moon.
    public var unseenCount: Int { queue.count + inbox.count }

    /// Agents currently blocked on the user, with the time their wait began.
    public var blockedAgents: [(agentID: String, since: Date)] {
        waits.map { ($0.key, $0.value.since) }.sorted { $0.since < $1.since }
    }

    // MARK: - Inputs

    /// A new moment from an agent.
    public mutating func receive(_ moment: Moment, presence: PresenceSnapshot, now: Date) -> [AttentionEffect] {
        let level = config.presence.level(of: presence)
        if moment.kind.isBlocking, !moment.isReminder {
            // The same unresolved request again, such as the notification Claude Code sends
            // after a permission request: the user has been told already.
            if waits[moment.agentID] != nil { return [] }
            waits[moment.agentID] = Wait(moment: moment, since: moment.createdAt, nextReminder: 0)
        }
        // Only the latest news from an agent matters.
        queue.removeAll { $0.moment.agentID == moment.agentID }

        if moment.kind == .finished, config.skipWhenWatching, level == .active, !presence.inCall,
           let host = moment.hostBundleID, host == presence.frontmostBundleID {
            remember([moment])
            return [.flash(.finished)]
        }
        if moment.kind == .finished, config.batchedProjects.contains(moment.project) {
            inbox.removeAll { $0.agentID == moment.agentID }
            inbox.append(moment)
            return []
        }
        queue.append(Pending(moment: moment, arrivedWhileAbsent: level == .away || presence.inCall))
        return deliver(presence, now)
    }

    /// The agent is no longer blocked or stuck: it got an answer, moved on, or ended.
    public mutating func resolve(agentID: String, now: Date) -> [AttentionEffect] {
        waits[agentID] = nil
        let obsolete: (Moment) -> Bool = { $0.agentID == agentID && ($0.kind.isBlocking || $0.kind == .stuck) }
        queue.removeAll { obsolete($0.moment) }
        guard var card = current, card.moments.contains(where: obsolete) else { return [] }
        card.moments.removeAll(where: obsolete)
        guard card.moments.isEmpty else {
            current = card
            return []
        }
        current = nil
        return [.hide(card, .resolved)]
    }

    /// The user clicked anywhere: the visible card counts as seen.
    public mutating func click(now: Date) -> [AttentionEffect] {
        guard let card = current else { return [] }
        current = nil
        remember(card.moments)
        return [.hide(card, .clicked)]
    }

    /// The user summoned the full view, which shows everything; nothing stays unseen.
    public mutating func summoned(now: Date) -> [AttentionEffect] {
        var effects: [AttentionEffect] = []
        if let card = current {
            current = nil
            remember(card.moments)
            effects.append(.hide(card, .summoned))
        }
        remember(queue.map(\.moment) + inbox)
        queue.removeAll()
        inbox.removeAll()
        return effects
    }

    /// Advance time. Call a few times per second with fresh presence.
    public mutating func tick(presence: PresenceSnapshot, now: Date) -> [AttentionEffect] {
        var effects = updateCurrent(presence, now)
        scheduleReminders(presence, now)
        effects += deliver(presence, now)
        return effects
    }

    // MARK: - Card lifecycle

    private mutating func updateCurrent(_ presence: PresenceSnapshot, _ now: Date) -> [AttentionEffect] {
        guard var card = current else { return [] }
        if presence.inCall {
            current = nil
            requeue(card)
            return [.hide(card, .callStarted)]
        }
        if config.presence.level(of: presence) == .away {
            current = nil
            requeue(card)
            return [.hide(card, .wentAway)]
        }
        let inputSinceShown = presence.secondsSinceInput < now.timeIntervalSince(card.shownAt)
        if inputSinceShown, !card.sawInput {
            card.sawInput = true
            // A card that waited for the user leaves shortly after they come back.
            if card.deadline == nil { card.deadline = now.addingTimeInterval(config.glance) }
        }
        if let deadline = card.deadline, now >= deadline {
            if card.sawInput {
                current = nil
                remember(card.moments)
                return [.hide(card, .seen)]
            }
            // Nobody touched anything while it showed: keep waiting for them.
            card.deadline = nil
        }
        current = card
        return []
    }

    private mutating func scheduleReminders(_ presence: PresenceSnapshot, _ now: Date) {
        for agentID in waits.keys.sorted() {
            guard var wait = waits[agentID], wait.nextReminder < config.reminderOffsets.count else { continue }
            guard now >= wait.since.addingTimeInterval(config.reminderOffsets[wait.nextReminder]) else { continue }
            wait.nextReminder += 1
            waits[agentID] = wait
            let alreadyShowing = current?.moments.contains { $0.agentID == agentID } == true
                || queue.contains { $0.moment.agentID == agentID }
            guard !alreadyShowing else { continue }
            let minutes = max(1, Int(now.timeIntervalSince(wait.since) / 60))
            var reminder = wait.moment
            reminder.id = UUID()
            reminder.isReminder = true
            reminder.createdAt = now
            reminder.detail = "Waiting \(minutes) min · \(wait.moment.detail)"
            let absent = config.presence.level(of: presence) == .away || presence.inCall
            queue.append(Pending(moment: reminder, arrivedWhileAbsent: absent))
        }
    }

    private mutating func deliver(_ presence: PresenceSnapshot, _ now: Date) -> [AttentionEffect] {
        guard !queue.isEmpty, !presence.inCall else { return [] }
        let level = config.presence.level(of: presence)
        guard level != .away else { return [] }
        queue.sort { ($0.moment.kind.priority, $0.moment.createdAt) < ($1.moment.kind.priority, $1.moment.createdAt) }

        // Urgent news doesn't wait behind good news: a failure or a request takes the
        // pointer from a less urgent card. A card that already had its time counts as seen.
        if config.presence.isTyping(presence) {
            let since = queue[0].deferredSince ?? now
            queue[0].deferredSince = since
            let patience = config.typingPatience[queue[0].moment.kind] ?? 10
            if now.timeIntervalSince(since) < patience { return [] }
        }

        var effects: [AttentionEffect] = []
        if let card = current {
            guard queue[0].moment.kind.priority < card.tone.priority else { return [] }
            current = nil
            if now.timeIntervalSince(card.shownAt) >= config.hold {
                remember(card.moments)
            } else {
                for moment in card.moments where !queue.contains(where: { $0.moment.agentID == moment.agentID }) {
                    queue.append(Pending(moment: moment, arrivedWhileAbsent: false))
                }
            }
            effects.append(.hide(card, .preempted))
        }

        var card: Card
        let absent = queue.filter(\.arrivedWhileAbsent)
        if absent.count > 1 {
            queue.removeAll(where: \.arrivedWhileAbsent)
            card = Self.summaryCard(absent.map(\.moment), now: now)
        } else {
            let head = queue.removeFirst()
            var group = [head.moment]
            queue.removeAll { pending in
                let sameBurst = pending.moment.kind == head.moment.kind
                    && abs(pending.moment.createdAt.timeIntervalSince(head.moment.createdAt)) <= config.batchWindow
                if sameBurst { group.append(pending.moment) }
                return sameBurst
            }
            card = Self.card(for: group, now: now)
        }
        let hold = card.tone.isBlocking ? config.blockingHold : config.hold
        card.deadline = level == .active ? now.addingTimeInterval(hold) : nil
        current = card
        return effects + [.show(card)]
    }

    private mutating func requeue(_ card: Card) {
        for moment in card.moments where !queue.contains(where: { $0.moment.agentID == moment.agentID }) {
            queue.append(Pending(moment: moment, arrivedWhileAbsent: true))
        }
    }

    private mutating func remember(_ moments: [Moment]) {
        history.insert(contentsOf: moments.sorted { $0.createdAt > $1.createdAt }, at: 0)
        if history.count > config.historyLimit { history.removeLast(history.count - config.historyLimit) }
    }

    // MARK: - Card text

    static func card(for moments: [Moment], now: Date) -> Card {
        let first = moments[0]
        let title: String
        let detail: String
        if moments.count == 1 {
            title = "\(first.agentLabel) \(Self.verb(first))"
            detail = first.detail
        } else {
            title = "\(moments.count) agents \(Self.pluralVerb(first.kind))"
            detail = moments.map(\.agentLabel).joined(separator: ", ")
        }
        return Card(id: UUID(), title: title, detail: detail, tone: first.kind, moments: moments,
                    shownAt: now, isDigest: false, deadline: nil, sawInput: false)
    }

    static func summaryCard(_ moments: [Moment], now: Date) -> Card {
        let order: [MomentKind] = [.needsYou, .question, .failed, .stuck, .finished]
        let parts = order.compactMap { kind -> String? in
            let count = moments.filter { $0.kind == kind }.count
            guard count > 0 else { return nil }
            switch kind {
            case .needsYou: return "\(count) need\(count == 1 ? "s" : "") you"
            case .question: return "\(count) asked you something"
            case .failed: return "\(count) failed"
            case .stuck: return "\(count) seem\(count == 1 ? "s" : "") stuck"
            case .finished: return "\(count) done"
            }
        }
        let tone = moments.map(\.kind).min { $0.priority < $1.priority } ?? .finished
        return Card(id: UUID(), title: "While you were away", detail: parts.joined(separator: " · "), tone: tone,
                    moments: moments, shownAt: now, isDigest: true, deadline: nil, sawInput: false)
    }

    static func verb(_ moment: Moment) -> String {
        switch moment.kind {
        case .needsYou: moment.isReminder ? "still needs you" : "needs you"
        case .question: "has a question"
        case .failed: "failed"
        case .stuck: "seems stuck"
        case .finished: "done"
        }
    }

    static func pluralVerb(_ kind: MomentKind) -> String {
        switch kind {
        case .needsYou: "need you"
        case .question: "have questions"
        case .failed: "failed"
        case .stuck: "seem stuck"
        case .finished: "done"
        }
    }
}
