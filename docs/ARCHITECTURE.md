# Architecture

Moonlet is one Swift package with five libraries, one command-line tool, and one app.

```
            ┌───────────────── producers ─────────────────┐
            │ Claude Code hooks  Codex hooks/notify  scripts │
            └───────┬────────────────┬─────────────────┬────┘
                    ▼                ▼                 ▼
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
| `MoonletAdapters` | Claude Code and Codex hook payloads, and Codex notify payloads, to events; the ledger that keeps Codex turns from being reported twice | Core |
| `MoonletSetup` | Installers for Claude Code (`settings.json`) and Codex (`hooks.json`, or `notify` in `config.toml`) that preserve key order and comments | Core |
| `MoonletBrain` | Attention rules, presence policy, gestures, pointer policy, the companion's mood reading, question and stuck detection, learning, summary parsing | Foundation, CoreGraphics |
| `moonlet` | The command: hooks, `emit`, `status`, `summon`, `demo`, `install`, `doctor` | All libraries except Brain |
| `MoonletApp` | The menu bar app: sensing, pointer skin, the companion (art, behaviors, director), cards, summon view, local model client | Core, IPC, Brain, Setup (to read whether Codex is connected) |

Everything that decides *what happens* lives in value types with no clock and no I/O (`AgentStore`, `AttentionEngine`, `PointerPolicy`, `GestureRecognizer`, `CompanionMood`, `StuckDetector`, `EngagementTracker`), so it's covered by fast unit tests. The app layer only senses, renders, and wires.

The companion is drawn with Core Graphics from a `CompanionPose` (face, look, arms, props), so the same art serves the live companion, the summon view, the docs images, and the demo film. `CompanionDirector` owns the animation and places the card: a 60 Hz timer while a card or the companion is out and none otherwise. With the companion turned off, cards ride with the pointer exactly as they did before the companion existed.

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

- **Interception.** Moonlet's click-through windows should never receive an event. If the skin, companion, or card window gets a click or scroll, the skin turns itself off. The one exception is a parked request card, which takes a click on purpose, to open the agent, but only on its visible box, only once the pointer has rested there for about 0.15 s, and never within 0.3 s of a scroll; a scroll that still lands on it makes it click-through at once. An event counts as intended only if it was made while the card took input (its timestamp, on the same clock as `systemUptime`, is compared with when the card last went click-through), so a click queued behind a slow jump never turns the skin off. The companion's own window is always click-through.
- **Delivery.** Every hardware click and scroll (from `CGEventSource`) should reach some app, which Moonlet sees through its global and local event monitors. Two undelivered presses within 15 seconds turn the skin off.

Either way the reason appears in the menu and in `~/Library/Logs/Moonlet/app.log`, which also records once a minute how many presses reached apps while the pointer showed.

## Hooks

`moonlet hook claude-code` and `moonlet hook codex` read the hook payload from standard input, write nothing to standard output, and always exit 0. Claude Code and Codex therefore treat them as pure observers: they can't block a tool, change a permission decision, or add context. Each hook has a 5-second timeout in the agent's config, and a typical run takes well under that, since the command only parses JSON and writes one line to a socket.

`moonlet hook codex` with arguments is Codex's older `notify` program instead. Codex runs it after the `Stop` hooks of the same turn, so the `Stop` hook writes the finished turn to `CodexHookLedger` (`codex-hooks/` in the support directory), and the notify call skips a turn that's already there. Sessions whose hooks don't run keep reporting through notify.

## Testing

```bash
swift test                      # every module
swift test --filter Brain       # the attention rules alone
MOONLET_HOME=/tmp/mlt swift run moonlet demo   # drive a running app over the socket
```

Integration fixtures under `Tests/MoonletAdaptersTests/Fixtures` are synthetic. Never commit real transcripts or hook payloads.
