# Architecture

## Current product model

Strider is built around five primary user flows:

- `:StriderSearch {prompt}`
- `:StriderReview [scope] [prompt]`
- `:'<,'>StriderPatch {prompt}`
- `:StriderQ [prompt]` — tangent that branches off the session tree
- `:StriderChat [prompt]`

Supporting navigation and control:

- `:StriderNext`
- `:StriderPrev`
- `:StriderComment {text}`
- `:StriderComments`
- `:StriderReviewItems`
- `:StriderStop` — abort the main-lane in-flight turn (maps to pi's `abort` RPC)
- `:StriderStopFlow` — abort active Q/Search/Patch flow-worker turns

The main product is no longer centered on a linear `Q` loop.
Review is the primary walkthrough surface.

## Components

### 1. Neovim plugin

Lives in `lua/strider/`.

Owns:
- process lifecycle for `pi --mode rpc`
- RPC transport
- command bindings
- quickfix and picker UX
- file jumps and range highlighting
- scratch log buffer
- dedicated `strider://review` pane
- floating `strider://prompt` / `strider://comment` input editors
- local review/session state

Review code is split by responsibility:
- `lua/strider/review.lua` owns review state transitions, planning,
  navigation, comments, and prompts.
- `lua/strider/review/render.lua` owns the markdown rendered into the
  `strider://review` pane, including status text, item summaries, excerpts,
  comments, and the review plan table of contents.

### 2. pi extension

Lives in `pi/strider-stepper.ts`.

Owns:
- prompt shaping for `plan`, `review`, `search`, `patch`, and `prompt`
- the `strider_plan` and `strider_append_stops` tools used during reviews
- the `strider_clarify` tool used during `prompt` and `patch` for
  mid-turn questions, plan proposals, and yes/no confirmations
- the `strider_vim` tool, an always-available raw Lua bridge into the live
  Neovim client; the extension declares the tool and uses the RPC UI channel as
  transport, while Lua executes the code in-process
- read-only guardrails for plan / review / search
- widget/status updates for Neovim (model, context usage, running cost)
- `/models` and `/tree` commands that drive fuzzy pickers via
  `ctx.ui.select` to switch models or jump through the session tree
- `/thinking` command to cycle or set reasoning level

## Core flows

### Search

1. user runs `:StriderSearch <prompt>`
2. plugin sends `/search <prompt>`
3. extension constrains the model to structured search output
4. plugin parses result lines
5. results open through telescope/fzf when available for a consistent selection flow
6. without a picker, Strider falls back to quickfix and jumps/highlights the lone match when only one exists

## Review

Reviews are pre-planned. The model commits to a full list of stops up
front via the `strider_plan` tool; the plugin then walks that fixed list.

1. user runs `:StriderReview <prose>` (optionally with a visual range)
2. plugin opens the review pane in a "planning..." state and sends
   `/plan <prose>` to the extension
3. extension's `plan` command tells the model to produce a plan. The model
   reads code as needed, then calls the `strider_plan` tool with:
   - `scope`: `"selection"`, `"diff"`, or `"free"` (model self-labels)
   - `base`: required when scope is `"diff"`
   - `stops`: ordered list of
     `{path, startLine, endLine, title, why, explanation}` — the
     explanation is pre-written at plan time, 2-4 sentences per stop
4. plugin ingests the plan, renders the TOC in the review pane, and
   focuses stop 1. The sidebar shows stop 1's pre-written explanation
   immediately — no follow-up model turn.
5. `:StriderNext` / `:StriderPrev` advance through the fixed plan. Each
   move is a local index change plus a buffer jump — instant, no model
   call. `:StriderNext!` accepts the current stop before advancing, so
   explicit acceptance stays on the existing navigation command. The
   sidebar flips to the pre-written explanation for the new stop.
6. `:StriderReview <question>` with an active review is the only way to
   trigger a per-stop model call. It sends `/review ...` scoped to the
   current stop, carrying the question.
7. during a free-scope review, the model may call `strider_append_stops`
   mid-review to add more stops (append-only — no reorder, no deletion)
8. walking past the last stop ends the review; unresolved comments are
   summarized back to the agent

Coverage guarantees (enforced at plan-ingest time):
- selection scope: every line in the original range is covered by some stop
- diff scope: every changed line in `git diff <base>...HEAD` is covered
- free scope: no coverage check — the model chose

Important UX rule:
- the review pane is the primary explanation surface
- the log is secondary transcript/history
- during review, the user stays on the active stop — the model's
  `read`/`bash` tool calls do NOT auto-jump the buffer

### Patch

1. user visually selects a range (or relies on the active review item)
2. user runs `:StriderPatch [prompt]`
3. plugin opens the floating patch editor, prefilled when inline args were given
4. on submit, plugin sends `/patch ...` with file, line range, and excerpt context
   on the dedicated patch worker process
5. a non-focus-stealing patch flow card opens in the bottom-right
6. tool events update the card with inspected/touched files and diff blocks
7. full transcript lands in `:StriderLogPatch`
8. tool events update the file jump and edit highlighting
9. edited ranges remain highlighted after the patch

### Tangent

`:StriderQ` opens a floating editor for a one-shot side question that
runs on Strider's dedicated Q worker — a separate pi process from main chat,
search, patch, and review. This keeps the main session clean and lets the user
ask quick questions without interrupting a running chat or patch turn.

1. user runs `:StriderQ [prompt]` (optionally with a visual range)
2. plugin opens the floating editor, prefilled when inline args were given
3. on submit, plugin dispatches the question as `/prompt ...` on the
   Q worker (with an excerpt block when a range was given)
4. the question runs in the background: the focused answer opens in a
   non-focus-stealing bottom-right `strider://StriderQAnswer` window; it stays
   compact until the user focuses/selects it or runs bare `:StriderQ`, then
   expands to near full height and remains expanded until `q`, `<Esc>`, or
   bare `:StriderQ` folds it
5. expanded Q cards open a separate follow-up compose float beneath the answer;
   `<C-s>` sends that draft as another `/prompt` on the same Q worker/session
6. the full transcript lands in `:StriderLogQ`, including reasoning, tool calls,
   and tool output; chat is not auto-opened
7. no tree anchoring needed — the Q worker has its own independent session

### Chat

1. user runs `:StriderChat` (no args) to toggle the log + compose surfaces
2. `:[range]StriderChat [message]` opens chat and prefills compose with the
   range pointer and/or inline text instead of sending immediately
3. compose `<C-s>` sends `/prompt <message>` if no request is pending, or
   `/steer <message>` to redirect a running turn
4. assistant handles the request under the user's global pi system
   prompt; Strider adds no mode-specific guidance beyond making
   `strider_clarify` available
5. the compose buffer persists across sends; user can fire off steers
   any time, even while a reply is streaming
6. user can follow up with `:StriderReview` to walk through the result

## Review state model

Strider keeps local review state in the Neovim session.
A review session tracks:
- review items
- current index
- accepted stops
- local comments
- per-item explanation text
- end-of-review summary state

Comments are local today, but the data shape leaves room for future GitHub review mapping.

## UI surfaces

### Code window

The source of truth for the currently reviewed or edited range.
Strider jumps here and highlights the active region.

### Review pane

Buffer name:
- `strider://review`

Purpose:
- show one active review item
- show the current explanation
- show excerpt and item-local comments
- show the end-of-review summary
- show busy state while waiting for agent responses

### Log buffer

Buffer name:
- `strider://log`

Purpose:
- keep the full transcript, tool activity, and stderr
- useful for debugging and history
- toggled via `:StriderChat` along with compose
- tail new output only while the log window is already at the bottom;
  scrolling up pauses follow-mode until the user jumps back to the tail
- keep the latest user prompt available as a small pinned preview when
  its source block has scrolled out of view
- not the primary pairing surface during review

### Input editor

Buffer names:
- `strider://prompt` — used by `:StriderSearch`, `:StriderReview`, `:StriderPatch`, `:StriderQ`
- `strider://compose` — persistent user input buffer used by `:StriderChat`;
  also hijacked to reply to `strider_clarify` questions and to edit
  plan-proposal bodies (the `[Clarify]` badge marks this state)
- `strider://comment` — used by `:StriderComment`

A centered floating scratch buffer used by popup-style commands. Renders
per-command guidance as `Comment`-highlighted virtual lines plus a
`<C-s> to submit · <Esc><Esc> to cancel` hint. Inline command arguments
prefill the editor instead of dispatching directly. For `:StriderReview`,
the editor has two modes: when no review is active the text describes the
review scope; when a review is active, the text is treated as a question
about the current review item.

## RPC events used by the plugin

### From pi

- `message_update`
  - carries incremental streaming events inside
    `assistantMessageEvent`: `thinking_start`, `thinking_delta`,
    `thinking_end`, `text_delta`, `done`, `error`
  - thinking deltas stream raw text into a live block in the log buffer;
    on `thinking_end` the raw text is replaced with a styled
    `[thinking]` block
  - text deltas stream per-message text into a live block (reset on each
    `message_end`, separate from the cross-message `assistant_text`
    accumulator used by reviews); on `message_end` the raw text is
    replaced with a styled `[assistant]` block
  - `done` / `error` flush any remaining thinking blocks
  - the live block mechanism is shared: `start_live_block` (force-create,
    used by thinking) vs `ensure_live_block` (idempotent, used by text)
- `message_end`
  - capture assistant text
  - update log
  - update review pane when the response belongs to review
  - when `message.stopReason == "error"` or `"aborted"`, render the
    reason as an `[error]` block (red header / red-tinted background),
    consume the pending request, and stop the activity spinner
- `extension_error` — runtime failure the extension can't recover from
  (e.g. "No API key found for <provider>", provider 4xx before the
  stream opens). The preceding `response` may be `success: true`
  because the RPC dispatch itself succeeded — the failure is async.
  Renders as a red `[error]` block, clears pending state, stops the
  spinner. Without handling this, the log just hangs on "Waiting for
  assistant response…".
- `tool_execution_start`
  - log tool usage as a Codex-style `• Verb` header (paths highlighted
    in the `StriderLogPath` accent color)
  - track touched paths
- `tool_execution_end`
  - output is inserted directly after the matching tool header
    (via extmark tracking) rather than appended at the end of the log,
    so parallel tool calls render header+result pairs in order
  - for `edit`: parse `result.details.diff`, update the tool header to
    `• Edited <path> (+N -M)`, and render the diff rows directly under
    that header with Strider-owned green/red extmark bands, a line-number
    gutter, and treesitter source highlighting on the changed code
  - for `read` / `write`: inline `result.content[*].text` wrapped in
    a fenced markdown code block tagged with the language derived
    from the file's extension (lua, rust, typescript, …) so
    treesitter + render-markdown syntax-highlight the body. Pi's trailing
    `[N more lines in file. Use offset=X to continue.]` sentinel on
    truncated reads is stripped before fencing so prose never lands
    inside the language parser.
  - for `bash` / `grep` / `ls` / `find`: render compact transcript rows
    with a muted `│` gutter instead of a code fence. `grep`, `ls`, and
    `find` get cheap line-count metadata (`N matches`, `N entries`,
    `N paths`). Compact output uses the same 5-line Codex-style middle
    truncation and `… +N lines` marker. The gutter keeps raw command output
    from rendering as headings, lists, blockquotes, tables, or fences.
    Search/list headers preserve meaningful
    arguments from pi, including grep patterns, find patterns, paths, and limits.
  - highlight read/edit/write ranges on the edited file
- `extension_ui_request`
  - `notify` / `setStatus` / `setWidget` / `setTitle` — fire-and-forget
    UI updates. `setWidget` payloads are flattened into the log
    window's winbar. The `strider-clarify` `setStatus` key drives the
    `[Clarify]` badge in the compose winbar.
  - `editor` — the extension uses this both for user-facing clarification
    and for Strider-owned silent transports:
    - **Strider Vim** (title prefixed `[strider-vim-exec]`): no UI opens.
      Lua executes the request prefill as arbitrary Neovim Lua via
      `strider.vim_exec`, then replies with `extension_ui_response{value}`.
      The visible log shows only `• Vim: <intent>` from the tool arguments;
      the Lua source and raw result remain in pi's tool-call history.
    - **Plain clarify** (`kind: question`): title/body rendered as a
      `[clarify]` block in the log, pending-id stashed, compose
      hijacked — the next `<C-s>` sends the reply via
      `extension_ui_response{value}`, `<Esc><Esc>` sends `cancelled`.
      `[Clarify]` badge on the compose winbar marks the state.
    - **Plan proposal** (title prefixed `[strider-plan-proposal]`):
      body rendered as a `[plan]` block, then `vim.ui.select` offers
      Accept / Modify / Reject. Accept sends the body back as-is;
      Modify seeds compose with the body and hijacks it same as a
      plain clarify; Reject sends `cancelled`.
  - `confirm` — yes/no picker via `vim.ui.select`; plugin replies with
    `{confirmed: bool}` or `{cancelled: true}`.
  - `select` — fuzzy picker via telescope / fzf-lua / `vim.ui.select`
    fallback; plugin replies with `{value}` or `{cancelled: true}`.
  - `input` — single-line input via `vim.ui.input`; plugin replies
    with `{value}` or `{cancelled: true}`.

### To pi

- `prompt` — user prompt message (extension commands like `/models`,
  `/tree`, `/thinking`, `/sessions`, and `/resume` are passed through
  verbatim so pi routes them to the matching extension command handler;
  other text is wrapped in `/prompt`)
- `new_session` — start a fresh session (`/new` in compose)
- `fork` — fork the current session from an entry (`/fork [entryId]`)
- `compact` — compact context (`/compact [instructions]`)
- `export_html` — export session to HTML (`/export [path]`)

Compose-dispatched raw RPC commands create a main-lane pending `command`
request and start `Working` indicators in the compose and log winbars until the
`response` event arrives, even though no assistant `message_end` follows.

- `switch_session` — raw RPC session switch remains available internally;
  Strider's `/resume` and `/switch_session` slash commands go through the
  prompt/extension path first so ids and paths can be resolved.
- `steer` — mid-turn user redirect delivered after the current assistant
  turn's tool calls complete. Slash-commands are rejected as steers
  (pi forbids them).
- `abort` — cancel the in-flight turn. No body (`{"type":"abort"}`).
  Pi finishes the current model stream and emits a `message_end` with
  `stopReason = "aborted"`, which renders as a cancel-flavored
  `[error]` block. Driven by `:StriderStop` for main and
  `:StriderStopFlow` for flow workers.
- `extension_ui_response` — reply to an awaiting `extension_ui_request`
  (carries the request `id` plus `value` / `confirmed` / `cancelled`)

## File/range heuristics

Strider currently keys off explicit tool paths only:
- `read.path`
- `edit.path`
- `write.path`

Shell parsing remains intentionally lightweight.

## Current implementation status

Working today:
- structured search with picker + quickfix behavior
- pre-planned review with in-buffer annotations and sidebar TOC
- dedicated review pane
- local review comments
- selection-scoped patching
- plain-prompt agent turns with clarify available
- side questions, search, and patches on separate flow-worker processes; Q and
  patch results open in compact flow cards while full transcripts land in their
  worker logs (`:StriderLogQ`, `:StriderLogPatch`, `:StriderLogFlow`); expanded
  Q cards open a separate follow-up compose float, and bare `:StriderQ` toggles
  the latest card when one exists
- clarify and plan-proposal flows rendered inline in the chat log with
  compose-buffer hijack for replies (`[Clarify]` badge while active)
- `:StriderStatus` for a compact lane/status/control summary
- accepted review stops via `:StriderNext!`
- `:StriderStop` / `:StriderStopFlow` to abort in-flight turns
- inline red `[error]` blocks for provider / model / transport errors
  (no more silent hangs)
- cycle thinking level via `<S-Tab>` in compose (mirrors pi's TUI);
  active level shown as `Model: …/… (level)` on the log winbar
- live streaming: thinking and assistant text tokens render in the log
  as unformatted plain text during generation, then finalize into styled
  blocks when the stream completes
- live Neovim bridge: `strider_vim` lets the agent run arbitrary Lua in the
  current Neovim via a silent `[strider-vim-exec]` editor request; Strider logs
  only the supplied intent, not the Lua body or routine inspection result
- rich log rendering: inline diff rows under `• Edited <path> (+N -M)`
  headers for edit tools; syntax-highlighted fenced output for
  read/write via treesitter + render-markdown; compact gutter output for
  bash/grep/ls/find; up to 5 visible output lines with a Codex-style
  `… +N lines` marker when middle lines are hidden; accent-colored file paths in
  tool headers; parallel tool results inserted next to their headers
  via extmark tracking
- session management: `/new`, `/fork`, `/compact`, and `/export` route to
  dedicated RPC message types and show `Working` in the compose/log winbars
  while their RPC response is pending; `/sessions`, `/resume`, and `/switch_session`
  route to Strider extension commands that browse/resolve sessions before
  switching. Session changes render a visual separator
  (`──── New session ────`) in the log
- fast fake-backend tmux e2e tests
- optional real-pi smoke tests on bundled fixture projects

Still rough:
- the review pane can be polished further
- review summaries depend heavily on model quality
- code restoration is not implemented

## Related docs

- `docs/review-mode.md`
- `docs/usage.md`
- `docs/message-queue.md`
- `docs/plan.md`
- `tests/README.md`
