# Implementation plan

## Product goal

Sherpa is a guided coding workflow for Neovim backed by pi.

The core loop is:

1. start a goal
2. let the agent make one bounded chunk of progress
3. inspect the affected file in Neovim
4. ask questions, request revisions, or continue
5. repeat until done

## Command contract

### `:SherpaStart {goal}`

Starts a guided workflow.

Expected behavior:
- ensure the pi RPC backend is running
- initialize or reset workflow state
- ask pi to create a short plan and execute only the first chunk
- stop after the first chunk and summarize

### `:SherpaQ {question}`

Ask about the current chunk without progressing the workflow.

Expected behavior:
- preserve the current step
- answer the question in context of the current chunk
- do not edit code by default
- do not mark a step done

### `:SherpaRevise {feedback}`

Request a refinement to the current chunk.

Expected behavior:
- preserve the current step
- rework the current chunk using the feedback
- stop again after the revision is complete

### `:SherpaNext`

Advance to the next bounded chunk.

Expected behavior:
- mark the current chunk done
- activate the next step
- perform one more bounded chunk
- stop again after completion

### `:SherpaStatus`

Show current workflow state.

Expected behavior:
- goal
- current step
- remaining steps
- last touched file if known
- recent summary if known

## Architecture split

### Neovim side

Lives in Lua.

Responsibilities:
- spawn and manage the pi RPC process
- send commands and prompts
- stream and parse RPC events
- jump to touched files
- surface assistant answers and workflow status in Neovim

### pi extension side

Lives in TypeScript.

Responsibilities:
- define the workflow state machine
- persist workflow state
- shape prompts for guided chunk behavior
- distinguish question turns from revision or progression turns
- keep the model from running too far ahead

## Data flow

### Start flow

1. `:SherpaStart ...`
2. plugin sends `/guide ...`
3. extension initializes workflow state
4. extension sends a structured user message to pi
5. plugin watches tool events and focuses touched files
6. plugin presents summary when the turn ends

### Question flow

1. `:SherpaQ ...`
2. plugin sends `/question ...`
3. extension builds a question-only prompt using:
   - goal
   - current step
   - last touched file
   - recent assistant summary
4. pi answers
5. plugin renders the answer in a scratch buffer or message log

### Revision flow

1. `:SherpaRevise ...`
2. plugin sends `/revise ...`
3. extension keeps the current step active
4. pi revises the chunk
5. plugin jumps to touched files and renders the follow-up summary

### Next flow

1. `:SherpaNext`
2. plugin sends `/next`
3. extension advances step state
4. pi executes the next chunk
5. plugin jumps to touched files and waits again

## Phase plan

### Phase 1: transport skeleton

Goal: prove Neovim can drive pi.

Build:
- spawn `pi --mode rpc`
- send a prompt
- read JSONL events
- log assistant output
- expose user commands in Neovim

Current status:
- complete

Shipped:
- backend spawn from Neovim
- prompt sending over RPC
- JSONL event handling
- scratch log buffer output
- user commands registered in Neovim

### Phase 2: guided workflow state

Goal: move workflow logic into the pi extension.

Build:
- `/guide`, `/question`, `/revise`, `/next`, `/status`
- persisted workflow state via extension entries
- status widget/state reconstruction on session start

Current status:
- first pass complete

Shipped:
- command split between question, revise, and next
- extension-managed workflow state
- question turns that do not progress the workflow
- status updates surfaced back to Neovim

### Phase 3: file-aware UX

Goal: make the editor feel connected to the active chunk.

Build:
- inspect `tool_execution_start` and `tool_execution_end`
- track `read`, `edit`, and `write` paths
- jump to touched files
- remember recent files

Current status:
- in progress, already useful

Shipped:
- explicit path tracking for `read`, `edit`, and `write`
- jump on touched files
- jump to the first changed line for edit results when pi reports it
- improved ordering for write completion before jumping to new files

Still to do:
- highlight or preview the changed range
- smooth out edge cases around brand new files and multi-step writes

### Phase 4: discussion and status surfaces

Goal: make question/answer and progress visible without leaving Neovim.

Build:
- scratch buffer for Sherpa log
- concise notifications for state changes
- optional floating status summary

Current status:
- first pass complete

Shipped:
- live Sherpa log buffer
- user messages written into the same conversation buffer
- log windows auto-scroll with the conversation
- status surfaced through notifications and extension widgets

Still to do:
- a cleaner persistent UI than raw notifications
- a dedicated status panel or floating summary

### Phase 5: polish

Build:
- keymaps
- improved plan extraction
- recent file list
- better step summaries
- optional quickfix integration
- changed-range highlighting or diff preview

## Stopping point for today

This is a good first vertical slice.

At the end of today's work Sherpa can:
- run pi from inside Neovim
- execute a guided chunk flow
- let the user ask non-progressing questions with `:SherpaQ`
- jump to files touched by the agent
- show a usable log of the interaction in a scratch buffer

The next session should focus on UX smoothing rather than basic plumbing:
- better changed-range presentation
- more reliable new-file handling in edge cases
- improved status and log presentation
- stronger step planning and summaries

## Constraints

- keep the first version simple and inspectable
- prefer explicit `read`, `edit`, and `write` tool paths over shell parsing
- avoid heavyweight custom UI until the RPC loop is stable
- keep chunking rules in the pi extension, not in the Lua client
