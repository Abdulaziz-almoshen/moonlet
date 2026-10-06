# Wire protocol, version 1

Anything can report to Moonlet: a hook, a script, a CI job, or your own agent. This page describes the format so you can write a producer in any language. The `moonlet` command is the reference client.

## Transport

- A Unix domain stream socket at `~/Library/Application Support/Moonlet/moonlet.sock`, or `$MOONLET_HOME/moonlet.sock` when `MOONLET_HOME` is set.
- The directory has mode `0700` and the socket mode `0600`, so only the current user can connect. There's no network listener.
- One JSON object per line, UTF-8, terminated by `\n`. Lines longer than 64 KiB, excluding the newline, are dropped.
- When the app isn't running, `moonlet` appends events to `spool.jsonl` in the same directory (bounded to 256 KiB, newest kept). The app replays the spool at launch.

## Envelopes

| Line | Reply | Meaning |
| --- | --- | --- |
| `{"type":"event","event":{…}}` | None | Report about one agent session |
| `{"type":"status"}` | `{"type":"status","agents":[…]}` | Every agent the app tracks |
| `{"type":"summon"}` | None | Open the summon view at the pointer |

## Events

```json
{
  "type": "event",
  "event": {
    "v": 1,
    "kind": "update",
    "source": "my-agent",
    "session": "run-42",
    "label": "nightly-eval",
    "state": "working",
    "title": "Score the new model",
    "activity": "Scoring 400 tasks",
    "progress": {"done": 120, "total": 400},
    "cwd": "/Users/me/evals",
    "ts": 1791273600.5
  }
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `v` | integer | Always `1` for this version. |
| `kind` | `"update"` or `"end"` | `end` marks the session as over; other fields are ignored. |
| `source` | string | Who's reporting: `claude-code`, `codex`, `cli`, or your own name. |
| `session` | string | Your session id. `source` and `session` together identify an agent. |
| `label` | string | Display name. Defaults to the last component of `cwd`. Moonlet adds ` 2`, ` 3`, and so on when two live agents share a label. |
| `state` | `idle`, `working`, `waiting`, `done`, `failed` | `waiting` means blocked on the user. |
| `title` | string | What the agent was asked. |
| `activity` | string | What it's doing now, 60 characters or fewer. |
| `summary` | string | The final message, unabridged. Moonlet shortens it for cards. |
| `message` | string | What the agent needs (`waiting`) or why it failed (`failed`). |
| `milestone` | string | A notable step, such as `Committed changes`. Shown in the summon view, never as a card. |
| `tasks` | array of tasks | The full task list, replacing the stored one. |
| `task` | task | Insert or update one task; status `deleted` removes it. |
| `progress` | `{"done", "total"}` | Explicit progress; takes precedence over task counts. A `total` of 0 clears it. |
| `cwd` | string | Working directory. |
| `host` | object | Where the agent runs: `bundle_id`, `term_program`, `tty`, `pid`. Lets Moonlet bring the right window forward. |
| `ts` | number | Seconds since 1970. |

A task is `{"id": "…", "title": "…", "status": "pending" | "in_progress" | "completed" | "deleted"}`.

Text fields are patches: leave a field out to keep the stored value, or send an empty string to clear it.

## What becomes a card

Moonlet derives everything from state changes:

| Change | Card |
| --- | --- |
| Any state → `waiting` | `<label> needs you`, with `message` |
| `waiting` → anything else | The card is withdrawn |
| Any state → `done` | `<label> done`, with a few words from `summary`, or `has a question` if the summary asks the user something |
| Any state → `failed` | `<label> failed`, with `message` |
| `working` with no events for 10 minutes | `<label> seems stuck` |

When cards appear, and for how long, is described in [DESIGN.md](DESIGN.md).

## Examples

```bash
# From any language: one line to the socket.
printf '%s\n' '{"type":"event","event":{"v":1,"kind":"update","source":"ci","session":"build-7","state":"failed","message":"Integration tests failed","ts":0}}' \
  | nc -U ~/Library/Application\ Support/Moonlet/moonlet.sock

# Or with the command, which also spools when the app is closed.
moonlet emit --source ci --session build-7 --state failed --message "Integration tests failed"
moonlet status --json
```

## Versioning

New optional fields may appear in version 1; producers and the app ignore fields they don't know. A breaking change would bump `v`, and the app would keep accepting version 1 for at least one major release.
