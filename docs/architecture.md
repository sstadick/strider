# Architecture

## Current product model

Sherpa is now built around four primary user flows:

- `:SherpaSearch {prompt}`
- `:SherpaReview [scope] [prompt]`
- `:'<,'>SherpaPatch {prompt}`
- `:SherpaWork {prompt}`

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
- prompt shaping for `search`, `teach/review`, `patch`, and `work`
- read-only guardrails for search/review
- widget/status updates for Neovim

## Core flows

### Search

1. user runs `:SherpaSearch <prompt>`
2. plugin sends `/search <prompt>`
3. extension constrains the model to structured search output
4. plugin parses result lines
5. single match jumps directly to the file
6. multiple matches open telescope/fzf when available, otherwise quickfix

## Review

1. user runs `:SherpaReview file|diff|last|searches`
2. plugin builds local review items
3. Sherpa opens the dedicated review pane and highlights the active range
4. plugin sends `/teach ...` for the active review item
5. assistant explanation is written both to the log and the review pane
6. `:SherpaNext` / `:SherpaPrev` move through items
7. unresolved comments are summarized back to the agent at review end

Important UX rule:
- the review pane is the primary explanation surface
- the log is secondary transcript/history

### Patch

1. user visually selects a range
2. user runs `:SherpaPatch <prompt>`
3. plugin sends `/patch ...` with file, line range, and excerpt context
4. tool events update the file jump and edit highlighting
5. edited ranges remain highlighted after the patch

### Work

1. user runs `:SherpaWork <prompt>`
2. plugin sends `/work <prompt>`
3. assistant may make broader changes than patch mode
4. user reviews the result with `:SherpaReview diff` or `:SherpaReview last`

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
- can be reopened with `:SherpaLog`
- not the primary pairing surface during review

### Input editor

Buffer names:
- `sherpa://prompt` — used by `:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`, `:SherpaWork`
- `sherpa://comment` — used by `:SherpaComment`

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
  - status + widget updates from the extension

### To pi

- `prompt`

## File/range heuristics

Sherpa currently keys off explicit tool paths only:
- `read.path`
- `edit.path`
- `write.path`

Shell parsing remains intentionally lightweight.

## Current implementation status

Working today:
- structured search with picker + quickfix behavior
- explicit review scopes
- dedicated review pane
- local review comments
- selection-scoped patching
- broader work requests
- fast fake-backend tmux e2e tests
- optional real-pi smoke tests on bundled fixture projects

Still rough:
- the review pane can be polished further
- review summaries depend heavily on model quality
- work mode is broader than patch mode but still lightweight
- code restoration is not implemented

## Related docs

- `docs/review-mode.md`
- `docs/plan.md`
- `tests/README.md`
