# Message queue plan

Design notes for an editable message queue in `:SherpaChat`.

Status: planned. No runtime behavior has changed yet.

## Goal

Let the user keep working while the main chat turn is running:

- steer the active turn immediately when the current run needs redirecting
- queue follow-up messages for after the current turn
- edit, delete, and reorder queued messages before they enter pi history
- keep the default flow linear and Neovim-first

This should feel like disciplined pair programming: the agent can keep
working, but the user can line up the next bounded instruction without
losing the ability to revise it.

## What pi gives us

Pi RPC supports:

- `steer`: queue a steering message while the agent is running
- `follow_up`: queue a follow-up message after the agent finishes
- `prompt.streamingBehavior = "steer" | "followUp"` for prompt-time
  queueing while streaming
- `queue_update`: events containing pending steering and follow-up text
- `set_steering_mode` and `set_follow_up_mode`, each with `"all"` and
  `"one-at-a-time"` modes

Pi's TUI can restore queued messages to its editor, but RPC does not
currently expose an obvious `clear_queue` or `dequeue` command. That is
the important constraint for Sherpa: once we send a queued message to pi,
we should treat it as no longer reliably editable from the Neovim side.

## Design principle

Sherpa owns editable queue state.

Messages stay local until Sherpa decides to dispatch them. Local queue
items can be edited freely. Once a message is sent to pi as `steer`,
`follow_up`, or `prompt`, it becomes transcript/history, not an editable
queue item.

This gives us predictable editing without depending on pi internals.

## User-facing model

Sherpa distinguishes two send paths:

- `steer`: immediate redirect for the running turn. Sent to pi right
  away. Not editable after send.
- `follow-up`: editable local message queued for after the current
  main-chat turn completes.

Only follow-ups are part of the Sherpa-owned editable queue. Sent
steering messages may be shown for context, but they are locked.

There is no separate draft kind for v1. If the user wants to jot down
text without sending it, the compose buffer itself is the draft surface.

## UI surface

Add a small queue buffer:

- buffer name: `sherpa://queue`
- command: `:SherpaQueue`
- location: in the chat column, between `sherpa://log` and
  `sherpa://compose`
- visibility: auto-open when non-empty if chat is visible; hide when
  empty unless the user explicitly opened it

Example:

```text
Pending
1 [F] auto after current turn    add focused tests for the queue
2 [F] auto after current turn    document keymaps too

Locked in pi
3 [S] steering sent              stop editing UI, just inspect state
```

The queue buffer is a read-only control surface. Editing happens through
the existing multiline editor flow, not by parsing modified queue-buffer
text.

## Compose behavior

Keep `<C-s>` predictable:

- clarify pending: answer clarify
- idle main lane: send normal prompt
- main lane running: send steering immediately

Add explicit queue actions:

- `<C-f>`: queue current compose text as a follow-up
- `:SherpaFollowUp`: command equivalent of `<C-f>`
- `:SherpaQueue`: open or focus the queue buffer

Rationale: steering is urgent and should remain the fast default while
running. Follow-up queueing is intentional and editable, so it deserves
a distinct key.

## Compose hints

The empty-compose hint and winbar should describe the active send mode.

Idle:

```text
Type a message - <C-s> send - <C-f> queue follow-up
```

Running:

```text
Turn in flight - <C-s> steer now - <C-f> queue follow-up - :SherpaStop cancel
```

Clarify:

```text
Answer clarify - <C-s> send - <Esc><Esc> reject
```

If queue items exist, add a compact count:

```text
Sherpa is ready - queue 2 - <C-s> send - :SherpaQueue edit
```

## Queue buffer controls

Inside `sherpa://queue`:

- `<CR>` or `e`: edit selected item
- `d`: delete selected item
- `J`: move selected item down
- `K`: move selected item up
- `s`: send selected item now as steering if a turn is running, removing
  it from the local follow-up queue
- `<C-s>`: flush all queued follow-ups now if idle

Locked sent-steering rows are selectable for inspection but cannot be
edited, deleted, or reordered.

## Dispatch semantics

Rules:

1. Clarify always wins. No queued item is dispatched while a clarify
   answer is pending.
2. Steering is immediate. It is logged as user text and sent to pi via
   `steer`.
3. Follow-ups are local and editable until dispatch starts.
4. On a normal main-lane `message_end`, if the lane is idle and queued
   follow-ups exist, Sherpa sends all queued follow-ups at once.
5. Batch dispatch creates one next prompt containing every queued
   follow-up in order, with clear item boundaries. This gives the model
   the complete next set of instructions in a single turn and avoids
   stop-and-wait behavior between follow-ups.
6. `:SherpaStop` aborts the active turn and pauses auto-dispatch. Local
   queued items remain available for editing.
7. Queued follow-ups are plain agent instructions in v1. Slash commands
   should stay on the normal compose send path until we define command
   batching semantics.

Batch mode is the default. Sherpa should not drip one follow-up per
assistant turn unless we discover a concrete reason to add that option.

## State model

Add queue state to the main session:

```lua
message_queue = {
  {
    id = "queue-1",
    kind = "follow_up",
    text = "...",
    status = "local",  -- "local" | "dispatching" | "sent" | "failed"
    created_at = 1710000000,
    updated_at = 1710000000,
  },
}
```

Optional local context for sent steering:

```lua
sent_queue_items = {
  {
    id = "queue-locked-1",
    kind = "steer",
    text = "...",
    status = "sent",
    created_at = 1710000000,
  },
}
```

Keep images as a follow-up enhancement. Today compose inserts `@image`
markers, but the RPC prompt path does not yet convert them into pi
`images` payloads. Queue text should preserve those markers exactly
until image dispatch is implemented consistently for normal compose
sends too.

## Logging

Queued local items do not appear in `sherpa://log`.

When a queued item is dispatched:

- append a normal user block to the log
- mark the queue item `dispatching`
- on successful acceptance, remove it from the local queue or mark it
  `sent` until the next redraw
- on preflight failure, keep it in the queue as `failed` so the user can
  edit or delete it

This keeps the transcript truthful: only messages that actually entered
the agent conversation appear in history.

## Relationship to pi queue_update

Sherpa should not rely on pi's queue as the editable source of truth.

Use `queue_update` later for two optional surfaces:

- mirror locked messages that were already sent into pi
- detect when pi consumed a sent steering/follow-up message

Do not use `queue_update` to reconstruct editable local queue state.

## Implementation sketch

### Phase 1: Local editable queue

Files:

- `lua/sherpa/state.lua`
- `lua/sherpa/ui.lua`
- `lua/sherpa/init.lua`
- `plugin/sherpa.lua`

Work:

1. Add queue CRUD helpers to state:
   - `enqueue_message(kind, text, lane)`
   - `update_message(id, fields, lane)`
   - `remove_message(id, lane)`
   - `move_message(id, delta, lane)`
   - `queued_follow_ups(lane)`
2. Add `sherpa://queue` rendering and keymaps.
3. Add `:SherpaQueue` and `:SherpaFollowUp`.
4. Add compose `<C-f>` for follow-up queueing.
5. Update compose hint and winbar with queue counts and mode text.

### Phase 2: Dispatch loop

Files:

- `lua/sherpa/init.lua`
- `lua/sherpa/rpc.lua`

Work:

1. After main-lane `message_end`, schedule a queue flush.
2. Flush all local follow-ups as one batch prompt when idle.
3. Reject or hold queued slash commands for v1; do not silently send
   them as plain prose.
4. For a running turn, let selected queue item `s` send as steering.
5. Keep failed local items editable.

### Phase 3: pi follow_up and queue_update

Files:

- `lua/sherpa/rpc.lua`

Work:

1. Add `send_follow_up(lane, text)` for explicit pi follow-up dispatch.
2. Decide whether a future locked handoff should use pi `follow_up`.
3. Handle `queue_update` events for locked pi-owned queue display.

Initial recommendation: keep editable follow-ups local and dispatch them
as a single prompt batch. Add `send_follow_up` only when we have a
specific use case for handing delayed delivery to pi after the user can
no longer edit the messages.

## Tests

Add tmux tests under `tests/test_tmux_queue.py`:

- queue buffer opens when adding a follow-up
- queued follow-up does not appear in log before dispatch
- edit updates the queue item text
- delete removes the item and hides queue when empty
- reorder changes dispatch order
- `<C-s>` while running still sends steering immediately
- `<C-f>` while running queues editable follow-up
- all queued follow-ups auto-dispatch as one batch after main turn completes
- queued follow-ups preserve order in the batch prompt
- `:SherpaStop` leaves local queue intact and pauses auto-dispatch
- clarify pending suppresses queue dispatch

Unit tests can cover queue state helpers without tmux.

## Open questions

1. Should follow-up queueing be `<C-f>`, `<M-Enter>`, or both?
   `<C-f>` is easier to test and less terminal-dependent. `<M-Enter>`
   matches pi, but terminals vary.
2. Should `:SherpaChat <prompt>` while a turn is running prefill compose
   or enqueue a follow-up? Current behavior opens compose with prefill.
   Keep that for now; explicit queueing should happen from compose.
3. Should slash commands be allowed in the follow-up queue? No for v1.
   We need explicit command batching semantics before supporting that.
4. Should queue state persist across Neovim restarts? No for v1. It is
   local UI state, not committed history.
5. Should review and flow lanes get queues too? No for v1. Start with
   main chat only.

## Non-goals

- rebuilding pi's TUI queue editor
- held draft items separate from compose
- queueing review navigation commands
- queueing flow-lane `:SherpaQ`, `:SherpaPatch`, or `:SherpaSearch`
  requests
- implementing image payload dispatch before normal compose supports it
