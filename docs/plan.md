# Implementation plan

## Product goal

Sherpa is a linear, guided coding workflow for Neovim backed by pi.

The core loop is:

1. ask for a bounded change with `:SherpaQ`
2. let the agent make one chunk of progress
3. inspect the affected file in Neovim
4. either ask another follow-up with `:SherpaQ` or accept the chunk with `:SherpaNext`
5. repeat

## Command contract

### `:SherpaQ {request}`

Start or continue the current linear flow.

Expected behavior:
- start the backend if needed
- initialize workflow state on the first request
- reuse the current chunk context on later requests
- answer directly when the request is explanatory
- make one bounded chunk of progress when the request asks for code changes
- stop again after the chunk

### `:SherpaNext`

Accept the current chunk and continue linearly.

Expected behavior:
- label the current accepted chunk in pi history
- increment the checkpoint count
- ask pi for the next bounded chunk
- stop again after completion

## Architecture split

### Neovim side

Lives in Lua.

Responsibilities:
- spawn and manage the pi RPC process
- send prompts
- stream and parse RPC events
- jump to touched files
- highlight changed chunks
- surface the conversation log in Neovim

### pi extension side

Lives in TypeScript.

Responsibilities:
- define the linear workflow state machine
- persist workflow state
- label accepted checkpoints in pi history
- shape prompts for bounded chunk behavior
- keep the model from running too far ahead

## Data flow

### Q flow

1. `:SherpaQ ...`
2. plugin sends `/question ...`
3. extension either starts the flow or continues the current chunk
4. pi answers or edits
5. plugin updates the log, jumps to touched files, and highlights the chunk

### Next flow

1. `:SherpaNext`
2. plugin sends `/next`
3. extension labels the last assistant chunk as `chunk-N`
4. extension increments the linear chunk counter
5. pi executes the next bounded chunk
6. plugin updates the log, jumps to touched files, and highlights the result

## Phase plan

### Phase 1: transport skeleton

Goal: prove Neovim can drive pi.

Status:
- complete

Shipped:
- backend spawn from Neovim
- prompt sending over RPC
- JSONL event handling
- scratch log buffer output
- Neovim commands

### Phase 2: linear workflow state

Goal: simplify Sherpa to a linear chunk loop.

Status:
- complete for the first usable version

Shipped:
- `SherpaQ` as the only active request command
- `SherpaNext` as the accept-and-continue command
- extension-managed linear workflow state
- accepted chunk labeling through pi history

Still to do:
- stronger checkpoint summaries
- clearer checkpoint presentation in Neovim

### Phase 3: file-aware UX

Goal: make the editor feel connected to the active chunk.

Status:
- in progress, already useful

Shipped:
- explicit path tracking for `read`, `edit`, and `write`
- jump on touched files
- jump to the first changed line for edits when pi reports it
- gutter markers for changed lines
- improved write completion ordering before opening new files

Still to do:
- highlight or preview the changed range more clearly
- smooth out edge cases around brand new files and multi-step writes

### Phase 4: checkpoint UX

Goal: make accepted checkpoints visible and useful without pretending code restoration exists yet.

Status:
- started conceptually, not exposed yet

Planned:
- sidebar or buffer view of accepted checkpoints
- summary text per checkpoint
- light navigation over checkpoint history

Important constraint:
- use pi's built-in history as the source of truth
- do not imply workspace rewind until code restoration exists

### Phase 5: future code restoration

Goal: make checkpoint navigation materially useful.

Future directions:
- git checkpoints per accepted chunk
- patch or snapshot restoration
- richer use of pi history and `/tree` after code restoration exists

## Current stopping point

Sherpa now has the right control shape for the intended workflow:
- linear by default
- one active request command
- one accept-and-continue command
- built on pi's native history so future restoration work has a solid base

The next useful work should focus on UX refinement, not more control surface:
- checkpoint presentation
- better summaries
- stronger changed-range feedback
- eventual code restoration support

## Constraints

- keep the workflow linear until code restoration exists
- rely on pi history instead of inventing a second history model
- prefer explicit `read`, `edit`, and `write` tool paths over shell parsing
- keep chunking rules in the pi extension, not in the Lua client
