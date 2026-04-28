# Flow Cards Plan

## Proposal

- Date proposed: 2026-04-27
- Implementation status: Q answer cards, Q-card follow-up compose, bare `:StriderQ` card toggle, and patch cards are implemented in-process

## Goal

Turn the current single `strider://StriderQAnswer` surface into a reusable
**flow card** system for flow-worker work (`Q`, patch, and later search). Flow
cards should make flow-worker results visible without forcing the user into the
full worker transcript.

The working model:

- Flow work runs on dedicated worker lanes: search (`flow`), patch (`patch`),
  and one Q worker per StriderQ card (`q`, `q-2`, `q-3`, ...).
- `:StriderLogFlow`, `:StriderLogQ`/`strider://StriderLogQ-N`, and
  `:StriderLogPatch` are the complete audit/debug transcripts.
- Each completed or running flow request gets a compact card on the right.
- Cards stay folded until the user focuses/selects one.
- Focusing a card expands it into a near full-height right-side panel.
- Expanded cards remain open when focus returns to code.
- Pressing `q` or `<Esc>` in a card folds it back down; bare `:StriderQ` toggles
  the latest Q card up/down when a card exists.
- Expanded Q cards open a separate follow-up compose float under the answer;
  `<C-s>` submits that draft on the same card's Q worker.
- The compact main Chat placeholder shares the same right-edge stack slots as
  Q/Patch cards so compact surfaces do not overlap.

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

Implemented decision: patch cards use a **curated patch log**. They include the
request, target, inspected/touched files, edit activity, diff blocks, and final
summary. Thinking, verbose read output, and full tool details remain in
`:StriderLogPatch`.

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
   - `finish_card(id, status, fields, lane)`
   - `reflow(lane)`
3. Preserve current Q behavior exactly:
   - bottom-right folded card
   - answer-only expanded Q card
   - flow-log transcript unchanged
   - `:StriderStopFlow` winbar hint

### Phase 2 — Multiple Q cards

Status: partially implemented for named StriderQ card history.

Implemented:

1. Each submitted `:StriderQ` prompt creates a named card instead of reusing the
   previous card.
2. The first card keeps the compatibility buffer `strider://StriderQAnswer`;
   later cards use `strider://flow-card/q/N`.
3. Folded Q cards stack in the shared right-edge stack.
4. Each new Q card gets its own worker lane; text deltas and final text route
   through the pending request's `card_id`/`card_lane`.
5. Bare `:StriderQ` toggles the latest card; `:StriderQ!` opens a new prompt.
6. `:StriderCards` opens a telescope/fzf/`vim.ui.select` picker for named cards.
7. Card-local `d` dismisses a card and `o` opens its worker log.

### Phase 3 — Patch cards

Status: implemented in-process for `:StriderPatch`.

1. A patch card is created when `:StriderPatch` submits.
2. The pending patch request stores the card id in metadata.
3. Tool-end events record inspected/touched files and edit diff blocks on the
   card.
4. Message completion finalizes the card with success/error/cancel state and the
   assistant summary.
5. Verbose read output and reasoning stay in `:StriderLogPatch`.

### Phase 4 — Navigation and history controls

Implemented:

- bare `:StriderQ` — toggles/focuses the latest Q card, or folds it when already
  expanded; if no card exists it opens the original Q prompt.
- `:StriderCards` — picker for named card surfaces.
- `:StriderCardsClear[!]` — dismiss completed cards; bang includes running
  cards.
- Card-buffer mappings:
  - `q` / `<Esc>`: fold focused card
  - `d`: dismiss card
  - `o`: open the card's worker log
  - `]c` / `[c`: focus next/previous card in the lane

## Tests

Add tmux tests around the card manager:

1. Q cards stack.
   - Run two Q requests sequentially.
   - Assert two card buffers/windows exist.
   - Assert both are folded and newest is lower/rightmost in the stack.
2. Q focus expands and stays pinned.
   - Focus a folded Q card or run bare `:StriderQ` after a card exists.
   - Assert height is near full editor height.
   - Move focus away and assert it remains expanded.
   - Press `q` / `<Esc>` or run bare `:StriderQ` again and assert it folds back.
   - Type a Q-card follow-up and assert `<C-s>` sends it on that card's Q worker.
3. Q answer remains answer-only.
   - Assert folded card only previews readiness.
   - Assert expanded card contains assistant answer.
   - Assert expanded card does not contain thinking/tool text.
   - Assert `:StriderLogQ` still contains full transcript.
4. Patch card completion.
   - Run a selection-scoped patch.
   - Assert a folded patch card appears.
   - Focus it and assert request, target, diff rows, and summary are visible.
   - Assert `:StriderLogPatch` still contains full patch transcript.
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
  - Clarify that worker logs are still the complete transcripts.
- `docs/architecture.md`
  - Add `flow_cards` as flow-worker UI state.
  - Explain card lifecycle and relationship to pending requests.
- `README.md`
  - Mention flow cards briefly in the feature list once patch cards land.

## Open Questions

1. How many folded cards should remain visible before older cards collapse into
   history? Initial guess: fit as many 3-line cards as the editor height allows,
   but cap at 5–7 to avoid visual clutter.
2. Should card state persist across Neovim restarts? Recommendation: no for v1.
3. Should expanded cards stay floats, or should focusing a card eventually snap
   into a real right-side split/drawer? Recommendation: float first; split mode
   later only if the float feels unstable.
4. Should search use cards, or are picker/quickfix enough?

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
