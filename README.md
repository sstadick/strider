# sherpa

A Neovim plugin that wraps [pi](https://github.com/badlogic/pi-mono) in
a set of scoped commands — review, search, patch, tangent, chat — each
with its own guardrails so the agent stays in its lane.

Sherpa is pi-backed: your pi model, providers, extensions, skills,
prompt templates, `AGENTS.md` / `CLAUDE.md`, session tree, and cost
tracking all apply. Sherpa adds the Neovim surfaces and the scoped
modes; pi does the agent work.

Everything happens in native buffers (`sherpa://log`, `sherpa://compose`,
`sherpa://review`). Review is the primary walkthrough surface.

## Requirements

- Neovim 0.10+
- `pi` on `$PATH` with at least one model/provider configured
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
  with parsers for `markdown`, `markdown_inline`, and the languages
  you'll be reading (rust / typescript / lua / python / …). Drives
  the syntax highlighting inside fenced tool output in the log.
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  — renders the log's markdown and fenced code blocks
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  or [fzf-lua](https://github.com/ibhagwan/fzf-lua) (optional; used for
  fuzzy pickers, falls back to `vim.ui.select`)

## Install

Lazy:

```lua
{
  dir = "~/dev/sherpa",  -- or clone path / github spec
  config = function() require("sherpa").setup() end,
}
```

Manual:

```lua
vim.opt.rtp:append(vim.fn.expand("~/dev/sherpa"))
vim.cmd("runtime plugin/sherpa.lua")
require("sherpa").setup()
```

## Commands

| Command | What it does |
|---|---|
| `:SherpaSearch {prompt}` | Structured code search (picker + quickfix) |
| `:SherpaSearches` | Reopen recent flow-lane search result sets |
| `:SherpaLogFlow` | Toggle the flow log used by Q/Search/Patch |
| `:SherpaReview [prompt]` | Open the review popup; submit to start a dedicated review-lane walkthrough or ask about the current stop |
| `:SherpaLogReview` | Toggle the dedicated review log |
| `:'<,'>SherpaReview [prompt]` | Open the review popup scoped to the selected range |
| `:SherpaNext` / `:SherpaPrev` | Walk review stops |
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
| `:SherpaRetry` | Re-dispatch a stalled plan turn |

`:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`, `:SherpaQ`, and
`:SherpaComment` use floating editors. Submit with `<C-s>`, cancel with
`<Esc><Esc>`. `:SherpaChat` keeps the persistent main log + compose
buffers; `:SherpaQ`, `:SherpaSearch`, and `:SherpaPatch` run on a
separate flow lane whose transcript lives in `:SherpaLogFlow`.
`:SherpaReview` runs on its own dedicated review lane whose transcript
lives in `:SherpaLogReview`.

## Slash commands in compose

Type into the `:SherpaChat` compose buffer; leading `/` routes to pi
extensions instead of the model. Beyond Sherpa's own `/prompt`,
`/review`, etc., the compose buffer drives:

- `/models [filter]` — fuzzy-pick a model via telescope/fzf
- `/tree` — jump to any previous user message in the session tree
- `/thinking [level]` — cycle or set the reasoning level
  (`off`/`minimal`/`low`/`medium`/`high`/`xhigh`); also bound to
  `<S-Tab>` in compose, mirroring pi's own shift-tab. Pi clamps the
  level to what the current model supports.

## Examples

Search:

```vim
:SherpaSearch where is the main entrypoint?
:SherpaSearch all websocket entrypoints
```

Review a file, a diff, or a selection:

```vim
:SherpaReview walk me through the authentication flow
:SherpaReview walk through the changes on this branch vs main
:'<,'>SherpaReview explain what this block does
```

Ask a follow-up on the current stop (or on a sub-range):

```vim
:SherpaReview why does this block matter?
:'<,'>SherpaReview what assumption breaks here?
```

Comment:

```vim
:'<,'>SherpaComment this branch needs a clearer name
:'<,'>SherpaComment                       " opens multiline editor
```

Patch:

```vim
:'<,'>SherpaPatch change greeting from hi to hello, only this line
```

Tangent — ask something mid-session without polluting history:

```vim
:SherpaQ what does this flag actually do?    " opens popup prefilled with the question
:'<,'>SherpaQ why is this loop written this way?
```

Chain chat → review:

```vim
:SherpaChat add loading states to the lobby flow   " prefill compose, then <C-s>
:SherpaReview walk through the diff on this branch  " prefill popup, then <C-s>
:SherpaNext
```

## How review works

1. You prompt. If you mention a diff, PR, or branch changes, the model
   plans a diff review. A visual selection plans a selection review.
   Otherwise it's free-form.
2. The model produces a full plan up front via the `sherpa_plan` tool —
   an ordered list of stops with file ranges, titles, hooks, and
   explanations. The plan appears in the review pane as a TOC.
3. `:SherpaNext` / `:SherpaPrev` walk the fixed plan. Navigation is
   instant — explanations were written at plan time, so no per-stop
   model call.
4. Selection and diff reviews cover every targeted line. Free-form
   reviews let the model choose.
5. `:SherpaReview <question>` during a review triggers a per-stop model
   turn. Plain questions stream into the log; ranged questions
   (`:'<,'>SherpaReview ...`) render as inline block annotations.
6. On free-form plans, the model may `sherpa_append_stops` mid-review
   to add stops it spots are worth visiting.

Review is read-only. Comments stay local and are fed back to the agent
when the review ends. No external sync.

## Chat

`:SherpaChat` (no args) toggles two persistent buffers: `sherpa://log`
(transcript) and `sherpa://compose` (input). `<C-s>` in compose sends.
With args, or with an Ex range like `:1,5SherpaChat`, Sherpa opens chat
and prefills compose instead of sending immediately. Range-prefill uses
`path:start-end` so you can add the rest of the request before sending.

Compose clears on successful send and survives across turns. Sending
while a reply is streaming steers the running turn via pi's `steer`
command — pile up mid-stream corrections freely. Slash-commands
(`/models`, `/tree`, etc.) are rejected mid-turn. `:SherpaStop` aborts
the in-flight turn; the abort shows up as a cancel-flavored `[error]`
block in the log and the activity spinner stops.

Errors from pi (no API key, model rejected by the provider, etc.)
render inline as red `[error]` blocks in the log rather than silent
hangs, so failed turns are always visible.

Tool calls show their results inline. `edit` operations append a
`[diff]` block with green `+` / red `-` line colors matching the
gutter signs on the edited file. `read` and `write` wrap their
content in a fenced markdown code block tagged with the file's
language (from the extension), so treesitter + render-markdown give
you real syntax highlighting. `bash` / `grep` / `ls` / `find` render
as plain muted text. In both cases only the last 15 lines are shown;
when earlier lines are hidden, a muted `N earlier lines…` note sits
above the block. File paths in `[tool]` headers get their own accent
color so targets pop when scanning.

The log's winbar shows live model, thinking level, context usage, and
running cost, pushed by pi after every turn:

```
Model: openai-codex/gpt-5.4 (high) · Context: 14k / 200k (8.7%) · Cost: $0.0123
```

The `(level)` segment reflects the current reasoning setting. Cycle it
with `<S-Tab>` in compose (same as pi's TUI), or set explicitly with
`/thinking <level>`.

When the model pauses to ask a clarifying question or propose a plan
(via the `sherpa_clarify` tool), the question lands in the chat log as
a `[clarify]` or `[plan]` block and the compose buffer is hijacked for
the reply — a `[Clarify]` badge appears on the compose winbar. `<C-s>`
sends the answer; `<Esc><Esc>` rejects. Plan proposals also show an
Accept / Modify / Reject picker; Modify seeds compose with the
proposal body so you can edit in place.

## Tangents

`:SherpaQ` opens a floating editor for a one-shot side question.
Submitting it asks the question on Sherpa's separate flow lane without
popping open main chat. If you invoke it with a range, Sherpa includes
the selected excerpt in the prompt.

Answers land in `:SherpaLogFlow`. Q no longer branches the main chat
session tree.

## Review lane

`:SherpaReview` uses its own dedicated pi process. Planning, in-review
questions, and the final review-summary turn all stay on that review
lane. When the review ends, Sherpa forwards the summary back into the
main chat transcript and stops the review backend.

## Patch

`:SherpaPatch` is for hyper-local edits — one function or region at a
time. It opens a floating editor and requires a visual range (or an
active review item). Sherpa embeds the excerpt + range in the prompt
and instructs the model to stay inside the selection. Patch runs on the
flow lane; transcript/tool output lands in `:SherpaLogFlow`.

## Clarify

During `:SherpaChat` and `:SherpaPatch`, the model may pause to ask a
clarifying question, propose a plan, or confirm a destructive action
(via the `sherpa_clarify` tool).

On main chat, questions and plan bodies render inline in the chat log
and the compose buffer is hijacked for the reply, marked with a
`[Clarify]` badge on the winbar. `<C-s>` submits, `<Esc><Esc>` rejects.

On the flow lane (`:SherpaQ`, `:SherpaSearch`, `:SherpaPatch`), clarify
prompts stay popup-based and their transcript lands in `:SherpaLogFlow`.

Plan proposals pair the `[plan]` body block with an Accept / Modify /
Reject picker. Modify opens an editor seeded with the proposal body;
Reject sends cancellation.

Confirmations (yes/no) still surface via a plain `vim.ui.select`
picker — no keyboard-to-compose roundtrip, just a pick.

One clarify per turn, enforced in the tool. If you want it to stop
asking, rely on the budget + your global pi system prompt.

## Architecture

- `lua/sherpa/` — Neovim UX, RPC transport, command bindings, pickers,
  highlights.
- `pi/sherpa-stepper.ts` — pi extension: prompt shaping, tools
  (`sherpa_plan`, `sherpa_append_stops`, `sherpa_clarify`), read-only
  guardrails, status widget, tangent anchor/end commands.

The plugin speaks pi's RPC protocol. Dialog UI (`editor`, `confirm`,
`select`, `input`) flows from the extension through pi to the plugin,
which drives native Neovim pickers/editors and replies over the same
channel.

See `docs/architecture.md` for the full picture.

## Development

Run pi against this extension only:

```bash
pi --no-extensions --extension ./pi/sherpa-stepper.ts
# or RPC mode (Sherpa's path):
pi --mode rpc --no-extensions --extension ./pi/sherpa-stepper.ts
```

## Tests

Fast fake-backend tmux + nvim tests:

```bash
python3 -m unittest tests.test_tmux_search tests.test_tmux_review tests.test_tmux_popups tests.test_plan_helpers tests.test_count_lines
```

Optional real-pi smoke (slower, needs API access):

```bash
SHERPA_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

See `tests/README.md` for the harness.

## Related docs

- `docs/architecture.md` — components, flows, RPC events
- `docs/review-mode.md` — review lifecycle + state shape
- `docs/review-planning.md` — why review is pre-planned
- `docs/clarify-plan.md` — design notes for the clarify tool
- `docs/saved-sessions.md` — deferred session-resume design
- `recordings/README.md` — how to render demos
