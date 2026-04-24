# Compose Working Elapsed Time Plan

## Proposal

- Date proposed: 2026-04-24
- Implementation status: done

## Goal

Move the active-turn elapsed timer from the right side of the compose winbar to
sit directly next to the animated `Working` label.

Target active winbar shape:

```text
Working (<elapsed>)                                      :SherpaStop to interrupt
```

Examples:

```text
Working (0s)
Working (12s)
Working (1m04s)
```

## Implementation Plan

1. Update `lua/sherpa/ui.lua` in `compose_status_line()`.
   - Keep the animated/highlighted `Working` label from
     `compose_working_label(prefix, lane)`.
   - Format elapsed time with the existing `format_elapsed(progress.started_at)`.
   - Build the left side as `Working (<elapsed>)` by appending the escaped
     elapsed suffix after the statusline-highlighted working label.
   - Change the right side to only `:SherpaStop to interrupt`.

2. Preserve existing behavior.
   - Do not change idle compose winbar text.
   - Do not change clarify prefix handling.
   - Do not change the spin timer or elapsed formatting cadence.
   - Keep `left_is_statusline = true` for active progress because the working
     label still contains statusline highlight escapes.

3. Update comments in `lua/sherpa/ui.lua`.
   - Replace descriptions that call elapsed time a right-side suffix.
   - Describe the new layout as elapsed time next to `Working`, with the stop
     hint on the right.

4. Update tests in `tests/test_tmux_popups.py`.
   - In `test_compose_winbar_tracks_and_rotates_activity`, assert the winbar
     contains a `Working (` elapsed suffix shape.
   - Assert `:SherpaStop to interrupt` is still present.
   - Keep the existing wait that verifies the winbar changes as elapsed time or
     shimmer updates.

5. Run the focused test.
   - `pytest tests/test_tmux_popups.py -k compose_winbar_tracks_and_rotates_activity`
