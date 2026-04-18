# sherpa

Guided, chunked code generation for Neovim powered by pi.

## Idea

Sherpa is a thin Neovim frontend over a pi backend.

The goal is to make agentic coding feel more like pair programming:

1. describe the feature
2. let pi pick one small chunk
3. jump to the file being touched
4. make the edit
5. pause for questions, revisions, or adjustments
6. continue with `next`

This is intentionally not inline completion and not full-autopilot agent mode.
It is a guided stepper.

## MVP

Build the smallest useful loop:

- Neovim plugin starts pi in RPC mode
- pi extension owns workflow state
- user starts a guided task with a goal
- pi creates or tracks a short plan
- pi executes one chunk at a time
- plugin jumps to touched files and shows status
- user can say `q`, `next`, `revise`, or `status`

## Working model

### pi extension responsibilities

- track workflow state
- register commands like `/guide`, `/question`, `/next`, `/revise`, `/status`
- persist step state across session resume
- shape prompts so the model edits one bounded chunk at a time

### Neovim plugin responsibilities

- spawn `pi --mode rpc`
- send prompts and custom commands
- watch RPC events for file edits and queue status
- jump to files when `read` / `edit` / `write` tools target them
- present lightweight UX for question/next/revise/status

## Repo layout

- `docs/architecture.md` - system sketch and message flow
- `docs/plan.md` - phased implementation plan
- `pi/sherpa-stepper.ts` - pi extension sketch
- `lua/sherpa/` - Neovim client sketch
- `plugin/sherpa.lua` - user commands

## First milestone

1. start pi from Neovim
2. send a prompt
3. stream back events
4. detect target file from tool execution events
5. expose `:SherpaStart`, `:SherpaQ`, `:SherpaNext`, `:SherpaRevise`, `:SherpaStatus`

## Notes

- RPC is the right first transport for a Neovim plugin
- rich custom UI should live in Neovim, not in pi extension UI
- chunking behavior should come from extension-side workflow rules
- `:SherpaQ` is a non-progressing question turn about the current chunk
