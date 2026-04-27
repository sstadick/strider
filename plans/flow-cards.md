# Flow Cards Plan

## Proposal

- Date proposed: 2026-04-27
- Implementation status: phase 1 implemented (Q answer surface extracted to flow-card manager)

## Goal

Turn the current single `strider://StriderQAnswer` surface into a reusable
**flow card** system for flow-lane work (`Q`, patch, and later search). Flow
cards should make flow-lane results visible without forcing the user into the
full `:StriderLogFlow` transcript.

The working model:

- Flow work still runs on the dedicated flow lane.
- `:StriderLogFlow` remains the complete audit/debug transcript.
- Each completed or running flow request gets a compact card on the right.
- Cards stay folded until the user focuses/selects one.
- Focusing a card expands it into a near full-height right-side panel.
- Leaving the card folds it back down.

## Target UX

### Folded card stack

Cards stack on the right edge, newest near the bottom:

```text
┌─ Strider Q ───────────────────────┐
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
┌─ Strider Q ───────────────────────────────────────┐
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

`StriderLogFlow` still contains the full Q transcript.

### Patch card

Purpose: make completed patch work reviewable without opening the full flow log.

Folded body:

- one-line preview of the patch request
- divider
- `Patch running…`, `Patch complete — focus to expand`, or error/cancel status

Expanded body, v1 target:

- patch request and target range/file
- files touched
- edit/diff rows
- final assistant summary
- enough tool/log context to understand what changed

Open decision: whether the patch card should literally mirror the full
`StriderLogFlow` slice for that patch, including read/tool output, or use a
curated patch transcript that excludes thinking and low-value tool noise. The
initial recommendation is **curated patch log**: include request, tool headers,
edits/diffs, and final summary; keep thinking and verbose read output in
`:StriderLogFlow`.

### Search card (later)

Search already has picker/quickfix surfaces, so defer this unless Q/Patch cards
feel good. If added, a search card should show query, result count, and top
matches, with focus opening the picker or expanding a result summary.

## State Model

Add flow-card state to the flow session:

```lua
flow_cards = {
  {
    id = "flow-card-1",
    kind = "q" | "patch" | "search",
    operation = "q" | "patch" | "search",
    title = "Strider Q",
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
- leaving the expanded card reflows it back into the folded stack

Autocmds:

- `WinEnter`, `WinLeave`, `BufEnter`: expand/fold cards based on focused window
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
   - `finish_card(id, status, fields, lane)`
   - `reflow(lane)`
3. Preserve current Q behavior exactly:
   - bottom-right folded card
   - answer-only expanded Q card
   - flow-log transcript unchanged
   - `:StriderStopFlow` winbar hint

### Phase 2 — Multiple Q cards

1. On every `:StriderQ` submit, create a new card instead of reusing
   `strider://StriderQAnswer`.
2. Give each card its own scratch buffer name, e.g.
   `strider://flow-card/q/1`.
3. Stack folded cards bottom-right.
4. Route text deltas and final text to the active request's card id.
   - Store `card_id` in `pending_request.metadata` or directly on pending state.
5. Add basic card dismissal inside focused cards:
   - `q` or `d` closes/dismisses the focused card
   - optional `o` opens `:StriderLogFlow`

### Phase 3 — Patch cards

1. Create a patch card when `:StriderPatch` submits.
2. Capture enough per-request transcript data to render an expanded patch card.
   Options:
   - v1-simple: record flow log start/end rows and copy that slice into the
     card on completion.
   - v1-polished: record structured patch events and render a curated patch
     transcript with existing diff renderer components.
3. Recommended first implementation:
   - request header + target file/range
   - tool headers for relevant reads/edits
   - inline diff rows from edit result details
   - final assistant summary
   - error/cancel block when applicable
4. Keep verbose read output and reasoning in `:StriderLogFlow` unless we decide
   the patch card should literally mirror the full flow-log slice.

### Phase 4 — Navigation and history controls

Add commands only once multiple cards exist:

- `:StriderFlowCards` — focus the newest visible flow card or open a picker of
  cards if none is visible.
- `:StriderFlowCardsClear` — dismiss completed cards.
- Optional mappings inside card buffers:
  - `q` / `<Esc>`: fold or close focused card
  - `d`: dismiss card
  - `o`: open `:StriderLogFlow`
  - `]c` / `[c`: focus next/previous card

## Tests

Add tmux tests around the card manager:

1. Q cards stack.
   - Run two Q requests sequentially.
   - Assert two card buffers/windows exist.
   - Assert both are folded and newest is lower/rightmost in the stack.
2. Q focus expands.
   - Focus a folded Q card.
   - Assert height is near full editor height.
   - Move focus away and assert it folds back.
3. Q answer remains answer-only.
   - Assert folded card only previews readiness.
   - Assert expanded card contains assistant answer.
   - Assert expanded card does not contain thinking/tool text.
   - Assert `:StriderLogFlow` still contains full transcript.
4. Patch card completion.
   - Run a selection-scoped patch.
   - Assert a folded patch card appears.
   - Focus it and assert request, target, diff rows, and summary are visible.
   - Assert `:StriderLogFlow` still contains full patch transcript.
5. Stop behavior.
   - Start a slow Q/Patch fake backend request.
   - Run `:StriderStopFlow`.
   - Assert the active card shows cancelled/stopped state.
6. Resize/reflow.
   - Trigger a resize or call reflow directly.
   - Assert cards remain anchored to the right edge and do not steal focus.

## Documentation

Update:

- `docs/usage.md`
  - Describe flow cards as the visible result surface for Q/Patch.
  - Clarify that `:StriderLogFlow` is still the complete transcript.
- `docs/architecture.md`
  - Add `flow_cards` as flow-lane UI state.
  - Explain card lifecycle and relationship to pending requests.
- `README.md`
  - Mention flow cards briefly in the feature list once patch cards land.

## Open Questions

1. Should patch cards literally include thinking/reasoning if the user says
   "full patch log", or should they remain curated and leave reasoning in
   `:StriderLogFlow`?
2. How many folded cards should remain visible before older cards collapse into
   history? Initial guess: fit as many 3-line cards as the editor height allows,
   but cap at 5–7 to avoid visual clutter.
3. Should card state persist across Neovim restarts? Recommendation: no for v1.
4. Should expanded cards stay floats, or should focusing a card eventually snap
   into a real right-side split/drawer? Recommendation: float first; split mode
   later only if the float feels unstable.
5. Should search use cards, or are picker/quickfix enough?

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
