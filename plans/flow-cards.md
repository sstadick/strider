# Flow Cards Plan

## Proposal

- Date proposed: 2026-04-27
- Implementation status: partially superseded. Named Q records and background
  patch summaries shipped, but Q answers now open on demand in normal splits via
  `:StriderQLatest`/`:StriderQs` instead of auto-visible right-edge cards. The
  card-stack UX below is preserved as design history.

## Goal

Turn the current single `strider://StriderQAnswer` surface into a reusable
**flow card** system for Q-worker work (and later possibly search). Patch work
uses background summaries instead of card containers so patch results remain
visible on demand without adding right-edge chrome.

The shipped model:

- Flow work runs on dedicated worker lanes: search (`flow`), patch (`patch`),
  and one Q worker per StriderQ answer (`q`, `q-2`, `q-3`, ...).
- `:StriderLogFlow`, `:StriderLogQ`/`strider://StriderLogQ-N`, and
  `:StriderLogPatch` are the complete audit/debug transcripts.
- Q answers do not auto-open UI; completion leaves a low-disruption cue.
  `:StriderQLatest` and `:StriderQs` open answer records in normal splits.
- In an answer split, `a` opens a follow-up prompt on the same Q worker.
- Patch requests run in the background like Qs and create pull-up summaries;
  `:StriderPatches`/`:StriderPatchLatest` open them in normal splits instead of
  right-edge card containers. Main chat hides its split surfaces without leaving
  a visible compact placeholder.

Historical target UX:

## Target UX

### Folded card stack

Cards stack on the right edge, newest near the bottom:

```text
┌─ StriderQ #1 ─────────────────────┐
│ › why is this flag here?          │
│ ───────────────────────────────── │
│ Answer ready — focus to expand    │
└───────────────────────────────────┘

┌─ Strider patch ───────────────────┐
│ › change hi to hello              │
│ ───────────────────────────────── │
│ Patch complete — focus to expand  │
└───────────────────────────────────┘
```

Rules:

1. Folded cards are small, currently 3 content lines plus border/winbar.
2. Cards never steal focus when created or updated.
3. Running cards show the active `Working` winbar and the flow stop hint:
   `:StriderStopFlow to interrupt`.
4. Completed cards stay visible until dismissed or displaced by stack limits.
5. Only one card expands at a time.

### Expanded card

When focused, the selected card snaps to the right side and expands to nearly the
full editor height:

```text
┌─ StriderQ #1 ─────────────────────────────────────┐
│ Working/ready winbar or card status                │
│                                                    │
│ › why is this flag here?                           │
│ ───────────────────────────────────────────────── │
│                                                    │
│ This flag controls whether...                      │
│ ...                                                │
└────────────────────────────────────────────────────┘
```

Expansion should be a float first, not a real split, so the user's editing layout
is not rearranged. A future version can offer a split/drawer mode if the float
feels too transient.

## Card Kinds

### Q card

Purpose: focused answer surface.

Folded body:

- one-line preview of the question
- divider
- `Waiting for Strider…`, `Answer streaming — focus to expand`,
  `Answer ready — focus to expand`, or error/cancel status

Expanded body:

- full question pinned at the top
- assistant answer text only
- no thinking/reasoning
- no tool calls or tool output
- separate follow-up compose float beneath the answer; `<C-s>` sends the draft
  as another Q prompt on the same card worker

`:StriderLogQ` still contains the full Q transcript.

### Patch summary

Purpose: make completed patch work reviewable without opening the full flow log.
Patch summaries are recorded in the background and opened on demand in normal
splits.

Summary body:

- patch request and target range/file
- files touched
- edit/diff rows
- final assistant summary
- enough tool/log context to understand what changed

Implemented decision: patch summaries use a **curated patch log**. They include
the request, target, inspected/touched files, edit activity, diff blocks, and
final summary. Thinking, verbose read output, and full tool details remain in
`:StriderLogPatch`.

### Search card (later)

Search already has picker/quickfix surfaces, so defer this unless Q cards and
patch summaries feel good. If added, a search card should show query, result
count, and top matches, with focus opening the picker or expanding a result
summary.

## State Model

Add flow-card state to the flow session:

```lua
flow_cards = {
  {
    id = "flow-card-1",
    kind = "q" | "patch" | "search",
    operation = "q" | "patch" | "search",
    title = "StriderQ",
    prompt = "...",
    status = "running" | "success" | "error" | "cancelled",
    answer_text = "...",       -- Q only / assistant-only text
    body_lines = { ... },       -- rendered expanded body for patch/search
    summary = "...",           -- folded status/detail
    started_at = hrtime,
    finished_at = hrtime | nil,
    log_start_row = number | nil,
    log_end_row = number | nil,
    win = number | nil,
    buf = number | nil,
  },
}
active_flow_card_id = "flow-card-1" | nil
flow_card_seq = 0
```

Notes:

- Cards are UI/session state, not persisted to pi history in v1.
- Keep the latest N visible cards; retain older cards in memory for a command or
  picker if cheap.
- Use card ids rather than relying on buffer names, because multiple cards of
  the same kind can exist.

## Layout Model

Implement a right-edge card manager.

Folded layout:

- width: current Q-card width policy is acceptable initially
  (`min(88, max(42, editor_width * 0.42))`)
- height: 3 content rows
- anchor: right edge
- order: newest at bottom, older cards stacked above
- gap: 1 row between cards if space permits
- overflow: hide oldest visible cards first, but keep them in card state

Expanded layout:

- selected card gets higher `zindex`
- width: same right-side width for v1
- height: `editor_height - margin`
- row: top margin, e.g. `1`
- col: right edge
- all other cards remain folded behind/above/below as practical
- leaving the expanded card preserves expansion; explicit `q` / `<Esc>` folds it

Autocmds:

- `WinEnter`, `BufEnter`: pin the focused card as expanded
- `WinLeave`, `WinClosed`, `VimResized`: reflow without auto-folding the pinned card
- `WinClosed`: clear dead window handles and reflow
- `VimResized`: recompute all card positions

Use a plugin-private augroup such as `StriderFlowCardsLayout` and Lua-local
helpers. No Neovim convention requires `_` for internal autocmd callbacks; local
functions plus a plugin-prefixed augroup are the normal pattern.

## Implementation Plan

### Phase 1 — Extract current Q answer surface into flow cards

1. Create `lua/strider/ui/flow_cards.lua` or similar.
   - Move the current Q answer card logic out of `ui.lua`.
   - Keep `ui.lua` as a thin facade if existing callers expect
     `ui.open_q_answer`, `ui.update_q_answer`, etc.
2. Introduce a generic card API:
   - `create_card(kind, opts, lane)`
   - `update_card(id, fields, lane)`
   - `reflow(lane)`
3. Preserve the then-current Q-card behavior during the refactor:
   - bottom-right folded card
   - answer-only expanded Q card
   - flow-log transcript unchanged
   - `:StriderStopFlow` winbar hint

### Phase 2 — Multiple Q records

Status: implemented, with answer display moved to normal splits.

Implemented:

1. Each submitted `:StriderQ` prompt creates a named answer record instead of
   reusing the previous answer.
2. The first record keeps the compatibility buffer `strider://StriderQAnswer`;
   later records use `strider://flow-card/q/N`.
3. Q records do not auto-open UI; completion leaves a low-disruption cue.
4. Each new Q record gets its own worker lane; text deltas and final text route
   through the pending request's `card_id`/`card_lane`.
5. `:StriderQ` opens the Q prompt editor; `:StriderQ!` is equivalent and kept
   for muscle memory.
6. `:StriderQLatest` opens the newest answer directly, `:StriderQs` opens a
   Q-only picker, and `:StriderCards` opens a telescope/fzf/`vim.ui.select`
   picker for named records/summaries.
7. In an answer split, `a` opens a follow-up prompt, `q` closes the split, `d`
   dismisses the record, `o` opens its worker log, and `[c`/`]c` navigate Q
   records.

### Phase 3 — Patch summaries

Status: implemented in-process for `:StriderPatch`.

1. A background patch summary is created when `:StriderPatch` submits.
2. The pending patch request stores the summary id in metadata.
3. Tool-end events record inspected/touched files and edit diff blocks on the
   summary.
4. Message completion finalizes the summary with success/error/cancel state and
   the assistant summary.
5. Verbose read output and reasoning stay in `:StriderLogPatch`.

### Phase 4 — Navigation and history controls

Implemented:

- `:StriderQLatest` — opens the newest StriderQ answer in a normal split.
- `:StriderQs` — picker for named StriderQ answers.
- `:StriderCards` — picker for all named chat/Q/patch records.
- `:StriderCardsClear[!]` — dismiss completed surfaces; bang includes running
  surfaces.
- Answer-split mappings:
  - `a`: ask a follow-up on the same Q worker
  - `q`: close the split
  - `d`: dismiss the record
  - `o`: open the record's worker log
  - `]c` / `[c`: open next/previous Q record

## Tests

Current coverage lives in:

1. `tests/test_tmux_tangent.py`
   - Q answers do not auto-open UI.
   - `:StriderQs`/`:StriderQLatest` open answers in normal splits.
   - Follow-ups reuse the same Q worker and render with the `↳` marker.
2. `tests/test_tmux_flow_cards.py`
   - Named card/record picker behavior and dismissal.
3. `tests/test_tmux_popups.py`
   - Q prompt editor and model-toggle behavior.
4. `tests/test_tmux_log_rendering.py`
   - Worker logs retain full reasoning/tool transcripts.
5. Patch summary coverage
   - `:StriderPatchLatest`/`:StriderPatches` open request, target, diff rows,
     and summary in normal splits while `:StriderLogPatch` keeps the transcript.

## Documentation

Current user-facing docs are in `README.md`, `docs/usage.md`, and
`docs/architecture.md`. The split-answer follow-up design is tracked in
`plans/q-followups-in-splits.md`.

## Open Questions

1. Should Q answer state persist across Neovim restarts? Recommendation: no for
   v1; pi session history remains the durable transcript.
2. Should `:StriderQs` eventually become an inbox buffer instead of a picker?
3. Should search grow a persistent result surface, or are picker/quickfix enough?

## Validation Commands

When implemented, run at least:

```sh
python3 -m unittest tests.test_tmux_tangent -v
python3 -m unittest tests.test_tmux_popups -v
python3 -m unittest tests.test_tmux_log_rendering -v
```

For the full suite:

```sh
python3 -m unittest discover -v
```
