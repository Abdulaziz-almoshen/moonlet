import Foundation
import MoonletBrain

/// The user's choices, kept in `UserDefaults`. Every option has a default
/// that works without opening settings.
@MainActor
final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Give the pointer Moonlet's look while agents work.
    var pointerSkin: Bool {
        get { bool("pointerSkin", default: true) }
        set { defaults.set(newValue, forKey: "pointerSkin") }
    }

    /// Show the companion, a tiny moon that brings each card and reacts to what it says.
    var companion: Bool {
        get { bool("companion", default: true) }
        set { defaults.set(newValue, forKey: "companion") }
    }

    /// Seconds a card stays while the user is active.
    var holdSeconds: Double {
        get { defaults.object(forKey: "holdSeconds") as? Double ?? 4 }
        set { defaults.set(newValue, forKey: "holdSeconds") }
    }

    var summonWithCircle: Bool {
        get { bool("summonWithCircle", default: true) }
        set { defaults.set(newValue, forKey: "summonWithCircle") }
    }

    /// Hold cards while the camera is on or the microphone is in long use.
    var holdDuringCalls: Bool {
        get { bool("holdDuringCalls", default: true) }
        set { defaults.set(newValue, forKey: "holdDuringCalls") }
    }

    /// Flash the pointer instead of showing a card for a quick task in the app in front.
    var skipWhenWatching: Bool {
        get { bool("skipWhenWatching", default: true) }
        set { defaults.set(newValue, forKey: "skipWhenWatching") }
    }

    /// Ollama model for summaries: `nil` picks one automatically.
    var summaryModel: String? {
        get { defaults.string(forKey: "summaryModel") }
        set { defaults.set(newValue, forKey: "summaryModel") }
    }

    /// Use a local model for summaries at all.
    var localSummaries: Bool {
        get { bool("localSummaries", default: true) }
        set { defaults.set(newValue, forKey: "localSummaries") }
    }

    /// Notice which projects the user always skips and offer to collect them quietly.
    var learns: Bool {
        get { bool("learns", default: true) }
        set { defaults.set(newValue, forKey: "learns") }
    }

    var batchedProjects: Set<String> {
        get { Set(defaults.stringArray(forKey: "batchedProjects") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "batchedProjects") }
    }

    var engagement: EngagementTracker {
        get {
            guard let data = defaults.data(forKey: "engagement"),
                  let tracker = try? JSONDecoder().decode(EngagementTracker.self, from: data) else { return EngagementTracker() }
            return tracker
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "engagement") }
    }

    /// Cards left that fly to the menu bar moon before they simply fade.
    var homeFlightsLeft: Int {
        get { defaults.object(forKey: "homeFlightsLeft") as? Int ?? 3 }
        set { defaults.set(newValue, forKey: "homeFlightsLeft") }
    }

    /// The attention rules these settings imply.
    var attentionConfig: AttentionConfig {
        var config = AttentionConfig()
        config.hold = holdSeconds
        config.skipWhenWatching = skipWhenWatching
        config.batchedProjects = batchedProjects
        return config
    }

    var gestureConfig: GestureRecognizer.Config {
        var config = GestureRecognizer.Config()
        config.circleEnabled = summonWithCircle
        return config
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}
