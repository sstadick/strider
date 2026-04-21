# Session Persistence Plan

Close nvim, reopen it later, pick up the conversation where you left off.

## The core insight

**pi already persists conversations.** Every RPC session writes to a `.jsonl` file under `~/.pi/agent/sessions/<cwd-hash>/`. The missing piece is just that Sherpa doesn't *reconnect* to an existing session when you restart nvim — it always starts a fresh pi process with a fresh session.

## Two layers of state

1. **Conversation state** (pi's `.jsonl` file) — already persisted by pi. Contains the full message history, tool calls, etc.
2. **Sherpa UI state** (review items, comments, explanations, highlights, cursor position) — lives only in Lua memory inside `state.lua`. Lost on nvim exit.

## Strategy: reconnect to the last session, replay Sherpa state

### Phase 1: Reconnect to existing pi session (the big win)

When `SherpaReview`/`SherpaWork`/`SherpaSearch` starts the backend:

1. Before spawning a new pi process, check if there's a recent session file for this CWD
2. If found, start pi with `--session <path>` (or `--continue`) to resume that conversation
3. On reconnect, use `get_state` and `get_messages` to reconstruct what happened
4. Parse the message history to restore the Sherpa log buffer content
5. If the last message was a teach/work/search, restore the review pane

Implementation:

- `rpc.start(cwd)`:
  - Scan `~/.pi/agent/sessions/<cwd-hash>/` for the most recent `.jsonl` file
  - If found and modified < N hours ago (configurable, default 24h), add `--session <path>` to the command
  - After pi starts, send `get_state` + `get_messages` to populate the log buffer
- `state.lua`:
  - Add `session_file` field to track the active session path
  - Add `last_session_file()` helper that scans for the most recent `.jsonl`
- New config option: `resume_sessions = true` (default), `resume_max_age_hours = 24`

### Phase 2: Persist Sherpa-specific state

Write a small `.sherpa-session.json` alongside the pi session file (or in the project's `.sherpa/` dir):

```json
{
  "session_file": "/Users/.../.pi/agent/sessions/.../session.jsonl",
  "review": {
    "scope": "file",
    "items": [...],
    "current_index": 2,
    "comments": [...]
  },
  "last_summary": "...",
  "timestamp": "2026-04-21T..."
}
```

On reconnect:

1. Read `.sherpa-session.json` if it exists
2. Restore review items, comments, current index into `state.lua`
3. Re-render the review pane
4. Re-apply highlights to the current item's file/range

Implementation:

- `state.save_sherpa_state()` — called on `VimLeavePre` autocmd and after review/comment changes
- `state.load_sherpa_state()` — called on backend start when resuming
- Store in `<cwd>/.sherpa/session.json` (gitignored) or alongside the pi session file

### Phase 3: Session management UX

- `:SherpaSessions` — picker showing recent sessions for this project, with timestamps and first-user-message previews
- `:SherpaReview` respects `resume_sessions` config
- `:SherpaNewSession` or `:SherpaReview!` (bang) — force a fresh session instead of resuming
- Auto-cleanup: delete `.sherpa-session.json` when a session is explicitly ended

## What about the in-flight pi process?

When you quit nvim, the pi child process is killed (via `on_exit` in `jobstart`). But the session `.jsonl` file is already written — pi writes incrementally. So the conversation is saved even if the process dies ungracefully.

On resume, pi reads the `.jsonl` and continues the conversation. The LLM gets the full history back (or the compacted version if compaction ran).

## Edge cases

- **Stale session**: If the session was days ago or for a different branch, the LLM context may be confusing. The `resume_max_age_hours` config helps. Also consider showing a notification: "Resumed session from 2h ago"
- **Multiple nvim instances**: Two nvim instances for the same project would fight over the same pi session. Solution: pi sessions are per-process. Two nvim instances = two pi processes = two session files. Resume picks the most recent.
- **Compact history**: If pi auto-compacted, the `.jsonl` still has everything, but the LLM only sees the summary. Sherpa should still be able to replay the full log from the `.jsonl`.
- **Review items from a different file structure**: If files changed since the session was saved, review item paths may be stale. Load them but mark as "stale" and let the user re-review.

## Recommended order

1. **Phase 1 first** — reconnecting to the pi conversation is the highest value, lowest risk. Just add `--session <path>` to the spawn command and replay the log buffer from `get_messages`.
2. **Phase 2 next** — Sherpa state persistence is valuable but more complex. Start with just saving/restoring review items and comments.
3. **Phase 3 last** — session picker and management are polish.

## Files to modify

| File | Change |
|------|--------|
| `lua/sherpa/rpc.lua` | `command_list()` adds `--session <path>` when resuming; `start()` calls `get_messages` to replay log |
| `lua/sherpa/state.lua` | Add `session_file`, `last_session_file()`, `save_sherpa_state()`, `load_sherpa_state()` |
| `lua/sherpa/ui.lua` | Replay log buffer from message history on resume |
| `lua/sherpa/review.lua` | Restore review items/comments from saved state |
| `lua/sherpa/init.lua` | Add `:SherpaNewSession` command; `VimLeavePre` autocmd for save |
| `plugin/sherpa.lua` | Register `:SherpaNewSession` |
| `docs/` | Update architecture, add session persistence docs |

## Open questions

- Where should `.sherpa-session.json` live? Options:
  - **`<project>/.sherpa/session.json`** — project-local, gitignored, easy to find. But pollutes the project directory.
  - **`~/.pi/agent/sessions/<cwd-hash>/sherpa-state.json`** — alongside the pi session file. No project pollution but harder to clean up.
  - **`/tmp/sherpa-sessions/<cwd-hash>.json`** — ephemeral, lost on reboot. Simplest but least durable.
