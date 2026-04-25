# Review Start/End Without Auto-Opening Log

## Proposal

- Date proposed: 2026-04-24
- Implementation status: done

## Goal

Keep `:SherpaReview` centered on the review pane. Starting a review and
finishing a review should not open `sherpa://SherpaLogReview`; the review log is
diagnostic and should only appear when the user explicitly runs
`:SherpaLogReview`.

The end of a review should also be clearer: the user should see an explicit
final state in `sherpa://review`, including whether unresolved comments were
summarized and whether the summary was forwarded into the main chat transcript.

## Implementation Plan

1. Stop automatic review-log opens.
   - Remove `ui.open_log(..., "review")` from review start paths in
     `lua/sherpa/review.lua`.
   - Make review-lane sends able to run without opening the log.
   - Use hidden transcript writes for user/debug/comment blocks so session
     history is still recorded.
   - Do not force-close a manually opened `:SherpaLogReview` when the review
     summary is completed.

2. Preserve necessary answer visibility.
   - Review start and review end should use only `sherpa://review`.
   - Plain mid-review questions can continue using the existing review answer
     path until they get a richer in-review rendering surface.
   - Ranged questions continue rendering inline over the selected range.

3. Improve final review-pane messaging.
   - Render completed reviews with an explicit complete heading/state.
   - Show accepted count and unresolved comment count.
   - Show the final summary in the review pane.
   - Mark when the summary has been forwarded to the main chat transcript.
   - Replace active navigation controls with final-state next actions.

4. Tests.
   - Add tmux coverage that free/selection review start does not create a
     visible `sherpa://SherpaLogReview` window.
   - Add tmux coverage that review end, both with and without unresolved
     comments, leaves the review log closed while the final pane is populated.
   - Add a manual-log regression: if the user opens `:SherpaLogReview`, review
     completion should not close it.
   - Add render-unit coverage for completed review final messaging.

5. Documentation.
   - Update `docs/review-mode.md` to say the review log is manually toggled
     diagnostics and review start/end stay in `sherpa://review`.

## Implementation Notes

- Implemented review start/end no-log behavior on 2026-04-24.
- Review planning, selection-review startup, retry, and end-of-review summary
  dispatch now run without opening `sherpa://SherpaLogReview`.
- Review transcript/debug blocks are still written to the hidden review log.
- Manually opened `:SherpaLogReview` windows are no longer force-closed when a
  summary completes.
- Completed reviews render `# Sherpa Review Complete`, final summary state, and
  final next actions in `sherpa://review`.

## Validation

- `luajit -b lua/sherpa/review.lua /tmp/sherpa-review.luac`
- `luajit -b lua/sherpa/review/render.lua /tmp/sherpa-review-render.luac`
- `luajit -b lua/sherpa/init.lua /tmp/sherpa-init.luac`
- `python3 -m unittest tests.test_review_render`
- `python3 -m unittest tests.test_tmux_review`
- `python3 -m unittest tests.test_plan_helpers`
- `python3 -m unittest tests.test_tmux_popups`
- `python3 -m unittest tests.test_tmux_log_rendering`

## Future Enhancement

Consider an editable final summary surface before forwarding to main chat:

- `sherpa://review-final` or a modifiable final mode inside `sherpa://review`.
- The agent-generated summary lands there first.
- `<C-s>` forwards the edited summary to the main chat transcript.
- Cancel leaves it in the review pane without forwarding.

This is intentionally separate from the first implementation chunk so the log
behavior and final-state messaging can land independently.
