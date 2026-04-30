# Q follow-ups in split answer view

- Implementation status: implemented in Strider split answer flow.

## Goal

Bring follow-up questions back to the new `:StriderQ` answer-on-demand flow
without reintroducing disruptive floating answer cards.

## Current state

- `:StriderQ` asks a quick side question on its own Q worker lane.
- Each Q chooses a per-question model preset: `fast` or `deep`.
- Answers do not auto-open UI; completion sends a low-disruption cue.
- `:StriderQLatest` opens the newest Q answer directly in a normal split.
- `:StriderQs` opens a picker, and selecting a Q opens the answer in a normal
  split.
- The old expanded Q card follow-up compose was intentionally left behind.

## Desired UX

Inside a Q answer split:

- `a` opens the lightweight Q prompt for a follow-up.
- The prompt is pre-scoped to the selected Q record.
- Submit sends the follow-up to the same Q worker/card.
- The follow-up inherits the original Q model preset (`fast` or `deep`).
- The answer buffer updates as a threaded conversation with the new turn.
- Follow-up question rows use a distinct `↳` marker/highlight from the initial
  `›` prompt.
- `q` still closes the split only.
- `d` still dismisses the whole Q record.
- `o` still opens that Q worker log.
- `:StriderQLatest` skips the picker and opens the newest Q answer split.

## Minimal implementation plan

1. Add answer-split keymaps
   - In the Q answer buffer/window path, map `a` to start a follow-up.
   - Reuse the existing lightweight prompt editor rather than a split-local
     compose buffer.

2. Route follow-ups to the existing Q record
   - Add a helper like `ui.open_q_followup_prompt(card_id, lane)` or expose a
     Strider-level function that receives the selected card id.
   - Reuse `strider.q_followup(text, card_id)` for dispatch.

3. Preserve model choice
   - Store `model_label` on Q records, already present from the Q model work.
   - Follow-up dispatch should pass that label through so future display and
     worker metadata remain consistent.
   - Since the follow-up uses the same worker lane, no new worker model startup
     is needed.

4. Keep answer rendering threaded
   - Existing Q card state already supports multiple turns.
   - Ensure the normal split answer view re-renders expanded/threaded content
     after follow-up streaming and completion.
   - Render follow-up prompt markers/highlights distinctly from initial prompts.

5. Test coverage
   - Open a completed Q via `:StriderQs` into a normal split.
   - Press `a`, submit a follow-up, and assert:
     - the same worker log receives the follow-up
     - the same answer buffer contains both turns
     - the follow-up row uses the `↳` marker/highlight
     - no floating Q answer/card is opened
     - the split remains a normal window
   - Add a model inheritance assertion if practical.

## Non-goals for this pass

- No full Q inbox buffer yet.
- No persistent split-local compose surface yet.
- No automatic answer window on Q completion.
- No return to floating expanded Q cards.

## Later possibility

Replace the picker-first `:StriderQs` flow with a normal `strider://QInbox`
buffer that lists all Qs and expands/collapses answers in place.
