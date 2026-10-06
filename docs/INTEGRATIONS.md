# Integrations

## Claude Code

```bash
moonlet install claude-code --dry-run   # preview
moonlet install claude-code             # apply, with a backup next to the file
moonlet uninstall claude-code           # remove only Moonlet's hooks
```

Moonlet adds one hook group per event to `~/.claude/settings.json`, running `moonlet hook claude-code` with a 5-second timeout. Your other hooks and settings stay as they were, in the same order. Events newer than your Claude Code version are skipped, because older versions can reject settings that mention events they don't know.

| Hook event | What Moonlet records |
| --- | --- |
| `SessionStart` | The session appears as idle, labeled after its folder. A restart after compaction keeps the state. |
| `UserPromptSubmit` | Working; the first line of your prompt becomes the title. Prompts Claude Code writes itself are ignored. |
| `PreToolUse` | Working, with a short activity such as `Editing orders.ts`. `AskUserQuestion` and `ExitPlanMode` mean the agent is waiting on you, with the question and its options or the plan's title. |
| `PermissionRequest` (2.0.45+) | Waiting, with what the agent wants to do: `Wants to run npm install`, `Wants to edit Orders.swift`, `Wants to open example.com`. |
| `PostToolUse` | Working; task-list progress from `TodoWrite`, `TaskCreate`, and `TaskUpdate`; milestones for `git commit`, `git push`, and `gh pr create`. |
| `Notification` | Waiting, for permission prompts and input dialogs. A permission notification keeps the more specific message from `PermissionRequest`. Idle reminders are ignored. |
| `Stop` | Done, with the final message read from the transcript's last 512 KiB. |
| `StopFailure` (2.1.78+) | Failed, with the reason: rate limit, overload, authentication, and so on. |
| `SessionEnd` | The session is over. |

The hook is a pure observer: it writes nothing to standard output and always exits 0, so it can't approve, block, or alter anything Claude Code does.

Every Claude Code session that reads `~/.claude/settings.json` reports, wherever it runs. Sessions that were already open pick up the hooks the next time they start.

## Codex CLI

```bash
moonlet install codex --dry-run
moonlet install codex
moonlet uninstall codex
```

Codex runs one `notify` program after each turn. Moonlet sets the top-level `notify` in `~/.codex/config.toml`. If you already have one, Moonlet chains it rather than replacing it:

```toml
# before
notify = ["/Applications/Some Tool.app/Contents/MacOS/client", "turn-ended"]
# after
notify = ["/Users/me/.local/bin/moonlet", "hook", "codex", "--then", "/Applications/Some Tool.app/Contents/MacOS/client", "turn-ended"]
```

`moonlet hook codex` records the turn, then starts the original program with its original arguments plus Codex's payload, exactly as Codex would have. Uninstalling restores the original line.

Codex reports finished turns only, so its agents appear when a turn ends: done, with the final message, the first prompt as the title, and the session's folder as the label.

## Anything else

```bash
moonlet emit --session SESSION [--source NAME] [--label LABEL] [--state idle|working|waiting|done|failed] \
             [--title TEXT] [--activity TEXT] [--summary TEXT] [--message TEXT] [--milestone TEXT] \
             [--progress DONE/TOTAL] [--end]
```

- A long job: `--state working` at the start, `--state done --summary "…"` at the end.
- A blocked job: `--state waiting --message "Approve the deploy"`, then `--state working` once it continues.
- A failure: `--state failed --message "…"`.

For other languages, write one line of JSON to the socket; see [PROTOCOL.md](PROTOCOL.md).

## Checking your setup

```bash
moonlet doctor
```

It checks that the app is reachable, that Claude Code's hooks and Codex's `notify` are in place, and whether Ollama is reachable for summaries.
