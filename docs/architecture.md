# Architecture

## Current product model

Sherpa is built around five primary user flows:

- `:SherpaSearch {prompt}`
- `:SherpaReview [scope] [prompt]`
- `:'<,'>SherpaPatch {prompt}`
- `:SherpaQ [prompt]` — tangent that branches off the session tree
- `:SherpaChat [prompt]`

Supporting navigation:

- `:SherpaNext`
- `:SherpaPrev`
- `:SherpaComment {text}`
- `:SherpaComments`
- `:SherpaReviewItems`

The main product is no longer centered on a linear `Q` loop.
Review is the primary walkthrough surface.

## Components

### 1. Neovim plugin

Lives in `lua/sherpa/`.

Owns:
- process lifecycle for `pi --mode rpc`
- RPC transport
- command bindings
- quickfix and picker UX
- file jumps and range highlighting
- scratch log buffer
- dedicated `sherpa://review` pane
- floating `sherpa://prompt` / `sherpa://comment` input editors
- local review/session state

### 2. pi extension

Lives in `pi/sherpa-stepper.ts`.

Owns:
- prompt shaping for `plan`, `review`, `search`, `patch`, and `prompt`
- the `sherpa_plan` and `sherpa_append_stops` tools used during reviews
- the `sherpa_clarify` tool used during `prompt` and `patch` for
  mid-turn questions, plan proposals, and yes/no confirmations
- read-only guardrails for plan / review / search
- widget/status updates for Neovim (model, context usage, running cost)
- `/models` and `/tree` commands that drive fuzzy pickers via
  `ctx.ui.select` to switch models or jump through the session tree
- `/q-anchor` and `/q-end` commands used by `:SherpaQ` to capture the
  current leaf messageId and later navigate the tree back to it so a
  tangent drops off the active path

## Core flows

### Search

1. user runs `:SherpaSearch <prompt>`
2. plugin sends `/search <prompt>`
3. extension constrains the model to structured search output
4. plugin parses result lines
5. results open through telescope/fzf when available for a consistent selection flow
6. without a picker, Sherpa falls back to quickfix and jumps/highlights the lone match when only one exists

## Review

Reviews are pre-planned. The model commits to a full list of stops up
front via the `sherpa_plan` tool; the plugin then walks that fixed list.

1. user runs `:SherpaReview <prose>` (optionally with a visual range)
2. plugin opens the review pane in a "planning..." state and sends
   `/plan <prose>` to the extension
3. extension's `plan` command tells the model to produce a plan. The model
   reads code as needed, then calls the `sherpa_plan` tool with:
   - `scope`: `"selection"`, `"diff"`, or `"free"` (model self-labels)
   - `base`: required when scope is `"diff"`
   - `stops`: ordered list of
     `{path, startLine, endLine, title, why, explanation}` — the
     explanation is pre-written at plan time, 2-4 sentences per stop
4. plugin ingests the plan, renders the TOC in the review pane, and
   focuses stop 1. The sidebar shows stop 1's pre-written explanation
   immediately — no follow-up model turn.
5. `:SherpaNext` / `:SherpaPrev` advance through the fixed plan. Each
   move is a local index change plus a buffer jump — instant, no model
   call. The sidebar flips to the pre-written explanation for the new
   stop.
6. `:SherpaReview <question>` with an active review is the only way to
   trigger a per-stop model call. It sends `/review ...` scoped to the
   current stop, carrying the question.
7. during a free-scope review, the model may call `sherpa_append_stops`
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

1. user visually selects a range
2. user runs `:SherpaPatch <prompt>`
3. plugin sends `/patch ...` with file, line range, and excerpt context
4. tool events update the file jump and edit highlighting
5. edited ranges remain highlighted after the patch

### Tangent

`:SherpaQ` opens a tangent: a mini-conversation that reuses the main
chat surfaces but is dropped from the active session path on end. The
tree does the isolation; the UI stays single-pane.

1. user runs `:SherpaQ [prompt]` (optionally with a visual range)
2. plugin sends `/q-anchor` to the extension; extension responds with
   the current leaf messageId via `setStatus("sherpa-q-anchor", ...)`
3. plugin stores the anchor and flips `q_active = true`; the compose
   winbar gains a `[Tangent]` badge
4. if the user provided a prompt, plugin dispatches it as `/prompt ...`
   (with an excerpt block when a range was given); otherwise plugin
   opens the compose buffer so the user can type
5. while `q_active` is true, compose sends route as tangent follow-ups
   through `/prompt`; a one-shot stashed range is consumed on the
   first send to include the excerpt
6. re-invoking `:SherpaQ` with no args ends the tangent: plugin sends
   `/q-end <anchor>`, extension calls `ctx.navigateTree(anchor)`. The
   tangent's messages remain in pi's session graph (visible via
   `/tree`) but are no longer on the leaf path.
7. any other `:Sherpa*` command implicitly ends an active tangent
   first via the `send()` guard (skipped when the caller passes
   `is_q = true`)

Tangent state lives only in the Neovim session — the extension owns no
tangent concept beyond the two command handlers. Tree navigation is
idempotent: ending a tangent that never produced a message is a no-op
because `navigateTree(currentLeaf)` returns early.

### Chat

1. user runs `:SherpaChat` (no args) to open the log + compose surfaces,
   or `:SherpaChat <message>` to send directly
2. plugin sends `/prompt <message>` if no request is pending, or
   `/steer <message>` to redirect a running turn
3. assistant handles the request under the user's global pi system
   prompt; Sherpa adds no mode-specific guidance beyond making
   `sherpa_clarify` available
4. the compose buffer persists across sends; user can fire off steers
   any time, even while a reply is streaming
5. user can follow up with `:SherpaReview` to walk through the result

## Review state model

Sherpa keeps local review state in the Neovim session.
A review session tracks:
- review items
- current index
- local comments
- per-item explanation text
- end-of-review summary state

Comments are local today, but the data shape leaves room for future GitHub review mapping.

## UI surfaces

### Code window

The source of truth for the currently reviewed or edited range.
Sherpa jumps here and highlights the active region.

### Review pane

Buffer name:
- `sherpa://review`

Purpose:
- show one active review item
- show the current explanation
- show excerpt and item-local comments
- show the end-of-review summary
- show busy state while waiting for agent responses

### Log buffer

Buffer name:
- `sherpa://log`

Purpose:
- keep the full transcript, tool activity, and stderr
- useful for debugging and history
- toggled via `:SherpaChat` along with compose
- not the primary pairing surface during review

### Input editor

Buffer names:
- `sherpa://prompt` — used by `:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`
- `sherpa://compose` — persistent user input buffer used by `:SherpaChat`
- `sherpa://comment` — used by `:SherpaComment`
- `sherpa://clarify` — used by the `sherpa_clarify` tool during `prompt` / `patch` turns

A centered floating scratch buffer that opens when any text-input command is
called with no arguments. Renders per-command guidance as `Comment`-highlighted
virtual lines plus a `<C-s> to submit · <Esc><Esc> to cancel` hint.
Non-empty arguments still dispatch directly — the editor is purely for the
no-args path. For `:SherpaReview`, the editor has two modes: when no review is
active, the first word is parsed as a scope key; when a review is active, the
text is treated as a question about the current review item.

## RPC events used by the plugin

### From pi

- `message_end`
  - capture assistant text
  - update log
  - update review pane when the response belongs to review
- `tool_execution_start`
  - log tool usage
  - track touched paths
- `tool_execution_end`
  - jump to files
  - highlight read/edit/write ranges
- `extension_ui_request`
  - `notify` / `setStatus` / `setWidget` / `setTitle` — fire-and-forget
    UI updates. `setWidget` payloads are flattened into the log
    window's winbar. Two `setStatus` keys have plugin-side semantics:
    `sherpa-q-anchor` routes to a pending `:SherpaQ` callback (carries
    the captured leaf messageId), and `sherpa-q` drives the
    `[Tangent]` badge in the compose winbar.
  - `editor` — open a floating scratch editor with a prefill; plugin
    replies via `extension_ui_response` with `{value}` on submit or
    `{cancelled: true}` on cancel. Plan-proposal titles tagged with a
    `[sherpa-plan-proposal]` sentinel route through a read-only
    preview + accept/modify/reject picker.
  - `confirm` — yes/no picker via `vim.ui.select`; plugin replies with
    `{confirmed: bool}` or `{cancelled: true}`.
  - `select` — fuzzy picker via telescope / fzf-lua / `vim.ui.select`
    fallback; plugin replies with `{value}` or `{cancelled: true}`.
  - `input` — single-line input via `vim.ui.input`; plugin replies
    with `{value}` or `{cancelled: true}`.

### To pi

- `prompt` — user prompt message (slash-commands are passed through
  verbatim so pi routes them to the matching extension command; other
  text is wrapped in `/prompt`)
- `steer` — mid-turn user redirect delivered after the current assistant
  turn's tool calls complete. Slash-commands are rejected as steers
  (pi forbids them).
- `extension_ui_response` — reply to an awaiting `extension_ui_request`
  (carries the request `id` plus `value` / `confirmed` / `cancelled`)

## File/range heuristics

Sherpa currently keys off explicit tool paths only:
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
- tangent branching via `:SherpaQ` (tree anchor at start, navigate-back
  on end; `[Tangent]` badge in compose winbar while active)
- fast fake-backend tmux e2e tests
- optional real-pi smoke tests on bundled fixture projects

Still rough:
- the review pane can be polished further
- review summaries depend heavily on model quality
- code restoration is not implemented

## Related docs

- `docs/review-mode.md`
- `docs/plan.md`
- `tests/README.md`
