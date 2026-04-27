# Usage

This page keeps the command-level detail that does not need to live in the
README.

## Commands

| Command | What it does |
|---|---|
| `:StriderSearch {prompt}` | Structured code search with picker and quickfix output |
| `:StriderSearches` | Reopen recent flow-lane search result sets |
| `:StriderLogFlow` | Toggle the flow log used by Q/Search/Patch |
| `:StriderReview [prompt]` | Open the review popup; submit to start a dedicated review-lane walkthrough or ask about the current stop |
| `:StriderLogReview` | Toggle the dedicated review log |
| `:'<,'>StriderReview [prompt]` | Open the review popup scoped to the selected range |
| `:StriderNext` / `:StriderPrev` | Walk review stops; `:StriderNext!` accepts the current stop first |
| `:StriderReviewItems` | Pick any stop from the plan |
| `:StriderComment {text}` | Comment on the current stop |
| `:'<,'>StriderComment {text}` | Comment on a visual sub-range |
| `:StriderComments` | Browse recorded review comments |
| `:StriderPatch [prompt]` | Open the patch popup for the current review item |
| `:'<,'>StriderPatch [prompt]` | Open the patch popup for a visual selection |
| `:StriderQ [prompt]` | Open the Q popup and run a background flow-lane question |
| `:'<,'>StriderQ [prompt]` | Open the Q popup with a selection-scoped flow-lane question |
| `:StriderChat` | Toggle the chat log + compose buffers |
| `:[range]StriderChat [prompt]` | Open chat with the compose buffer prefilled from the range/prompt |
| `:StriderStop` | Abort the current main-lane turn |
| `:StriderStopFlow` | Abort the current flow-lane Q/Search/Patch turn |
| `:StriderStatus` | Open the current lane/status/control summary |
| `:StriderSessions` | Browse saved pi sessions for this project |
| `:StriderResume [id-or-path]` | Resume a saved pi session |
| `:StriderRetry` | Re-dispatch a stalled plan turn |

`:StriderSearch`, `:StriderReview`, `:StriderPatch`, `:StriderQ`, and
`:StriderComment` use floating editors. Submit with `<C-s>`, cancel with
`<Esc><Esc>`.

`:StriderChat` keeps the persistent main log and compose buffers.
`:StriderQ`, `:StriderSearch`, and `:StriderPatch` run on a separate flow lane
whose transcript lives in `:StriderLogFlow`. `:StriderQ` also opens a
non-focus-stealing `strider://StriderQAnswer` window in the bottom-right. It
stays as a compact three-line card while waiting and after the answer is ready;
select/focus it to expand into a near full-height right-side answer panel, then
leave it to fold again. The question stays pinned at the top, and only assistant answer text is shown below
it. Reasoning, tool calls, and tool output remain in `:StriderLogFlow`. When
flow-lane operations finish, Strider always leaves a bottom-left green-dot
completion cue; if the flow log is hidden, it also sends a notification.
`:StriderStopFlow`
aborts the active flow-lane turn. `:StriderReview` runs on a dedicated review
lane whose transcript lives in `:StriderLogReview`; that review log is
manual/diagnostic and does not open on review start or review end.

## Chat Compose

Type into the `:StriderChat` compose buffer. Leading `/` routes to pi
extensions instead of the model. Beyond Strider's own `/prompt`, `/review`,
and related commands, compose supports:

- `/models [filter]` - fuzzy-pick a model via telescope/fzf
- `/tree` - jump to any previous user message in the session tree
- `/thinking [level]` - cycle or set the reasoning level
  (`off`/`minimal`/`low`/`medium`/`high`/`xhigh`); also bound to `<S-Tab>`
- `/compact [instructions]` - manually compact context
- `/new` - start a fresh session
- `/fork [entryId]` - fork the session from a conversation point
- `/export [path]` - export session to HTML
- `/sessions` - browse saved sessions for the current project/session directory
- `/resume [id-or-path]` - browse sessions or resume by id prefix/path
- `/switch_session <id-or-path>` - explicit alias for `/resume <id-or-path>`

Some pi TUI commands (`/session`, `/copy`, `/share`, `/hotkeys`,
`/changelog`, `/settings`) have no RPC equivalent and are not available in
Strider.

Compose clears on successful send and survives across turns. Empty compose
ghost text and the winbar show whether `<C-s>` will send, steer, or answer a
clarify. Commands that use dedicated RPC messages, such as `/compact`, `/new`,
and `/export`, also set the main lane busy and show `Working` in the compose
and log winbars until pi replies. Sending while a reply is streaming steers the
running turn via pi's `steer` command. Slash commands are rejected mid-turn.

`:StriderStop` aborts the main-lane turn; `:StriderStopFlow` aborts the
flow-lane turn. `:StriderStatus` opens a compact summary of lane state, pending
controls, review progress, model/context widget lines, and the last error.

## Session Storage

Strider uses pi's existing JSONL session files rather than a separate store.
Projects can opt into repo-local sessions with:

```json
// .pi/settings.json
{
  "sessionDir": ".pi/sessions"
}
```

Because Strider starts pi with the project as the working directory, pi will
create and list sessions there. Use `/sessions` or `:StriderSessions` to browse
saved sessions, and `/resume <id-or-path>` or `:StriderResume <id-or-path>` to
resume directly. Session JSONL can include prompts, file contents, tool output,
and secrets, so `.pi/sessions/` should usually be gitignored.

## Review Flow

Review is pre-planned. The model commits to a full ordered list of stops up
front, and `:StriderNext` / `:StriderPrev` move mechanically through that plan.

1. You prompt. If you mention a diff, PR, or branch changes, the model plans a
   diff review. A visual selection plans a selection review. Otherwise it is
   free-form.
2. The model calls `strider_plan` with ordered stops, file ranges, titles,
   hooks, and explanations.
3. The plan appears in the review pane as a table of contents.
4. `:StriderNext` / `:StriderPrev` walk the fixed plan. `:StriderNext!` accepts
   the current stop before advancing.
5. `:StriderReview <question>` during a review asks about the current stop.
   Ranged questions render as inline block annotations.

Review mode is read-only. Comments stay local and are fed back to the agent
when the review ends. No external sync is performed.

## Log Rendering

Tool calls show their results inline.

- `edit` operations render under `* Edited <path> (+N -M)` with inline diff
  rows, a line-number gutter, green/red change markers, and source syntax
  highlighting for the changed code.
- `read` and `write` output stays in fenced markdown code blocks tagged with
  the file language for treesitter highlighting.
- `bash`, `grep`, `ls`, and `find` output renders as compact transcript rows
  with a muted gutter and count metadata for list tools. Search/list headers
  include their meaningful arguments, such as `grep "term" in src` or
  `find *.lua in lua/strider`.
- Tool output shows up to 5 visible lines, keeping the beginning and end with
  a muted Codex-style `… +N lines` marker when middle lines are hidden.
- Compact command output keeps the original text after a muted gutter so
  markdown-looking output cannot render as headings, lists, blockquotes,
  tables, or fences.

The log tails new output only while the visible log window is already at the
bottom. Scrolling up pauses follow-mode until you jump back to the tail. The log
winbar shows model, thinking level, context usage, and running cost.

## Clarify

During `:StriderChat` and `:StriderPatch`, the model may pause to ask a
clarifying question, propose a plan, or confirm a destructive action via the
`strider_clarify` tool.

On main chat, questions and plan bodies render inline in the chat log and the
compose buffer is used for the reply. `<C-s>` submits and `<Esc><Esc>` rejects.

On the flow lane (`:StriderQ`, `:StriderSearch`, `:StriderPatch`), clarify prompts
stay popup-based and their transcript lands in `:StriderLogFlow`.

Plan proposals pair the `[plan]` body block with an Accept / Modify / Reject
picker. Modify opens an editor seeded with the proposal body; Reject sends
cancellation.

## Tangents And Patch

`:StriderQ` opens a floating editor for a one-shot side question. Submitting it
asks on Strider's separate flow lane without popping open main chat. Range-based
Q includes the selected excerpt in the prompt. The focused answer opens in a
non-focus-stealing `strider://StriderQAnswer` window at the bottom-right. It
stays compact while waiting and after the answer is ready; select/focus it to
expand into a near full-height right-side answer panel, then leave it to fold again. The full transcript,
including reasoning and tool calls, still lands in `:StriderLogFlow`.

`:StriderPatch` is for hyper-local edits: one function or region at a time. It
requires a visual range or an active review item, embeds the excerpt and range
in the prompt, and instructs the model to stay inside the selection. Patch runs
on the flow lane.
