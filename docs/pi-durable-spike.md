# Spike: should Strider switch to pi-durable?

Investigated 2026-10-20. No plugin implementation changes.

## Decision

**Promising for durable workflow ownership; not a drop-in simplification.**

Keep the current backend as the default, modernize its lifecycle handling, and
consider an opt-in durable lane before committing to a migration. Adopt durable
if recoverable reviews, queued work, and reconnectable editor sessions become
primary requirements—not just to reduce code today.

`@earendil-works/pi-durable` is a separate harness built on pi-ai and Chord. It
is not a new mode of `pi --mode rpc`, nor a compatible coding-agent extension
loader. We would be building a small Strider backend rather than changing a
launch flag.

The durability primitives worked in an executable, credential-free spike.
Preserving the user's existing pi extensions, commands, and sessions is the
larger migration risk. Most of Strider's native UI and review behavior stays.

## Scope and versions

- Strider: `1502433e9e05671244cc827278fd411248942b2d`.
- Installed coding-agent and published durable: **1.3.0**.
- Upstream source pinned to tag `v1.3.0`, commit
  `71023aec1546d6d677a65669c5665c0927ce0dd0`; not unreleased `main`.
- Node: `v22.23.1`; durable requires `>=22.19.0`.
- Inspected source, documentation, public types, examples, and relevant tests.
  Ran metadata-only real-pi RPC and faux-provider durable probes.
- No real model requests, user configuration changes, or production migration.
  The complete Strider test suite was not run.

Durable explicitly labels its API experimental. Its changelog records breaking
changes in 1.1 and 1.2, and even earlier patch releases. Pin versions and budget
for adaptation; a 1.x version is not a compatibility promise here.

## What we have now

| Area | Current implementation | Implication |
|---|---|---|
| Lanes | One pi RPC subprocess per chat/search/patch/review worker and per Q; Q follow-ups reuse their worker | Durable can replace process-per-lane with conversation-per-lane |
| Request lifecycle | Lua tracks pending operations, callbacks, streams, and completion inferred from messages | Authoritative submissions/live state are a good fit |
| Persistence | Pi owns its normal JSONL conversations; review progress, comments, acceptance, cards, and pending clarification are mostly Neovim memory | Durable adds missing recovery, rather than deleting an existing recovery system |
| UI bridge | `ctx.ui` dialogs; sentinel-tagged editor requests for plans and Neovim Lua execution | Still needs a native-client interaction protocol |
| Review | Local plan ingestion, anchors, deterministic selection chunks, Next/Prev, acceptance, comments | Product logic stays; state ownership can move |
| Cross-lane context | Review optionally copies up to 20,000 characters of the rendered chat log | Structured context/fork APIs can replace display-text copying |

Relevant source:

- [`rpc.lua`](../lua/strider/rpc.lua#L41): launch and transport (342 lines).
- [`state.lua`](../lua/strider/state.lua#L265) and
  [`state/session.lua`](../lua/strider/state/session.lua): lane/UI state.
- [`rpc/messages.lua`](../lua/strider/rpc/messages.lua#L276): completion handling.
- [`strider-stepper.ts`](../pi/strider-stepper.ts#L129): operation lifecycle,
  tools, controls, and status.
- [`session-switching.ts`](../pi/session-switching.ts#L149): normal Pi session reuse.
- [`extension_ui.lua`](../lua/strider/rpc/extension_ui.lua#L49) and
  [`strider-tools.ts`](../pi/strider-tools.ts#L126): clarification/plan/editor bridge.
- [`review.lua`](../lua/strider/review.lua#L418): acceptance is a local table update.
- [`init.lua`](../lua/strider/init.lua#L373): display-text context copying.

Two important gaps: accepted review stops are not currently persisted/restored
as the product instructions intend; forwarding a review summary currently
appends it to the main **display log**, not the main model conversation
(`init.lua:228–259`). Both can also be fixed without durable.

Scale: about 12,035 Lua lines and 1,022 extension TypeScript lines. Roughly
5,600 Lua lines are `ui.lua`/`ui/*`. The RPC modules total about 1,503 lines,
but include rendering and product routing, not just deletable transport.
There is no defensible claim that durable removes most of this plugin.

## What durable would simplify

1. **Lane ownership.** One Harness can own independent conversations with
   their own model, tools, instructions, working directory, and provider session
   identity. Q and review need not each own an OS process. Prefer ownerless
   conversations for independent lanes; task ownership has cancellation
   semantics that must not accidentally make Stop Chat cancel a side question.
2. **Run/queue bookkeeping.** `submit()` produces a durable submission;
   `requestId` deduplicates admission across restart. Busy behavior explicitly
   chooses follow-up, steer, or reject. Inbox and live task state are observable.
3. **Review/checkpoint persistence.** Typed documents and transcript entries
   can change atomically. Plan, current stop, acceptance, comments, and pending
   decisions can become backend-owned state instead of editor-only tables.
4. **Reconnection.** A new observer starts with a committed snapshot, then
   updates. It does **not** replay a history of missed transient events. Lua
   must support replacing its projection, including after observer overflow.
5. **Crash recovery.** Pending work resumes from persisted checkpoints; tools
   have explicit replay policies. This is more than restoring a chat transcript.
6. **Context and usage.** Conversation forks/context access avoid copying
   rendered buffers; usage is recorded per conversation and across the Harness.

These are demonstrated capabilities, not a finished Strider implementation.
Custom documents need their own observers: `watchEvents()` does not automatically
include our review/approval documents.

## What it does not give us

| Compatibility / behavior | Migration work |
|---|---|
| Current pi extensions | Different ABI: durable uses named tools/sections/hooks/tasks, not `ExtensionAPI` registration and `ctx.ui`; port Strider and audit user extensions |
| Existing RPC protocol | No packaged replacement `pi --mode rpc` server; implement a host and versioned Neovim transport |
| Existing event renderer | Similar event names, different payloads: `run_start/run_end`, `message_update.changes`, `message_end.entry`; adapt, including snapshots |
| Slash commands and UI | Implement command routing, model/session/tree pickers, clarification, plan approval, and live Neovim request/reply |
| User pi setup | Explicit resource/settings integration; skills, instructions, prompt expansion, MCP, custom-provider extensions and trust behavior are not automatically inherited |
| Old sessions | Durable JSONL is a different format with documents/tasks/commit markers; cannot open coding-agent session files as-is |
| Review UX | Keep native buffers, highlights, diffs, cards, quickfix, selections, anchors, comments, mechanical navigation and explicit acceptance |
| Read-only / patch scope | Host policy, not a durability guarantee; restrict actual execution, not only offered model tools or prompt text |
| Process supervision | Host startup/restart, storage ownership, multi-editor attach, cleanup, and stale-editor requests remain our responsibility |

**Some service reuse is plausible:** coding-agent's exported `ModelRuntime`
implements pi-ai's `Models`, the interface durable accepts. Static inspection
indicates we can reuse normal model/auth services without copying credentials.
`SettingsManager` and `DefaultResourceLoader` can supply inputs to explicit
adapters. This was not integration-tested and does not make coding-agent
extensions executable in durable. Loading extension metadata alone does not
run their provider registration, lifecycle hooks, commands, or UI.

Durable's plan/reviewer examples are useful patterns, not Strider replacements.
In particular, the reviewer example automatically asks for further model passes;
Strider must retain bounded work and user-controlled continuation.

## Durability and safety limits

- **One process owns a storage.** Durable provides no cross-process ownership
  locking. Multiple Neovim instances must attach to one host or use separate
  stores; do not point independent hosts at one workspace database.
- SQLite WAL with `synchronous=NORMAL` covers process crashes, not a guarantee
  against losing the latest commits on power/host failure. JSONL also keeps
  history in memory; SQLite is the better long-lived default.
- A single host reduces processes but shares a failure domain. Storage failure
  closes the Harness; trusted extension code is not sandboxed by conversation.
- Replay-safe tools may execute again after a crash. Deduplicated submissions
  do **not** guarantee exactly-once filesystem/process/editor side effects.
- A tool with committed intent does not rerun `beforeTool` on recovery. Persist
  approvals with clear validity/replay rules; do not rely on a fresh dialog.
- Arbitrary `strider_vim` execution is editor-bound and potentially mutating.
  Keep it unavailable without a live attachment, restricted in read-only lanes,
  and non-replayable unless a particular operation is proven idempotent.
- A persisted human wait is something we build with tasks/documents, not a
  built-in approval product. Reconnection, denial, cancellation, stale replies,
  and closing Neovim need explicit semantics.

## Improvements available on regular pi now

**Do these before a backend rewrite.**

1. **Use `agent_settled` for operation completion.**
   `strider-stepper.ts:225–233` clears the operation on *every* `message_end`.
   Pi's documented sequence includes the initial user message's `message_end`,
   so static control flow indicates the read-only operation guard can disappear
   before tools run. It can also hide plan tools too early. Lua completion on
   assistant messages can precede retries/recovery. Keep rendering at message
   boundaries; finish work at settlement. Add an event-sequence regression test.
   This is a high-priority static finding, not a live-model reproduction.
2. **Preserve active tool selections.** `applyOperationTools()` starts from
   `getAllTools()`, effectively enabling non-Strider tools regardless of the
   user's selection. Modern deferred/codemode exposure makes that especially
   undesirable. Change only Strider-owned visibility; make user-interaction
   tools model-only where appropriate.
3. **Use prompt disposition and command discovery.** RPC reports started,
   queued, or handled. Discover commands/templates/skills rather than guessing.
   Caveat: Strider commands call `sendUserMessage()` themselves, so an outer
   `handled` command may still launch a run. Do not equate it with idle.
4. **Restore from existing session APIs.** Custom entries plus
   `get_entries({since})`, `get_tree`, and active-branch reconstruction can
   persist/rebuild review state without a second storage system. Also replace
   rendered-log context copying and actually deliver review summaries to Pi.
5. **Use native statistics and controls.** Prefer `get_session_stats` over the
   reset-on-start cost accumulator; query supported thinking levels; handle
   queue clearing explicitly when abort should discard queued work.

The legacy package imports are **not currently a loading failure**. Pi 1.3.0
aliases `@mariozechner/pi-coding-agent` and `@sinclair/typebox`. A real,
metadata-only RPC launch loaded all 12 Strider commands successfully, answered
`get_commands`, `get_state`, `get_entries`, and `get_tree`, and exited cleanly
with no stderr or session file. That does not prove all tools/user extensions
work, but removes package renaming as a reason for a rewrite.

## Executable spike results

Published packages, isolated temporary installation, lifecycle scripts disabled,
empty home, inherited credentials removed, faux-only models, and a network
tripwire. **9/9 checks passed**, including an independent parent rerun and a
read-only Python SQLite audit.

| Probe | Observed |
|---|---|
| Two conversations in one Harness | Independent context/model/tool selections; reviewer finishes while chat is blocked; unoffered fixture write never executes |
| Atomic custom state + entry | Both persist at the same commit; intentional rollback persists neither change |
| Late observer and reconnect | Snapshot contains committed live output and queue; subsequent events reconstruct the transcript; no historical event replay |
| Duplicate request IDs | Answered, previously queued, and crash-interrupted submissions retain identity across reopen; no extra model request for answered duplicates |
| SIGKILL during tool | Safe→safe re-executes; unsafe→unsafe and either policy-change combination return interrupted instead; existing runs subsequently settle |
| Human decision | Custom pending decision/task survives SIGKILL; no completion before host approval; one completion after approval |
| No configured model | Submission settles `unanswered/no_model`, rather than waiting indefinitely |
| Isolation/provenance checks | Pinned 1.3.0 packages; zero runtime network attempts |

The nine checks group several assertions; the table summarizes rather than
assigning one row per test. The crash fixture killed only its own subprocesses.

**Not proven:** real provider/auth integration, Neovim reconnect/rendering,
user extension compatibility, built-in filesystem confinement, observer overload,
power loss, multi-process ownership, denial/stale-approval races, performance or
whole-plugin code reduction. The human wait was a custom task watching a
document, not a native `waiting` task state for human input.

Disposable scripts and detailed evidence remain at:

```text
/tmp/strider-durable-spike/probe/VERIFICATION.md
/tmp/strider-durable-spike/probe/probe.mjs
/tmp/strider-durable-spike/probe/common.mjs
/tmp/strider-durable-spike/probe/artifacts/results.json
/tmp/strider-durable-spike/probe/artifacts/parent-sqlite-audit.json
```

Rerun locally with `cd /tmp/strider-durable-spike/probe && bash run.sh` and
`python3 sqlite-audit.py`. These are temporary investigation artifacts, not
checked-in tests or available from a fresh clone. This report preserves the
findings and upstream references; no disposable dependencies enter Strider.

## Options and proposed next slice

| Option | Relative effort | Assessment |
|---|---|---|
| Update existing CLI/RPC integration | Smallest | Best immediate simplification; retains normal pi setup and session format |
| Small host around coding-agent SDK | Medium | Could multiplex `AgentSession`s and use typed APIs while retaining coding-agent behavior; still needs transport and explicit UI/resource binding; not durable task recovery |
| Host around pi-durable | Largest | Cleanest ownership for recoverable workflows; substantial compatibility ports and new operational responsibilities |

If pursuing durable, target this boundary:

```text
Neovim: selections, buffers, navigation, rendering, local interaction
    ↕ versioned JSONL initially; snapshot + incremental projection
Strider host: lane IDs, workflow policy, commands, editor attachment
    ↕
pi-durable: conversations, submissions, tasks, docs, usage → SQLite
    ↕ explicit model/auth/resource adapters
user's pi services
```

Start with one opt-in Q lane, then a read-only planned review. Keep main chat
and old sessions on the current backend until compatibility is demonstrated.
This temporarily adds two backends; it is a validation strategy, not the final
simplification. Don't run coding-agent and durable as competing transcript
owners for the same conversation.

Acceptance criteria before broader adoption:

- Existing native Q rendering/model selection works with isolated conversation
  context; Stop Chat does not abort an independent Q.
- Kill/restart the host and close/reopen Neovim: reconstruct transcript, active
  work, plan/current stop/comments/acceptance without duplicates.
- Next/Prev/accept are persisted mechanical transitions with **zero model
  calls**; planning, clarification and stop boundaries cannot auto-continue.
- A pending decision reappears after restart; no file/editor side effect happens
  before explicit approval; unsafe interrupted effects are not blindly replayed.
- Read-only and patch policy covers nested/codemode/MCP tools and `strider_vim`,
  not just built-in `edit`/`write`; prove this with execution-level tests.
- Normal model/auth setup works; explicitly inventory supported versus
  unsupported extensions, skills, prompts, providers, commands and old sessions.
- Test snapshot replacement/slow observers, two editor attachments, and storage
  failure. Choose attached-child versus daemon lifetime deliberately; only a
  surviving host can keep working while Neovim is closed.
- Measure backend code/process/memory/startup changes. Delete superseded
  lifecycle state only once the replacement is authoritative and tested.

Existing useful tests: `test_rpc_commands.py`, `test_review_planning_flow.py`,
`test_tmux_review.py`, `test_tmux_flow_cards.py`, `test_readonly_guard.py`, and
opt-in `test_real_pi_smoke.py`. Some worker tests assert different process IDs;
replace those with logical isolation assertions for a multiplexed host. Current
fake-backend guard tests do not establish real lifecycle or nested-tool safety.

## Upstream references (pinned)

- [Durable README](https://github.com/earendil-works/pi/blob/v1.3.0/packages/durable/README.md)
- [Normative durable spec](https://github.com/earendil-works/pi/blob/v1.3.0/packages/durable/docs/spec.md)
- [Durable changelog](https://github.com/earendil-works/pi/blob/v1.3.0/packages/durable/CHANGELOG.md)
- [Durable events](https://github.com/earendil-works/pi/blob/v1.3.0/packages/durable/src/harness/events.ts)
- [Durable public types](https://github.com/earendil-works/pi/blob/v1.3.0/packages/durable/src/harness/types.ts)
- [Durable examples](https://github.com/earendil-works/pi/tree/v1.3.0/packages/durable/test/examples)
- [Pi SDK](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/sdk.md)
- [Pi RPC commands](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/rpc-commands.md)
- [Pi event lifecycle](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/json.md)
- [Pi extension contracts/state](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/extensions.md)
- [Pi session format](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/session-format.md)
