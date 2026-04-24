# Sherpa UX Improvements

## Priority Now

1. Unified status surface across `main`, `flow`, and `review`.
2. Review stop acceptance through `:SherpaNext!`, with accepted stops recorded in local session state.
3. Clearer waiting and clarify states in compose, review, and status surfaces.
4. Better pending-turn controls so users know whether typing will send, steer, answer clarify, or be blocked.

## Backlog

1. Make active state impossible to miss: show idle, running, waiting for clarify, stopped, and failed states consistently.
2. Improve review stop acceptance: distinguish accepted stops from merely visited stops without adding another top-level command.
3. Add review progress persistence: restore comments, accepted stops, current index, and summary state after interruption.
4. Make `:SherpaNext` end behavior clearer with a final finish-review card before summary generation.
5. Better pending-turn controls: expose `:SherpaStop`, retry, steer, and clarify behavior while a turn is running.
6. Clarify flow polish: show a compact waiting card outside the transcript, not just a log block.
7. Review pane hierarchy: tighten the current stop card and make bulky excerpt or TOC sections less dominant.
8. Inline annotation affordances: distinguish the planned stop annotation from a ranged follow-up answer.
9. Search result confidence: mark exact, likely, and weak matches in picker or quickfix labels.
10. Patch preview and confirm: require explicit acceptance when a patch escapes the selected range.
11. Model and context affordance: provide a `:SherpaStatus` command for lane, model, thinking, context, pending request, and last error.
12. Session tree ergonomics: make `/tree` labels clearer for branches, forks, and the current leaf.
