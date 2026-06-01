# Saved sessions

Strider surfaces pi's existing session persistence. It does not create a second
session store: pi remains the source of truth and Strider adds Neovim commands
for browsing and resuming saved JSONL session files.

## Repo-local sessions

A project can opt into repo-local sessions with pi's project settings file:

```json
// .pi/settings.json
{
  "sessionDir": ".pi/sessions"
}
```

Strider starts pi RPC with the project as `cwd`, so pi automatically creates and
lists sessions in that directory. If `sessionDir` is not configured, pi's default
session directory is used. If users pass an explicit `--session-dir` via
`pi_cmd`, Strider uses the active pi session manager's directory.

Session JSONL can contain prompts, file contents, tool output, logs, and secrets.
This repo's root `.gitignore` excludes `.pi/sessions/` by default; keep that
rule unless you explicitly want to commit or share sessions.

## Commands

- `/sessions` — browse saved sessions for the current project/session directory.
- `/resume` — browse saved sessions, same as `/sessions`.
- `/resume <id-or-path>` — resume by session id prefix or JSONL path.
- `/switch_session <id-or-path>` — explicit alias for `/resume <id-or-path>`.
- `:StriderSessions` — Vim command for `/sessions` on the main lane.
- `:StriderResume [id-or-path]` — Vim command for `/resume [id-or-path]` on the
  main lane.

The picker labels show the current-session marker, modified time, session name
(or first user prompt), short id, and message count.

## Behavior

- Session id resolution searches the active project/session directory first.
- If no local session matches, Strider falls back to pi's global session list.
- Ambiguous id prefixes open a picker when UI is available.
- After switching, Strider updates the widget/status and appends a visible
  session-boundary marker to the log. It does not replay the full old transcript
  into the Neovim log in v1.

Review UI state is not restored yet. V1 switches the main chat lane/pi context;
future work can persist and restore review plans and stop position with pi
custom session entries.
