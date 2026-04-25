# Saved sessions (deferred)

Design notes for per-project saved sessions with a picker-driven resume
flow. **Deferred intentionally.** Pi already persists every turn to a
JSONL file, so "saving" is free; the question is whether surfacing old
sessions is a net win. Our current take: probably not — stale context
from an abandoned session can drag a new turn sideways just as easily
as it can save bootstrapping time. Encouraging fresh sessions tends to
produce better outcomes. We'll revisit if actual usage shows a concrete
case where resume pays off.

Keeping this doc so the plan is shelf-ready.

## Goal

- Sessions for the current project live under `<project-root>/.sessions/`.
- Each session has a meaningful name; default = current git branch.
- `:StriderSessions` opens a fuzzy picker; selecting resumes a session
  with full pi context (messages, model, tree) restored.
- Strider-side state either carries over or resets cleanly — no broken
  hybrids.

## What pi already gives us

No work needed for any of this — confirmed against `docs/rpc.md` and
`docs/session.md` in the installed pi package:

- **Auto-persistence**: every turn appends to a JSONL session file, so
  "save" is continuous. Nothing to do at save time.
- **Named sessions**: `set_session_name` RPC tags a session with a human
  label. Name is stored inside the JSONL header, not the filename.
- **Switching**: `switch_session {sessionPath}` loads any .jsonl and
  restores messages, model, thinking level, and tree leaf.
- **Custom directory**: `--session-dir <path>` on pi startup points pi
  at a non-default sessions directory. We already build the pi command
  line in `rpc.lua::command_list()` and can extend it.
- **Session listing**: `SessionManager.list(cwd, sessionDir)` exists,
  but readdir + parsing the JSONL header line ourselves is simpler and
  avoids a protocol round-trip per entry.

## Scope for v1

**Ship:**

1. **Redirect pi to `<project-root>/.sessions`.** `rpc.lua::command_list()`
   appends `--session-dir <cwd>/.sessions` when starting pi. One session
   directory per project; two worktrees of the same repo get isolated
   session sets naturally.
2. **Auto-name new sessions by git branch.** On backend start, if the
   active session has no name, derive one: `git rev-parse --abbrev-ref
   HEAD` → sanitize (replace `/` with `-`, strip unsafe chars) → call
   `set_session_name` via RPC. On collision with an existing session of
   the same name, append a short timestamp suffix (e.g. `feat-auth-20260421-1445`).
   Bail silently if not a git repo.
3. **`:StriderSessions` picker.** Scan `<project-root>/.sessions/*.jsonl`,
   read each header line (first line of the file) to extract name,
   created-at, message count, last-modified. Pass entries through
   `picker.select` (reuses telescope/fzf-lua/`vim.ui.select` fallback
   already wired for `/models` and `/tree`). Entries formatted as:
   `<name> <marker> — <msg_count> msgs — <relative_time>`, current
   session marked with `●`. On select: `{type: "switch_session", sessionPath: <abs path>}`.
4. **Log buffer reset on switch.** Wipe the log buffer on session
   switch, append a `[strider] switched to <name>` marker, and let new
   messages stream in. Don't attempt to rebuild the log from historical
   messages for v1.

**Defer:**

- `:StriderSessionNew [name]` — explicit new-session command. Pi already
  creates a new session file on startup; if the user wants a clean
  session they can quit and relaunch the backend. If we find people
  asking, add later.
- `/session-name <name>` extension command for inline rename. Nice but
  not essential; `set_session_name` works fine without a UI if the user
  really wants to rename.
- **Sidecar strider state**. If you ever want review state, recent files,
  or summaries to survive a switch, store `<sessionId>.strider.json`
  next to the session file. Skip until a concrete need shows up; the
  recoverable state (recent files, summaries) regenerates naturally.
- **Log rebuild from history.** Walking `get_messages` and re-rendering
  `[user]` / `[assistant]` / `[tool]` blocks would be nicer than the
  wipe-and-restart approach but adds non-trivial formatting work. Defer.
- **Auto-suggest new session on branch change.** Too intrusive. If the
  user `git switch`es mid-pi-run, the current session stays put. User
  opens `:StriderSessions` when they want to switch.

## Implementation sketch

**`rpc.lua`** — extend `command_list()`:

```lua
local sessions_dir = vim.fs.joinpath(cwd, ".sessions")
vim.list_extend(cmd, { "--session-dir", sessions_dir })
```

Add helpers:

- `M.send_switch_session(path)` — `{type: "switch_session", sessionPath = path}`.
- `M.send_set_session_name(name)` — `{type: "set_session_name", name = name}`.
- `M.send_get_state()` — `{type: "get_state"}` so we can learn the
  current session's path + name at startup (response carries
  `sessionFile`, `sessionName`).

Hook `handle_response` to update `state.session_info` from `get_state`
responses.

**`lua/strider/sessions.lua`** (new):

- `list_sessions(cwd) -> { { path, name, msg_count, mtime, is_active }, ... }` —
  readdir `<cwd>/.sessions`, parse each file's first line for the
  header, stat for mtime. Sort by mtime desc.
- `branch_name(cwd) -> string|nil` — shell out to `git rev-parse
  --abbrev-ref HEAD`, sanitize.
- `format_entry(entry) -> string` — name + markers + counts + relative
  time. Used as picker labels.
- `pick(on_select)` — build items, call `picker.select`.

**`init.lua`**:

- `function M.sessions()` — command body for `:StriderSessions`. Ensures
  backend, calls `sessions.pick`, on select calls `rpc.send_switch_session`
  and resets the log buffer.
- On backend-start hook (after the first `get_state` resolves): if
  `sessionName` is nil and `branch_name(cwd)` is non-nil, call
  `rpc.send_set_session_name(branch_name)` with collision handling.
- Register `:StriderSessions` via `plugin/strider.lua`.

**Tests**:

- `tests/test_tmux_sessions.py` under the fake_pi harness: create two
  canned sessions on disk, open the picker, select one, assert we sent
  a `switch_session` command with the right path and that the log was
  reset.
- Branch-name derivation unit test — pure function, trivially covered.

## Open questions (for when we unshelf this)

1. **`.gitignore` integration.** Auto-add `.sessions/` to the repo's
   `.gitignore`? My instinct: no, leave it to the user. It's their
   repo. Mention it in a notify the first time `.sessions/` is created.
2. **Session count cap.** A year of daily pi use could leave hundreds
   of .jsonl files per project. Picker sorts by mtime so recent wins,
   but we might want a `--prune` option or just a docs note on manual
   cleanup.
3. **Ephemeral branches.** If the user's branch is something like
   `HEAD` (detached) or a generated name (e.g. `dependabot/...`), the
   auto-name is awkward. Probably fine to accept whatever git returns;
   user can rename.
4. **Switch during an active turn.** Should `:StriderSessions` refuse to
   switch while a pending request is in flight, or force-abort and
   switch? Lean toward refuse-with-warning — you can always `:StriderAbort`
   first.

## Why we're deferring

Two reasons, both empirical rather than technical:

- **Stale context hurts.** An old session carries old assumptions, old
  file versions in the model's head, and accumulated mistakes. Picking
  it up for a new task often wastes more turns correcting drift than
  starting fresh would have cost.
- **The branch-name heuristic is fuzzy.** A single branch can host
  multiple unrelated tasks over its lifetime; mapping one branch to
  one session forces a 1:1 that doesn't match how people actually work.

If those reasons turn out to be wrong in practice — or if we hit a
specific workflow where resumption is clearly valuable (e.g. long
multi-day reviews where the plan state is expensive to rebuild) —
come back and build it. The design above should survive re-reading.
