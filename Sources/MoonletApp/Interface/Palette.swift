import AppKit
import MoonletBrain
import SwiftUI

/// Moonlet's colors. The pointer, cards, moons, and the menu bar dot share them,
/// so a color always means the same thing: blue tells you something, yellow asks
/// you something, red warns you, and gray is quiet work.
enum Palette {
    /// An agent is telling you something, such as a finished task.
    static let info = NSColor(srgbRed: 94 / 255, green: 192 / 255, blue: 232 / 255, alpha: 1)
    /// An agent is asking you something and waits for the answer.
    static let needsYou = NSColor(srgbRed: 255 / 255, green: 197 / 255, blue: 61 / 255, alpha: 1)
    /// An agent failed or seems stuck.
    static let problem = NSColor(srgbRed: 255 / 255, green: 69 / 255, blue: 58 / 255, alpha: 1)
    /// An agent is working and has nothing to say.
    static let working = NSColor.secondaryLabelColor
    static let idle = NSColor.tertiaryLabelColor

    static func color(for kind: MomentKind) -> NSColor {
        switch kind {
        case .needsYou, .question: needsYou
        case .failed, .stuck: problem
        case .finished: info
        }
    }

    static func color(for activity: AgentActivity) -> NSColor {
        switch activity {
        case .working: working
        case .waiting: needsYou
        case .done: info
        case .failed: problem
        case .idle: idle
        }
    }
}

extension Color {
    init(_ kind: MomentKind) { self.init(nsColor: Palette.color(for: kind)) }
    init(_ activity: AgentActivity) { self.init(nsColor: Palette.color(for: activity)) }
}
