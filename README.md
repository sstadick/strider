# sherpa

A Neovim plugin for guided code generation, search, review, and patch
flows backed by [pi](https://github.com/badlogic/pi-mono).

Sherpa keeps you in Neovim and jumps to touched files or reviewed
ranges. Review is the primary walkthrough surface.

## Requirements

- Neovim 0.10+
- `pi` on `$PATH` with at least one model/provider configured
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  or [fzf-lua](https://github.com/ibhagwan/fzf-lua) (optional; used for
  fuzzy pickers, falls back to `vim.ui.select`)
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  (optional; renders markdown in Sherpa output buffers)

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
| `:SherpaSearches` | Reopen recent search result sets |
| `:SherpaReview {prompt}` | Start a pre-planned walkthrough |
| `:'<,'>SherpaReview {prompt}` | Selection-scoped walkthrough |
| `:SherpaReview {question}` | During a review, ask about the current stop |
| `:SherpaNext` / `:SherpaPrev` | Walk review stops |
| `:SherpaReviewItems` | Pick any stop from the plan |
| `:SherpaComment {text}` | Comment on the current stop |
| `:'<,'>SherpaComment {text}` | Comment on a visual sub-range |
| `:SherpaComments` | Browse recorded review comments |
| `:'<,'>SherpaPatch {prompt}` | Small targeted edit on a selection |
| `:SherpaChat [prompt]` | Toggle chat surfaces; with args, send directly |
| `:SherpaRetry` | Re-dispatch a stalled plan turn |

`:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`, and `:SherpaComment`
with no args open a floating editor. Submit with `<C-s>`, cancel with
`<Esc><Esc>`.

## Slash commands in compose

Type into the `:SherpaChat` compose buffer; leading `/` routes to pi
extensions instead of the model. Beyond Sherpa's own `/prompt`,
`/review`, etc., the compose buffer drives:

- `/models [filter]` — fuzzy-pick a model via telescope/fzf
- `/tree` — jump to any previous user message in the session tree

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

Chain chat → review:

```vim
:SherpaChat add loading states to the lobby flow
:SherpaReview walk through the diff on this branch
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

Compose clears on successful send and survives across turns. Sending
while a reply is streaming steers the running turn via pi's `steer`
command — pile up mid-stream corrections freely. Slash-commands
(`/models`, `/tree`, etc.) are rejected mid-turn.

The log's winbar shows live model, context usage, and running cost,
pushed by pi after every turn:

```
Model: anthropic/claude-sonnet-4.5 · Context: 14k / 200k (8.7%) · Cost: $0.0123
```

## Clarify

During `:SherpaChat` and `:SherpaPatch`, the model may pause to ask a
clarifying question, propose a plan for approval, or confirm a
destructive action. Sherpa opens a floating editor (questions / plan
proposals) or a yes/no picker (confirmations). `<C-s>` submits,
`<Esc><Esc>` cancels — the model treats cancellation as "stop."

Plan proposals surface as a read-only preview followed by an
accept/modify/reject picker; modify opens the proposal in an editor
prefilled for in-place changes.

One clarify per turn, enforced in the tool. If you want it to stop
asking, rely on the budget + your global pi system prompt.

## Architecture

- `lua/sherpa/` — Neovim UX, RPC transport, command bindings, pickers,
  highlights.
- `pi/sherpa-stepper.ts` — pi extension: prompt shaping, tools
  (`sherpa_plan`, `sherpa_append_stops`, `sherpa_clarify`), read-only
  guardrails, status widget.

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
