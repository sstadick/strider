# Strider UX Improvements

## Proposal

- Date proposed: 2026-04-23
- Implementation status: partial

## Priority Now

1. Make `:StriderNext` end behavior clearer with a final finish-review card before summary generation.
2. Keep the review API minimal: no new command; reuse `:StriderNext` / `:StriderNext!` for finish confirmation.
3. Show accepted, reviewed, and commented counts on the finish-review card so the user knows what will be summarized.

## Backlog

1. Make active state impossible to miss: show idle, running, waiting for clarify, stopped, and failed states consistently.
2. Improve review stop acceptance: distinguish accepted stops from merely visited stops without adding another top-level command.
3. Add review progress persistence: restore comments, accepted stops, current index, and summary state after interruption.
4. Better pending-turn controls: expose `:StriderStop`, retry, steer, and clarify behavior while a turn is running.
5. Clarify flow polish: show a compact waiting card outside the transcript, not just a log block.
6. Review pane hierarchy: tighten the current stop card and make bulky excerpt or TOC sections less dominant.
7. Inline annotation affordances: distinguish the planned stop annotation from a ranged follow-up answer.
8. Search result confidence: mark exact, likely, and weak matches in picker or quickfix labels.
9. Patch preview and confirm: require explicit acceptance when a patch escapes the selected range.
10. Model and context affordance: provide a `:StriderStatus` command for lane, model, thinking, context, pending request, and last error.
11. Session tree ergonomics: make `/tree` labels clearer for branches, forks, and the current leaf.
