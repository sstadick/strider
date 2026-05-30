# Usage

This page keeps the command-level detail that does not need to live in the
README.

## Commands

| Command | What it does |
|---|---|
| `:StriderSearch {prompt}` | Structured code search with picker and quickfix output |
| `:StriderSearches` | Reopen recent search result sets |
| `:StriderLogFlow` | Toggle the search/flow log |
| `:StriderLogQ` | Toggle the latest StriderQ worker log |
| `:StriderLogPatch` | Toggle the dedicated patch worker log |
| `:StriderReview [prompt]` | Open the review popup; submit to start a dedicated review-lane walkthrough or ask about the current stop |
| `:StriderLogReview` | Toggle the dedicated review log |
| `:'<,'>StriderReview [prompt]` | Open the review popup scoped to the selected range |
| `:StriderNext` / `:StriderPrev` | Walk review stops; `:StriderNext!` accepts the current stop first |
| `:StriderReviewItems` | Pick any stop from the plan |
| `:StriderReviewSummary` | Reopen the completed review summary editor and forward it to main chat |
| `:StriderComment {text}` | Comment on the current stop |
| `:'<,'>StriderComment {text}` | Comment on a visual sub-range |
| `:StriderComments` | Browse recorded review comments |
| `:StriderPatch [prompt]` | Open the patch popup for the current review item |
| `:'<,'>StriderPatch [prompt]` | Open the patch popup for a visual selection |
| `:StriderQ [--fast\|--deep] [prompt]` | Open the StriderQ popup; choose fast/deep before submitting |
| `:StriderQ! [--fast\|--deep] [prompt]` | Same as `:StriderQ`; kept for muscle memory |
| `:'<,'>StriderQ [--fast\|--deep] [prompt]` | Open the StriderQ popup with a selection-scoped Q-worker question |
| `:StriderQs` | Pick a StriderQ answer and open it in a normal split |
| `:StriderQLatest` | Open the newest StriderQ answer directly in a normal split |
| `:StriderPatches` | Pick a patch summary and open it in a normal split |
| `:StriderPatchLatest` | Open the newest patch summary directly in a normal split |
| `:StriderCards` | Pick an existing named Chat/Q/Patch surface with telescope/fzf fallback |
| `:StriderCardsClear[!]` | Dismiss completed surfaces; `!` also dismisses running surfaces |
| `:StriderChat` | Toggle the chat log + compose split; collapsed state leaves a compact card |
| `:[range]StriderChat [prompt]` | Open chat with the compose buffer prefilled from the range/prompt |
| `:StriderChatReadOnly [on\|off\|toggle]` | Toggle the chat-only read-only prompt guard; compose shows an `RO` badge |
| `:StriderStop` | Abort the current main-lane turn |
| `:StriderStopFlow` | Abort active Q/Search/Patch worker turns |
| `:StriderStatus` | Open the current lane/status/control summary |
| `:StriderSessions` | Browse saved pi sessions for this project |
| `:StriderResume [id-or-path]` | Resume a saved pi session |
| `:StriderRetry` | Re-dispatch a stalled plan turn |

`:StriderSearch`, `:StriderReview`, `:StriderPatch`, `:StriderQ`,
`:StriderComment`, and the end-of-review summary confirmation use floating
editors. Submit with `<C-s>`, cancel with `<Esc><Esc>`. When starting a new
`:StriderReview`, press `<C-g>c` in the review editor to toggle between a fresh
review context and copying the current main chat transcript as background.

`:StriderChat` keeps persistent main log and compose buffers, shown as a
right-side split log/compose stack. Toggling it closed hides those surfaces; if
chat was the only visible normal window, Strider leaves you in a new empty
buffer. Use `:StriderChatReadOnly` (or `gR` in normal mode / `<C-g>r` in insert
mode inside `strider://compose`) to toggle a chat-only read-only guard; the
compose winbar shows `RO` while enabled. Compact Q cards share right-edge
stack slots with the collapsed chat card; patch summaries stay in the background
until you pull them up.
`:StriderQ`, `:StriderSearch`, and `:StriderPatch` run on separate flow-worker
processes, so Q and patch can proceed independently of each other and main chat.
Each new StriderQ answer gets its own Q worker process. Search transcript lives
in `:StriderLogFlow`, the latest Q worker in `:StriderLogQ`, and patch in
`:StriderLogPatch`. `:StriderQ` records answers without opening a card or split;
completion leaves a low-disruption cue, and `:StriderQs` opens a picker for
ready/running Q answers. Selecting a Q opens its answer in a normal split.
`:StriderPatch` records a patch summary without opening a card or split;
`:StriderPatches` and `:StriderPatchLatest` open patch summaries in normal
splits. Use `q` to close those splits, `d` to dismiss the record, `o` to open
its worker log, or `[c`/`]c` to move between records in that lane. Reasoning,
tool calls, and full tool output remain in the operation's log. When flow-worker
operations finish, Strider always leaves a bottom-left green-dot completion cue;
if that worker's log is hidden, it also sends a notification.
`:StriderStopFlow` aborts active flow-worker turns. `:StriderReview` runs on a
dedicated review lane whose transcript lives in `:StriderLogReview`; that review
log is manual/diagnostic and does not open on review start or review end.

## Chat Compose

Type into the `:StriderChat` compose split. Leading `/` routes to pi
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
ghost text and the winbar distinguish `<C-s>` sending a new prompt from `<C-s>`
sending a steer while a turn is in flight; clarify answers use the same send key
with their own hint. Commands that use dedicated RPC messages, such as
`/compact`, `/new`, and `/export`, also set the main lane busy and show
`Working` in the compose and log winbars until pi replies. Sending while a reply
is streaming steers the running turn via pi's `steer` command. Slash commands
are rejected mid-turn. In logs, normal prompts start with `›`, steers start with
`»`, and Q follow-ups start with `↳` so their markers are visually distinct.

`:StriderStop` aborts the main-lane turn; `:StriderStopFlow` aborts active
Q/search/patch worker turns. `:StriderStatus` opens a compact summary of lane
state, pending controls, review progress, model/context widget lines, and the
last error.

## Lane Model Profiles

Strider starts a separate pi RPC process per lane. Configure startup model and
reasoning choices per lane with `setup({ lane_models = ... })`; existing worker
processes keep their current model until they are restarted.

```lua
require("strider").setup({
  model_env_var = "PI_MODEL_ENV", -- default
  lane_models = {
    chat = {
      default = { model = "openai/gpt-5.5", reasoning = "xhigh" },
      work = { model = "bedrock/opus4-6", reasoning = "high" },
    },
    q = {
      default = { model = "anthropic/claude-sonnet-4", reasoning = "low" },
      work = { model = "openai/gpt-5", reasoning = "xhigh" },
    },
    search = {
      default = { model = "openai/gpt-5-mini", reasoning = "low" },
      work = { model = "openai/gpt-5-search", reasoning = "medium" },
    },
  },
  q_models = {
    fast = { model = "codex-spark" },
    deep = "chat", -- use the resolved chat/main lane model
  },
  q_default_model = "fast",
})
```

`PI_MODEL_ENV=work` selects each lane's `work` profile; unset, empty, or
`default` selects `default`. If a lane lacks the requested profile, it falls
back to that lane's `default`. Lane keys are `chat`/`main`, `q` (including
`q-2`, `q-3`, ...), `search`/`flow`, `patch`, `review`, plus a top-level
`default` fallback. Use either `reasoning` or pi's `thinking` key; both map to
pi's `--thinking` startup option.

StriderQ also has lightweight per-question presets. `fast` defaults to
`codex-spark`; `deep` resolves to the same profile the chat/main lane would use.
These presets override `lane_models.q` for submitted Q workers; set a preset to
`"q"` if you want it to use the legacy Q lane profile. Pass `--fast` or
`--deep` to `:StriderQ`, or press `<Tab>` in the Q prompt to switch before
submitting.

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
   free-form. On the review start editor, `<C-g>c` toggles whether the review
   starts fresh or copies the main chat transcript as background context.
2. The model calls `strider_plan` with ordered stops, file ranges, titles,
   hooks, and explanations.
3. The plan appears in the review pane as a table of contents.
4. `:StriderNext` / `:StriderPrev` walk the fixed plan. `:StriderNext!` accepts
   the current stop before advancing.
5. `:StriderReview <question>` during a review asks about the current stop.
   Plain answers render in the review pane without opening the review log;
   ranged questions render as inline block annotations.

Review mode is read-only. Comments stay local and are fed back to the agent
when the review ends. No external sync is performed.

## Log Rendering

Tool calls show their results inline.

- `edit` operations render under `• Edited <path> (+N -M)` with inline diff
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
picker. Modify seeds the chat compose buffer with the proposal body so the user
can edit and send it in place; Reject sends cancellation.

## StriderQ And Patch

`:StriderQ` opens a floating editor for a side question without popping open
main chat. Use `--fast`/`--deep`, or press `<Tab>` in the editor, to choose the
Q model before submitting. Range-based Q includes the selected excerpt in the
prompt. Each submitted question creates a named answer record and its own worker
process; the first keeps the legacy `strider://StriderQAnswer` buffer and later
records use `strider://flow-card/q/N`. No answer window opens automatically;
completion leaves a low-disruption cue. Use `:StriderQLatest` to open the newest
answer directly, or pick answers with `:StriderQs` / `:StriderCards`; all open in
a normal split. In the split, `a` opens a follow-up prompt that reuses the
same Q worker and answer record; follow-up question lines use the distinct `↳`
marker. `q` closes the split, `d` dismisses the answer
record, `o` opens its worker log, and `[c`/`]c` moves between Q records.
`:StriderQ!` behaves like `:StriderQ` and is kept for muscle memory; every new
submission starts another Q worker, so multiple StriderQ answers can run
concurrently. The full transcript, including reasoning and tool calls, lands in
that answer's worker log (`:StriderLogQ` for the first Q,
`strider://StriderLogQ-N` for later Qs).

`:StriderPatch` is for hyper-local edits: one function or region at a time. It
requires a visual range or an active review item, embeds the excerpt and range
in the prompt, and instructs the model to stay inside the selection. Patch runs
on the dedicated patch worker and records a background summary. Use
`:StriderPatchLatest` or `:StriderPatches` to open the patch request, target,
touched files, diff blocks, and final summary in a normal split; the full
transcript remains in `:StriderLogPatch`.
