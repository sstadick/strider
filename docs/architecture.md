# Architecture sketch

## Components

### 1. Neovim plugin

Lives in `lua/sherpa/`.

Owns:
- process lifecycle for `pi --mode rpc`
- RPC transport
- editor UX
- file jumping
- command bindings

### 2. pi extension

Lives in `pi/sherpa-stepper.ts`.

Owns:
- guided workflow state
- step progression
- persistence
- prompt shaping for one-chunk-at-a-time behavior

## Core flow

### Start

1. user runs `:SherpaStart make x, y, z work`
2. plugin sends `/guide make x, y, z work`
3. extension creates workflow state
4. extension prompts the model to plan and execute only the first chunk
5. plugin watches streamed tool events
6. when a file is targeted, plugin opens or focuses that buffer

### Pause

After the chunk is done:
- extension marks the current step as waiting
- plugin shows status
- user can inspect, ask questions, or adjust direction

### Question

1. user runs `:SherpaQ why did you choose this approach?`
2. plugin sends `/question why did you choose this approach?`
3. extension asks the model to answer about the current chunk
4. the workflow does not advance and the agent should not edit code by default

### Continue

1. user runs `:SherpaNext`
2. plugin sends `/next`
3. extension advances to the next chunk
4. model executes the next bounded edit

### Revise

1. user runs `:SherpaRevise tighten the error handling here`
2. plugin sends `/revise tighten the error handling here`
3. extension keeps the current step active and re-prompts the model with feedback

## RPC events we care about

### From pi

- `message_update`
  - assistant text and tool call streaming
- `tool_execution_start`
  - inspect `toolName` and `args`
- `tool_execution_update`
  - optional live output
- `tool_execution_end`
  - final tool result, useful for status and file tracking
- `queue_update`
  - reflect queued steering or follow-up messages in UI
- `extension_ui_request`
  - optional simple prompts from extension

### To pi

- `prompt`
- `steer`
- `follow_up`
- `abort`
- `get_state`

## File jump heuristic

For MVP, watch these tool calls:

- `read.path`
- `edit.path`
- `write.path`
- `bash.command` only if we later add parsing for editor hints

Prefer the explicit file tools and ignore shell inference at first.

## Suggested extension state

```ts
interface WorkflowStep {
  id: number;
  title: string;
  status: "todo" | "active" | "done" | "blocked";
  file?: string;
  notes?: string;
}

interface WorkflowState {
  mode: "idle" | "guided";
  goal?: string;
  currentStepId?: number;
  lastTouchedFile?: string;
  recentFiles: string[];
  lastAssistantSummary?: string;
  steps: WorkflowStep[];
}
```

Persist with `pi.appendEntry()` so a resumed session can reconstruct the workflow.

## Boundaries for chunk mode

The extension prompt should bias the model toward:

- one file at a time when possible
- one logical change per chunk
- short explanation after the edit
- explicit stop after the chunk is complete
- asking for clarification instead of guessing when blocked
- answering `:SherpaQ` without editing code unless explicitly asked

## MVP commands

### Neovim

- `:SherpaStart {goal}`
- `:SherpaQ {question}`
- `:SherpaNext`
- `:SherpaRevise {feedback}`
- `:SherpaStatus`

### pi extension

- `/guide {goal}`
- `/question {question}`
- `/next`
- `/revise {feedback}`
- `/status`

## Current implementation status

Working today:

- Neovim commands for `:SherpaStart`, `:SherpaQ`, `:SherpaRevise`, `:SherpaNext`, and `:SherpaStatus`
- pi launched in RPC mode from Neovim with the local Sherpa extension
- a scratch log buffer that records user prompts, assistant responses, tool activity, and stderr
- file jumps for explicit `read`, `edit`, and `write` tool calls
- edit jumps that prefer the first changed line reported by pi's edit tool
- question turns that stay in the current chunk instead of advancing the workflow

Known rough edges at this stopping point:

- file creation and first-open ordering is improved but still needs more UX testing
- jump behavior should eventually highlight or preview the changed range, not just place the cursor
- the log buffer works as a conversation surface, but the final UI should be more polished
- step planning is still intentionally lightweight and should become more explicit over time

## Milestones

### Milestone 1

- static command wiring
- spawn pi RPC process
- stream output into notifications or a scratch buffer
- status: complete

### Milestone 2

- guided state in extension
- file jumping from tool events
- basic status reporting
- question-only turn support for `:SherpaQ`
- status: first pass complete

### Milestone 3

- persistent workflow state
- quickfix or loclist view for touched files
- small floating UI for current chunk
- changed-range highlighting or diff preview
