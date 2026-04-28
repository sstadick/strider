# Usage

This page keeps the command-level detail that does not need to live in the
README.

## Commands

| Command | What it does |
|---|---|
| `:StriderSearch {prompt}` | Structured code search with picker and quickfix output |
| `:StriderSearches` | Reopen recent search result sets |
| `:StriderLogFlow` | Toggle the search/flow log |
| `:StriderLogQ` | Toggle the dedicated Q worker log |
| `:StriderLogPatch` | Toggle the dedicated patch worker log |
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
| `:StriderQ [prompt]` | Open the Q popup; with no args, toggles the latest Q card if one exists |
| `:'<,'>StriderQ [prompt]` | Open the Q popup with a selection-scoped Q-worker question |
| `:StriderChat` | Toggle the chat log + compose buffers |
| `:[range]StriderChat [prompt]` | Open chat with the compose buffer prefilled from the range/prompt |
| `:StriderStop` | Abort the current main-lane turn |
| `:StriderStopFlow` | Abort active Q/Search/Patch worker turns |
| `:StriderStatus` | Open the current lane/status/control summary |
| `:StriderSessions` | Browse saved pi sessions for this project |
| `:StriderResume [id-or-path]` | Resume a saved pi session |
| `:StriderRetry` | Re-dispatch a stalled plan turn |

`:StriderSearch`, `:StriderReview`, `:StriderPatch`, `:StriderQ`, and
`:StriderComment` use floating editors. Submit with `<C-s>`, cancel with
`<Esc><Esc>`.

`:StriderChat` keeps the persistent main log and compose buffers.
`:StriderQ`, `:StriderSearch`, and `:StriderPatch` run on separate flow-worker
processes, so Q and patch can proceed independently of each other and main chat.
Search transcript lives in `:StriderLogFlow`, Q in `:StriderLogQ`, and patch in
`:StriderLogPatch`. `:StriderQ` and `:StriderPatch` also open non-focus-stealing
flow cards in the bottom-right. Cards stay compact while running and after
completion; select/focus one to expand it into a near full-height right-side
panel. Expanded cards stay open when you return to code; press `q` or `<Esc>`
inside the card to fold it, or run bare `:StriderQ` to toggle the latest Q card.
Expanded Q cards show the question plus assistant answer and include a follow-up
compose section; type there and press `<C-s>` to ask on the same Q worker.
Patch cards show the request, target, touched files, diffs, and final summary.
Reasoning, tool calls, and full tool output remain in the operation's log. When flow-worker operations finish, Strider always leaves a
bottom-left green-dot completion cue; if that worker's log is hidden, it also
sends a notification. `:StriderStopFlow` aborts active flow-worker turns.
`:StriderReview` runs on a dedicated review
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

`:StriderStop` aborts the main-lane turn; `:StriderStopFlow` aborts active
Q/search/patch worker turns. `:StriderStatus` opens a compact summary of lane
state, pending controls, review progress, model/context widget lines, and the
last error.

## Live Neovim Tool

Strider exposes an always-available `strider_vim` tool to the agent. There is no
separate `:StriderVim` command: ask in `:StriderChat`, `:StriderQ`, or another
agent surface, and the model can call the tool when live editor state matters.

The tool takes:

- `intent` — a short human-readable description for the Strider log
- `lua` — arbitrary Lua executed inside the current Neovim, with access to
  `vim.api`, `vim.fn`, `vim.cmd`, `vim.lsp`, `vim.diagnostic`, plugin APIs,
  key feeding, buffers, windows, tabs, and the rest of the live editor process

Strider does not apply an allowlist or confirmation layer. Routine inspection is
silent except for a compact log line such as:

```text
• Vim: inspect current LSP clients
```

The Lua source and full tool result remain in pi's session/tool history. Strider
does not render inspection code inline by default. If the Lua mutates editor
state — opens files, moves windows, changes options, feeds keys — you see that
because your Neovim session changes.

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
- `strider_vim` renders only `• Vim: <intent>` by default. The executed Lua and
  raw result stay in pi's tool-call history rather than the visible log.

The log tails new output only while the visible log window is already at the
bottom. Scrolling up pauses follow-mode until you jump back to the tail. The log
winbar shows model, thinking level, context usage, and running cost.

## Clarify

During `:StriderChat` and `:StriderPatch`, the model may pause to ask a
clarifying question, propose a plan, or confirm a destructive action via the
`strider_clarify` tool.

On main chat, questions and plan bodies render inline in the chat log and the
compose buffer is used for the reply. `<C-s>` submits and `<Esc><Esc>` rejects.

On flow workers (`:StriderQ`, `:StriderSearch`, `:StriderPatch`), clarify
prompts stay popup-based and their transcript lands in that worker's log.

Plan proposals pair the `[plan]` body block with an Accept / Modify / Reject
picker. Modify opens an editor seeded with the proposal body; Reject sends
cancellation.

## Tangents And Patch

`:StriderQ` opens a floating editor for a one-shot side question. Submitting it
asks on Strider's dedicated Q worker without popping open main chat. Range-based
Q includes the selected excerpt in the prompt. The focused answer opens in a
non-focus-stealing `strider://StriderQAnswer` window at the bottom-right. It
stays compact while waiting and after the answer is ready; select/focus it or
run bare `:StriderQ` to expand it into a near full-height right-side answer
panel. It stays expanded when you return to code; press `q` or `<Esc>` inside
the card, or run `:StriderQ` again, to fold it. Expanded Q cards include a
follow-up compose section; type there and press `<C-s>` to ask on the same Q
worker. The full transcript, including reasoning and tool calls, lands in
`:StriderLogQ`.

`:StriderPatch` is for hyper-local edits: one function or region at a time. It
requires a visual range or an active review item, embeds the excerpt and range
in the prompt, and instructs the model to stay inside the selection. Patch runs
on the dedicated patch worker and opens a compact flow card; focusing it shows
the patch request, target, touched files, diff blocks, and final summary while
the full transcript remains in `:StriderLogPatch`.
