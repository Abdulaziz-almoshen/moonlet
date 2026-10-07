# Security

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **Report a vulnerability** button on the repository's Security tab. We aim to reply within a week and will credit you in the release notes unless you'd rather we didn't.

## What Moonlet protects

- **The local socket** lives in `~/Library/Application Support/Moonlet` (mode `0700`), and the socket itself is mode `0600`, so only your user account can send events or read status. Moonlet listens on no network port.
- **Hooks are observers.** `moonlet hook …` never writes to standard output and always exits 0, so a compromised or buggy Moonlet can't approve a tool call, block one, or inject text into an agent's context.
- **No data leaves your Mac.** The only network connection is to Ollama on `127.0.0.1`, and only when local summaries are on. There's no telemetry.
- **Config edits are reversible.** Installers preview every change, keep a timestamped backup next to each file, and touch only Moonlet's own entries. Codex asks you to trust new hooks before it runs them; Moonlet never trusts them for you.

## What Moonlet reads

Input timing (never key contents), the frontmost app, whether a camera or microphone is in use (never the audio or video), pointer movement, and agent hook payloads. Agent payloads can include prompts and final messages. Moonlet keeps them in memory for display and summaries, never writes them to disk except the short-lived spool used while the app isn't running, and never sends them anywhere except your local Ollama. For Codex sessions it also keeps each session's id and last finished turn id, and nothing else, for a week, so that a turn isn't reported twice.

## Private API

The pointer skin relies on two undocumented window-server calls (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). They can only hide or show the pointer. If either is missing, the skin turns itself off.
