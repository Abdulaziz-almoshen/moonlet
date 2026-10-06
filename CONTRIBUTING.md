# Contributing to Moonlet

Thanks for helping. Moonlet's promise is to stay out of the way until it matters, so every change is judged by one question: does it make the user's day calmer?

## Set up

You need macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/Abdulaziz-almoshen/moonlet.git
cd moonlet
swift build
swift test
make demo        # the app from source, playing the demo scenario
```

Useful while developing:

```bash
MOONLET_DEBUG=1 swift run MoonletApp            # log every decision to the terminal
swift run MoonletApp --render-docs docs/images  # regenerate the README images
scripts/make-demo.sh                            # regenerate the demo film (needs ffmpeg)
```

To try your build with real agents without touching your installed copy, give it its own support directory:

```bash
MOONLET_HOME=/tmp/mlt swift run MoonletApp
MOONLET_HOME=/tmp/mlt swift run moonlet demo
```

## Where things live

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. In short: decisions go in `MoonletBrain` or `MoonletCore` as plain value types with tests; `MoonletApp` only senses, renders, and wires.

## Changing behavior

The attention rules in [docs/DESIGN.md](docs/DESIGN.md) are part of the product. If you change a threshold or a rule, update that document and the tests in `Tests/MoonletBrainTests` in the same pull request, and explain the user-visible effect.

## Adding an agent

1. Add an adapter in `Sources/MoonletAdapters` that turns the agent's payload into `MoonletEvent`s.
2. Add synthetic fixtures and tests. Never commit real transcripts, prompts, or file paths.
3. Add an installer in `Sources/MoonletSetup` if the agent has a config file, with dry-run, backup, and an uninstall that restores the original exactly.
4. Document it in [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

## Style

- Swift 6 language mode, strict concurrency, no warnings.
- Short doc comments on every type and on anything non-obvious.
- No third-party dependencies without discussion.
- Interface copy is sentence case, short, and never says "please" or "successfully".

## Pull requests

- One topic per pull request, with tests.
- `swift build` and `swift test` pass locally; CI runs both.
- Describe what changes for the user, with a screenshot or recording for anything visual.

## Reporting bugs

Open an issue with your macOS version, how you run your agents, and `moonlet doctor` output. For security problems, follow [SECURITY.md](SECURITY.md) instead.
