# Architecture sketch

## Current product model

Sherpa is now explicitly linear.

The only user controls are:
- `:SherpaQ {request}`
- `:SherpaNext`

`SherpaQ` starts the workflow and continues it.
`SherpaNext` accepts the current chunk, records a checkpoint, and asks pi for the next bounded chunk.

Sherpa still relies on pi's built-in session history so future work can add code restoration and richer history navigation, but the current UX does not expose branching.

## Components

### 1. Neovim plugin

Lives in `lua/sherpa/`.

Owns:
- process lifecycle for `pi --mode rpc`
- RPC transport
- editor UX
- file jumping and chunk highlighting
- command bindings
- conversation log buffer

### 2. pi extension

Lives in `pi/sherpa-stepper.ts`.

Owns:
- linear workflow state
- checkpoint labeling
- persistence
- prompt shaping for one-chunk-at-a-time behavior

## Core flow

### Start or continue

1. user runs `:SherpaQ <request>`
2. plugin sends `/question <request>`
3. if Sherpa is idle, the extension starts a linear flow and treats the request as the initial goal
4. if Sherpa is active, the extension treats the request as guidance for the current chunk
5. pi makes at most one bounded chunk of progress and stops
6. plugin updates the log, jumps to touched files, and highlights the changed chunk

### Accept and continue

1. user runs `:SherpaNext`
2. plugin sends `/next`
3. extension labels the last assistant chunk as an accepted checkpoint using pi's built-in history labels
4. extension advances the linear chunk counter
5. pi performs one more bounded chunk and stops again

## History model

Sherpa uses pi's session history as the source of truth.

For now, accepted chunks are represented as labels on assistant messages, for example:
- `chunk-1`
- `chunk-2`
- `chunk-3`

This keeps Sherpa compatible with pi's built-in history and `/tree` model without pretending that code state can be restored yet.

Important limitation:
- session history can branch
- the working tree on disk does not automatically rewind
- therefore Sherpa currently presents a linear workflow only

## RPC events we care about

### From pi

- `message_end`
  - capture assistant summaries for the current chunk
- `tool_execution_start`
  - inspect `toolName` and `args`
- `tool_execution_end`
  - jump to changed files and highlight changed ranges
- `extension_ui_request`
  - receive status and widget updates from the extension

### To pi

- `prompt`

## File jump heuristic

For now, watch these explicit file tools only:

- `read.path`
- `edit.path`
- `write.path`

Shell parsing is intentionally out of scope for the current UX.

## Suggested extension state

```ts
interface WorkflowState {
  mode: "idle" | "guided";
  goal?: string;
  currentChunk: number;
  acceptedChunks: number;
  lastAcceptedEntryId?: string;
  lastAssistantEntryId?: string;
  lastTouchedFile?: string;
  recentFiles: string[];
  lastAssistantSummary?: string;
}
```

Persist with `pi.appendEntry()` so resumed sessions can reconstruct the linear flow.

## Boundaries for chunk mode

The extension prompt should bias the model toward:

- one bounded chunk per turn
- one file when possible
- explicit stop after the chunk is complete
- answering explanatory questions without editing code
- making code changes only when the request actually asks for them

## Current implementation status

Working today:

- `:SherpaQ` starts and continues the flow
- `:SherpaNext` records accepted checkpoints and advances linearly
- a scratch log buffer records user prompts, assistant replies, tool activity, and stderr
- file jumps happen for explicit `read`, `edit`, and `write` tool calls
- changed chunks are marked in the gutter
- accepted checkpoints are stored in pi history labels for future reuse

Known rough edges:

- the workflow is linear by design, but checkpoint browsing is not yet exposed in Neovim
- file creation and first-open ordering still needs more testing
- checkpoint summaries are still lightweight
- code restoration is not implemented yet
