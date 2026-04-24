# Usage

This page keeps the command-level detail that does not need to live in the
README.

## Commands

| Command | What it does |
|---|---|
| `:SherpaSearch {prompt}` | Structured code search with picker and quickfix output |
| `:SherpaSearches` | Reopen recent flow-lane search result sets |
| `:SherpaLogFlow` | Toggle the flow log used by Q/Search/Patch |
| `:SherpaReview [prompt]` | Open the review popup; submit to start a dedicated review-lane walkthrough or ask about the current stop |
| `:SherpaLogReview` | Toggle the dedicated review log |
| `:'<,'>SherpaReview [prompt]` | Open the review popup scoped to the selected range |
| `:SherpaNext` / `:SherpaPrev` | Walk review stops; `:SherpaNext!` accepts the current stop first |
| `:SherpaReviewItems` | Pick any stop from the plan |
| `:SherpaComment {text}` | Comment on the current stop |
| `:'<,'>SherpaComment {text}` | Comment on a visual sub-range |
| `:SherpaComments` | Browse recorded review comments |
| `:SherpaPatch [prompt]` | Open the patch popup for the current review item |
| `:'<,'>SherpaPatch [prompt]` | Open the patch popup for a visual selection |
| `:SherpaQ [prompt]` | Open the Q popup and run a background flow-lane question |
| `:'<,'>SherpaQ [prompt]` | Open the Q popup with a selection-scoped flow-lane question |
| `:SherpaChat` | Toggle the chat log + compose buffers |
| `:[range]SherpaChat [prompt]` | Open chat with the compose buffer prefilled from the range/prompt |
| `:SherpaStop` | Abort the current in-flight turn |
| `:SherpaStatus` | Open the current lane/status/control summary |
| `:SherpaRetry` | Re-dispatch a stalled plan turn |

`:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`, `:SherpaQ`, and
`:SherpaComment` use floating editors. Submit with `<C-s>`, cancel with
`<Esc><Esc>`.

`:SherpaChat` keeps the persistent main log and compose buffers.
`:SherpaQ`, `:SherpaSearch`, and `:SherpaPatch` run on a separate flow lane
whose transcript lives in `:SherpaLogFlow`. `:SherpaReview` runs on a dedicated
review lane whose transcript lives in `:SherpaLogReview`.

## Chat Compose

Type into the `:SherpaChat` compose buffer. Leading `/` routes to pi
extensions instead of the model. Beyond Sherpa's own `/prompt`, `/review`,
and related commands, compose supports:

- `/models [filter]` - fuzzy-pick a model via telescope/fzf
- `/tree` - jump to any previous user message in the session tree
- `/thinking [level]` - cycle or set the reasoning level
  (`off`/`minimal`/`low`/`medium`/`high`/`xhigh`); also bound to `<S-Tab>`
- `/compact [instructions]` - manually compact context
- `/new` - start a fresh session
- `/fork [entryId]` - fork the session from a conversation point
- `/export [path]` - export session to HTML
- `/resume [sessionPath]` - switch to a saved session

Some pi TUI commands (`/session`, `/copy`, `/share`, `/hotkeys`,
`/changelog`, `/settings`) have no RPC equivalent and are not available in
Sherpa.

Compose clears on successful send and survives across turns. Empty compose
ghost text and the winbar show whether `<C-s>` will send, steer, or answer a
clarify. Sending while a reply is streaming steers the running turn via pi's
`steer` command. Slash commands are rejected mid-turn.

`:SherpaStop` aborts the in-flight turn. `:SherpaStatus` opens a compact
summary of lane state, pending controls, review progress, model/context widget
lines, and the last error.

## Review Flow

Review is pre-planned. The model commits to a full ordered list of stops up
front, and `:SherpaNext` / `:SherpaPrev` move mechanically through that plan.

1. You prompt. If you mention a diff, PR, or branch changes, the model plans a
   diff review. A visual selection plans a selection review. Otherwise it is
   free-form.
2. The model calls `sherpa_plan` with ordered stops, file ranges, titles,
   hooks, and explanations.
3. The plan appears in the review pane as a table of contents.
4. `:SherpaNext` / `:SherpaPrev` walk the fixed plan. `:SherpaNext!` accepts
   the current stop before advancing.
5. `:SherpaReview <question>` during a review asks about the current stop.
   Ranged questions render as inline block annotations.

Review mode is read-only. Comments stay local and are fed back to the agent
when the review ends. No external sync is performed.

## Log Rendering

Tool calls show their results inline.

- `edit` operations render under `* Edited <path> (+N -M)` with inline diff
  rows.
- `read` and `write` output stays in fenced markdown code blocks tagged with
  the file language for treesitter highlighting.
- `bash`, `grep`, `ls`, and `find` output renders as compact transcript rows
  with a muted gutter and count metadata for list tools.
- Tool output is tailed to the last 15 lines with a muted `N earlier lines...`
  note when older lines are hidden.
- Compact command output is escaped before insertion so markdown-looking output
  cannot render as headings, lists, blockquotes, tables, or fences.

The log tails new output only while the visible log window is already at the
bottom. Scrolling up pauses follow-mode until you jump back to the tail. The log
winbar shows model, thinking level, context usage, and running cost.

## Clarify

During `:SherpaChat` and `:SherpaPatch`, the model may pause to ask a
clarifying question, propose a plan, or confirm a destructive action via the
`sherpa_clarify` tool.

On main chat, questions and plan bodies render inline in the chat log and the
compose buffer is used for the reply. `<C-s>` submits and `<Esc><Esc>` rejects.

On the flow lane (`:SherpaQ`, `:SherpaSearch`, `:SherpaPatch`), clarify prompts
stay popup-based and their transcript lands in `:SherpaLogFlow`.

Plan proposals pair the `[plan]` body block with an Accept / Modify / Reject
picker. Modify opens an editor seeded with the proposal body; Reject sends
cancellation.

## Tangents And Patch

`:SherpaQ` opens a floating editor for a one-shot side question. Submitting it
asks on Sherpa's separate flow lane without popping open main chat. Range-based
Q includes the selected excerpt in the prompt. Answers land in
`:SherpaLogFlow`.

`:SherpaPatch` is for hyper-local edits: one function or region at a time. It
requires a visual range or an active review item, embeds the excerpt and range
in the prompt, and instructs the model to stay inside the selection. Patch runs
on the flow lane.
