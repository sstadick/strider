# Session Switching Plan

## Proposal

- Date proposed: 2026-04-25
- Implementation status: v1 implemented (pending manual session-switch validation)

## Goal

Surface pi's existing session persistence inside Strider so users can browse and
resume saved sessions without leaving Neovim.

Strider should not invent a second session storage layer. pi remains the source
of truth. Strider adds a thin UX layer for discovering sessions, resolving a
session id/path, and switching the active pi RPC runtime to that session.

## Key Product Decision

Use pi's project settings file for repo-local session storage.

A project can opt into repo-local sessions with:

```json
// .pi/settings.json
{
  "sessionDir": ".pi/sessions"
}
```

Because Strider starts pi RPC with the project as `cwd`, pi will automatically
create and list sessions in that directory. Strider's session switching code
should use the active pi session manager's session directory, not hard-coded
paths, so this works for:

- repo-local `.pi/sessions`
- global default `~/.pi/agent/sessions/--encoded-cwd--`
- explicit `--session-dir` users may provide through `pi_cmd`

Recommend users add this unless they explicitly want to commit/share sessions:

```gitignore
.pi/sessions/
```

Session JSONL can contain prompts, file contents, tool output, and secrets from
logs or command output, so it should be private by default.

## User-Facing Commands

### `/sessions`

Browse saved sessions for the current project/session dir.

Behavior:

1. List sessions from the active pi session directory.
2. Show a picker with session metadata.
3. Switch to the selected session.
4. Do not send an LLM turn.

Suggested picker label:

```text
● Today 14:31  auth redirect cleanup      0196f3a  12 msgs
  Today 09:10  review lua rpc state       0196e8b   8 msgs
  Apr 24       patch session picker       0196c11   3 msgs
```

Include:

- current-session marker
- modified timestamp
- session name if set, otherwise first user prompt
- short session id
- message count

### `/resume`

Resume a session. With no argument, behaves like `/sessions`.

Examples:

```text
/resume
/resume 0196f3a
/resume ./some-session.jsonl
/resume /absolute/path/to/session.jsonl
```

Behavior with an argument:

1. If the value looks like a path, switch directly to that path.
2. Otherwise treat the value as a session id prefix.
3. Search current project/session dir first.
4. Optionally search all pi sessions as a fallback.
5. If exactly one match is found, switch to it.
6. If multiple matches are found, show a filtered picker.
7. If no matches are found, notify the user.

### `/switch_session <path-or-id>`

Alias for `/resume <path-or-id>`.

This is the explicit API-ish name and mirrors pi RPC's `switch_session`, but it
should go through the Strider extension resolver so ids and paths both work.

### Vim commands

Add first-class commands:

```vim
:StriderSessions
:StriderResume [path-or-id]
```

These should operate on the main chat lane in v1.

## Implementation Plan

### 1. Add session helpers to the pi extension

Update:

```text
pi/strider-stepper.ts
```

Import pi's session API:

```ts
import { SessionManager } from "@mariozechner/pi-coding-agent";
```

Add helpers:

- `looksLikePath(value: string): boolean`
- `shortSessionId(id: string): string`
- `sessionTitle(info): string`
- `formatSessionLabel(info, currentId): string`
- `resolveSessionPath(input, ctx): Promise<string | SessionInfo[]>`
- `switchToSession(path, ctx): Promise<boolean>`

Resolution should be equivalent to pi CLI behavior, with one Strider-specific
addition: prefer `ctx.sessionManager.getSessionDir()` so repo-local settings are
respected.

Current-dir lookup:

```ts
const sessionDir = ctx.sessionManager.getSessionDir?.();
const local = await SessionManager.list(ctx.cwd, sessionDir);
```

Global fallback:

```ts
const all = await SessionManager.listAll();
```

Use session id prefix matching:

```ts
session.id.startsWith(input)
```

Be explicit about ambiguous matches. If UI is available, offer a picker. If not,
notify/error with a short list of matching ids.

### 2. Register `/sessions`, `/resume`, and `/switch_session`

Add extension commands in `pi/strider-stepper.ts`.

`/sessions`:

- list local sessions using `SessionManager.list(ctx.cwd, ctx.sessionManager.getSessionDir())`
- if none, notify `No saved sessions found`
- open `ctx.ui.select(...)`
- switch to selected session

`/resume`:

- no args: call the same picker flow as `/sessions`
- args: resolve id/path, then switch

`/switch_session`:

- require an argument
- call the same direct resolver as `/resume <arg>`

Switching should use:

```ts
await ctx.switchSession(path, {
  withSession: async (nextCtx) => {
    updateWidget(nextCtx);
    nextCtx.ui.notify("Resumed session ...", "info");
  },
});
```

Do not use the captured pre-switch `ctx` after replacement except to finish the
immediate command path. Post-switch work belongs in `withSession`.

### 3. Update Lua slash-command routing

Update:

```text
lua/strider/init.lua
```

Currently `/resume` is intercepted as a raw RPC command:

```lua
resume = { type = "switch_session", args_key = "sessionPath" },
```

Remove that mapping so `/resume`, `/sessions`, and `/switch_session` are routed
as extension commands through normal RPC `prompt` handling.

Keep raw RPC mappings for commands that do not need extension resolution:

```lua
new
compact
export
```

Keep the existing Lua `/fork` flow for now.

### 4. Add Vim commands

Update:

```text
plugin/strider.lua
lua/strider/init.lua
```

Add:

```vim
:StriderSessions
:StriderResume [path-or-id]
```

Implementation can send slash commands to the main lane:

- `:StriderSessions` sends `/sessions`
- `:StriderResume foo` sends `/resume foo`
- `:StriderResume` sends `/resume`

These should ensure the main backend is running and open the main log/compose
only as needed.

### 5. Display current session identity

Update the Strider widget/status in `pi/strider-stepper.ts`.

Add a compact session line from:

```ts
ctx.sessionManager.getSessionName()
ctx.sessionManager.getSessionId()
ctx.sessionManager.getSessionFile()
```

Suggested line:

```text
Session: auth redirect cleanup 0196f3a
```

If there is no name:

```text
Session: 0196f3a
```

Optionally include a shortened file path in future, but keep the initial widget
compact.

### 6. Log behavior after switching

For v1, do not reconstruct the full old transcript into the Neovim log.

After switch:

- append a visible marker to the main Strider log, e.g.

```text
──── Resumed session ────
```

- update status/widget
- future prompts should continue using the resumed pi context

Do not clear the visible log automatically in v1. The marker is enough to show a
session boundary without destroying local UI history.

Future enhancement: call `get_messages` and replay the resumed transcript into
`strider://log`.

### 7. Scope and non-goals for v1

V1 switches the main chat lane only.

Do not try to restore active review UI state yet. Review restoration has extra
state that currently lives partly in Lua:

- active review plan
- current stop index
- accepted stops
- unresolved comments
- rendered annotations
- review window/buffer state

Later, Strider can persist and restore review state using pi custom session
entries.

Also out of scope for v1:

- deleting sessions
- renaming sessions from the picker
- exporting sessions
- replaying full transcript into the log
- branch/tree visualization beyond pi's existing `/tree`

## Tests

### Lua routing tests

Update or add tests around slash-command dispatch.

Cases:

1. `/resume abc123` should no longer be sent as raw RPC `switch_session`.
2. `/resume abc123` should be sent as a prompt/extension command.
3. `/sessions` should route as a prompt/extension command.
4. Existing raw RPC commands still work:
   - `/new`
   - `/compact`
   - `/export`

### Fake pi support

Update:

```text
tests/support/fake_pi.py
```

At minimum, let it handle prompt messages starting with:

```text
/sessions
/resume
/switch_session
```

It can emit a fake successful resume event:

```json
{"type":"session_start","reason":"resume"}
```

and an assistant/fake response if needed for current test expectations.

### Extension behavior tests

If we add TS-level tests or lightweight integration coverage later, cover:

1. path argument resolves directly
2. exact session id resolves
3. session id prefix resolves
4. ambiguous prefix opens a picker or errors clearly
5. current session dir is preferred over global matches
6. repo-local `.pi/settings.json` sessionDir is respected via `getSessionDir()`

## Documentation

Add a short section to the docs/README explaining repo-local sessions:

```json
// .pi/settings.json
{
  "sessionDir": ".pi/sessions"
}
```

Mention:

- sessions are pi JSONL files
- Strider uses pi's existing storage
- `/sessions` browses saved sessions
- `/resume <id-or-path>` resumes directly
- `.pi/sessions/` should usually be gitignored

## Implementation Order

1. Add docs note for `.pi/settings.json` sessionDir.
2. Add session formatting/resolution helpers in `pi/strider-stepper.ts`.
3. Register `/sessions`, `/resume`, `/switch_session`.
4. Remove Lua `/resume` raw RPC interception.
5. Add `:StriderSessions` and `:StriderResume`.
6. Add current session id/name to the widget.
7. Update fake backend and tests.
8. Run focused tests, then broader smoke tests.

## Validation Commands

Focused validation:

```bash
python3 -m unittest tests.test_rpc_commands
```

Static Lua checks, if available:

```bash
luajit -b lua/strider/init.lua /tmp/strider-init.luac
luajit -b lua/strider/rpc.lua /tmp/strider-rpc.luac
```

Manual validation:

1. Create `.pi/settings.json` with `sessionDir: ".pi/sessions"`.
2. Open Neovim in the repo.
3. Start `:StriderChat` and send a prompt.
4. Confirm `.pi/sessions/*.jsonl` is created.
5. Run `:StriderSessions` and switch sessions.
6. Run `:StriderResume <short-id>`.
7. Send a follow-up prompt and confirm it continues the resumed context.
