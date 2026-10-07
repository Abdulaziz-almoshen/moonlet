import Foundation

/// Synthetic payloads in `Fixtures/`, shaped like what Claude Code and Codex send.
enum Fixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Missing fixture \(name)" }
    }

    static func data(_ name: String, in directory: String = "claude-code") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/\(directory)")
        else { throw Missing(name: "\(directory)/\(name)") }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, in directory: String = "claude-code") throws -> String {
        String(decoding: try data(name, in: directory), as: UTF8.self)
    }

    /// A Claude Code payload with the common fields filled in.
    static func claudePayload(_ hookEvent: String, _ fields: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = [
            "session_id": "4f6c9a2e-7b1d-4c3e-9f0a-1d2e3f4a5b6c",
            "transcript_path": "/Users/example/.claude/projects/example/session.jsonl",
            "cwd": "/Users/example/code/payments",
            "hook_event_name": hookEvent,
        ]
        payload.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// The root session id in the Codex fixtures.
    static let codexSession = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"

    /// A Codex hook payload with the common fields of a turn event filled in.
    static func codexPayload(_ hookEvent: String, _ fields: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = [
            "session_id": codexSession,
            "turn_id": "7",
            "transcript_path": NSNull(),
            "cwd": "/Users/example/code/payments",
            "hook_event_name": hookEvent,
            "model": "gpt-5-codex",
            "permission_mode": "default",
        ]
        payload.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
