# Architecture

Moonlet is one Swift package with five libraries, one command-line tool, and one app.

```
            ┌──────────────── producers ────────────────┐
            │ Claude Code hooks   Codex notify   scripts │
            └───────┬───────────────┬──────────────┬─────┘
                    ▼               ▼              ▼
              moonlet hook claude-code │ hook codex │ emit        (Sources/moonlet)
                    │  MoonletAdapters: payload → MoonletEvent
                    ▼
     ~/Library/Application Support/Moonlet/moonlet.sock         (MoonletIPC)
                    │  (spool.jsonl when the app isn't running)
                    ▼
   Moonlet.app ─ AppModel ──────────────────────────────────── (Sources/MoonletApp)
        │  AgentStore          events → agents + signals        (MoonletCore)
        │  LocalModel          final message → a few words      (Ollama on localhost)
        │  AttentionEngine     signals + presence → card effects (MoonletBrain)
        │  PointerPolicy       who's talking → pointer tint      (MoonletBrain)
        │  GestureRecognizer   pointer samples → summon          (MoonletBrain)
        │  CompanionMood       a card's kind and words → a mood  (MoonletBrain)
        │  CompanionDirector   cards → the companion's performance, card placement
        ▼
   CompanionPanel · CardPanel · PointerSkin · SummonPanel · StatusMoon
```

## Modules

| Module | Role | Depends on |
| --- | --- | --- |
| `MoonletCore` | Wire protocol (`MoonletEvent`, `Envelope`), `Agent`, and `AgentStore`, which turns events into agents and signals | Foundation |
| `MoonletIPC` | Unix-socket server and client, the spool, and paths | Core |
| `MoonletAdapters` | Claude Code hook payloads and Codex notify payloads to events | Core |
| `MoonletSetup` | Installers for Claude Code and Codex that preserve key order and comments | Core |
| `MoonletBrain` | Attention rules, presence policy, gestures, pointer policy, the companion's mood reading, question and stuck detection, learning, summary parsing | Foundation, CoreGraphics |
| `moonlet` | The command: hooks, `emit`, `status`, `summon`, `demo`, `install`, `doctor` | All libraries except Brain |
| `MoonletApp` | The menu bar app: sensing, pointer skin, the companion (art, behaviors, director), cards, summon view, local model client | Core, IPC, Brain |

Everything that decides *what happens* lives in value types with no clock and no I/O (`AgentStore`, `AttentionEngine`, `PointerPolicy`, `GestureRecognizer`, `CompanionMood`, `StuckDetector`, `EngagementTracker`), so it's covered by fast unit tests. The app layer only senses, renders, and wires.

The companion is drawn with Core Graphics from a `CompanionPose` (face, look, arms, props), so the same art serves the live companion, the summon view, the docs images, and the demo film. `CompanionDirector` owns the animation: a 60 Hz timer while the companion is out and none otherwise.

## Threading

- `AppModel` and all interface types are `@MainActor`.
- `MoonletServer` reads sockets on its own queue and calls async handlers, which hop to the main actor.
- `LocalModel` is an actor; summaries are written off the main thread, and the resulting moment is delivered on the main actor.
- `PointerGuardian` runs a 100 ms watchdog on a background queue and shows the real pointer if the main thread stops beating for 350 ms.

## Private API

The pointer skin uses two private window-server calls, resolved at runtime with `dlsym`:

| Call | Purpose | If missing |
| --- | --- | --- |
| `CGSSetConnectionProperty(…, "SetsCursorInBackground", true)` | Lets a background app hide the arrow | The skin turns itself off |
| `CGSCopyRegisteredCursorImages(…, "com.apple.coregraphics.Arrow", …)` | Reads the arrow's size and hotspot, which follow the user's pointer-size setting | Defaults to a 40-point arrow |

Hiding and showing go through the public `CGDisplayHideCursor` and `CGDisplayShowCursor`. The drawn pointer's window sits at the assistive-technology overlay level, never at the cursor level: that level lies above the screen-shield band (`CGShieldingWindowLevel`), where a window can capture clicks and scrolls even when it ignores mouse events. A hidden pointer belongs to Moonlet's window-server connection, so macOS shows it again if Moonlet exits for any reason. (`CGSRegisterCursorWithImages`, which apps such as Mousecape used to replace the arrow image itself, still returns success on macOS 26 but has no effect.)

## Input safety

The pointer skin must never get between the user and their apps. `AppModel` checks two things while it draws:

- **Interception.** Moonlet's click-through windows should never receive an event. If the skin, companion, or card window gets a click or scroll, the skin turns itself off. The one exception is a request card while it's parked: it takes clicks on purpose, to open the agent, and goes back to click-through as soon as it leaves.
- **Delivery.** Every hardware click and scroll (from `CGEventSource`) should reach some app, which Moonlet sees through its global and local event monitors. Two undelivered presses within 15 seconds turn the skin off.

Either way the reason appears in the menu and in `~/Library/Logs/Moonlet/app.log`, which also records once a minute how many presses reached apps while the pointer showed.

## Hooks

`moonlet hook claude-code` reads the hook payload from standard input, writes nothing to standard output, and always exits 0. Claude Code therefore treats it as a pure observer: it can't block a tool, change a permission decision, or add context. Each hook has a 5-second timeout in the settings file, and a typical run takes well under that, since the command only parses JSON and writes one line to a socket.

## Testing

```bash
swift test                      # every module
swift test --filter Brain       # the attention rules alone
MOONLET_HOME=/tmp/mlt swift run moonlet demo   # drive a running app over the socket
```

Integration fixtures under `Tests/MoonletAdaptersTests/Fixtures` are synthetic. Never commit real transcripts or hook payloads.
