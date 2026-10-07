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

## Codex

```bash
moonlet install codex --dry-run
moonlet install codex
moonlet uninstall codex
```

With Codex 0.153 or later, Moonlet adds one hook group per event to `~/.codex/hooks.json` (in `$CODEX_HOME` if you set it), running `moonlet hook codex` with a 5-second timeout, or 2 seconds for `Interrupt` and `SessionEnd`, which Codex caps at 3. Moonlet's groups go after any hooks already in the file, so those keep their place and their trust. If Moonlet created the file, uninstalling deletes it again.

**Trust.** Codex runs a new or changed hook only after you trust it. The next time Codex starts, it asks you to review the new hooks; or type `/hooks` and press `t`. Moonlet never trusts hooks for you. Moving the `moonlet` command changes the hooks, so Codex asks again. Codex knows each hook by its place in the file, so if your own hooks follow Moonlet's group for an event, uninstalling moves them up and Codex asks about them again; the uninstall names those events.

`moonlet doctor` counts the hooks as trusted only when Codex has a trust record for each and a hook reported after `hooks.json` last changed. If the file changed since, it warns that Codex may ask you to trust Moonlet's hooks again: open `/hooks` in Codex.

| Hook event | What Moonlet records |
| --- | --- |
| `SessionStart` | The session appears as idle, labeled after its folder. Codex sends it with the first prompt, not when it opens. A restart after compaction keeps the state. |
| `UserPromptSubmit` | Working; the first line of your prompt becomes the title. A subagent's prompt doesn't change it. |
| `PreToolUse` | Working, with a short activity such as `Running swift test` or `Editing Orders.swift`; `update_plan` steps become task progress. `request_user_input` means the agent is waiting on you, with its question and options. |
| `PermissionRequest` | Waiting, with what the agent wants to do: `Wants to run npm install`, `Wants to edit Orders.swift`, `Wants to delete Legacy.swift`, `Wants network access to registry.npmjs.org`. A subagent's request counts too. With automatic approval review, still working: `Reviewing: run npm install`. |
| `PostToolUse` | Working; task-list progress from `update_plan`; milestones for `git commit`, `git push`, and `gh pr create` when the output shows they worked. |
| `Stop` | Done, with Codex's final message. |
| `Interrupt` | Idle again: you stopped the turn. |
| `SessionEnd` | The session is over. |

The hook is a pure observer, like Claude Code's: it writes nothing to standard output or standard error and always exits 0, so it can't approve, block, or add to anything Codex does. It runs synchronously, so events arrive in order, and returns in a few hundredths of a second, so the Codex TUI doesn't show it; `codex exec` does list each run, as a `hook: <Event>` line. Hooks in `~/.codex` also run for Codex sessions in the desktop app and editors that share that folder.

Codex 0.153 and 0.154 run hooks without detaching them from the terminal (0.155 does). If a shell startup file that a hook's shell reads (`~/.zshenv`, or `$BASH_ENV` when your shell is bash) runs `stty`, `tput`, `tty -s`, or `read -t` outside an interactive-only check, the system can stop the hook until Codex's timeout ends it. `moonlet doctor` warns about that; it only reads those files.

Codex 0.154 sends a shell command's output without its exit code, so a milestone needs the output to show the step went through: git's `[branch 3f2a1b9] message` line for a commit; a ref update (`1a2b3c4..5d6e7f8  main -> main`, `* [new branch]`, or a forced `+`), `Everything up-to-date`, or `set up to track` for a push; a `/pull/<number>` URL for `gh pr create`. Output with `error:`, `fatal:`, or `! [rejected]` never counts. When the output starts with an exit code header, the code decides.

Codex has no hook for a turn that ends in an error, so such a session stays working until its next event; after 10 minutes Moonlet says it seems stuck. With automatic approval review turned on (`approvals_reviewer = "auto_review"`), Codex sends `PermissionRequest` before its reviewer decides. Moonlet reads the session's latest turn settings from the end of its transcript (at most 256 KiB) and, when the reviewer answers, keeps the agent working with `Reviewing: …` instead of asking you. If the transcript can't be read, the request waits on you as usual.

### Older Codex: notify

Before Codex 0.153, or when Moonlet can't find `codex` to check its version and no hooks are installed, Moonlet uses Codex's `notify` program, which runs once after each turn. Moonlet sets the top-level `notify` in `~/.codex/config.toml`. If you already have one, Moonlet chains it rather than replacing it:

```toml
# before
notify = ["/Applications/Some Tool.app/Contents/MacOS/client", "turn-ended"]
# after
notify = ["/Users/me/.local/bin/moonlet", "hook", "codex", "--then", "/Applications/Some Tool.app/Contents/MacOS/client", "turn-ended"]
```

`moonlet hook codex` records the turn, then starts the original program with its original arguments plus Codex's payload, exactly as Codex would have. Uninstalling restores the original line. Another app's notifier that already runs Moonlet stays as it is, and the install says so. Notify reports finished turns only, so agents appear when a turn ends: done, with the final message, the first prompt as the title, and the session's folder as the label.

### Hooks and notify together

Installing hooks never adds Moonlet to `notify`. A notify setting that already runs Moonlet, directly or inside another app's notifier (one that keeps the previous command in an argument such as `--previous-notify`), stays as a fallback: until you trust the hooks, it still reports finished turns. Once the hooks run, they report each turn first, and `moonlet hook codex` skips the notify call for that turn, so nothing shows up twice. To tell the two apart, Moonlet keeps a tiny note per session in `~/Library/Application Support/Moonlet/codex-hooks/`, and removes notes untouched for a week.

`moonlet uninstall codex` removes Moonlet's hooks and its own notify chain. It never edits another app's notifier; when one still runs Moonlet, it names the app and says which command to take out of its `notify` line.

`moonlet hook codex` serves both callers: with no arguments it's the hook and reads its payload from standard input; with arguments it's the notify program, and the payload is the last argument, after an optional `--then <command…>`.

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

It checks that the app is reachable, that Claude Code's hooks are in place, that Codex's hooks are installed and trusted (or, on older Codex versions, that `notify` runs Moonlet, even inside another app's notifier), and whether Ollama is reachable for summaries. Lines marked `!` are warnings, such as hooks Codex may ask you to trust again, or a shell startup file that can stall hooks on Codex 0.153 and 0.154; only `✗` lines fail the check.
