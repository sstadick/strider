# sherpa

Sherpa is a Neovim-first interface for a pi-backed coding workflow. It keeps
the agent in scoped modes: review, search, patch, tangent, and chat.

Sherpa uses your existing pi setup: models, providers, extensions, skills,
prompt templates, project instructions, session tree, and cost tracking.

## Examples

Search the codebase without opening the main chat:

```vim
:SherpaSearch where is the main entrypoint?
:SherpaSearch all websocket entrypoints
```

Start a planned code walkthrough:

```vim
:SherpaReview walk me through the authentication flow
:SherpaReview walk through the changes on this branch vs main
:'<,'>SherpaReview explain what this block does
```

Ask about the current review stop:

```vim
:SherpaReview why does this block matter?
:'<,'>SherpaReview what assumption breaks here?
```

Leave review comments:

```vim
:'<,'>SherpaComment this branch needs a clearer name
:'<,'>SherpaComment
```

Patch a small selected range:

```vim
:'<,'>SherpaPatch change the greeting literal from hi to hello
```

Ask a side question on the flow lane:

```vim
:SherpaQ what does this flag actually do?
:'<,'>SherpaQ why is this loop written this way?
```

Work, then review the diff:

```vim
:SherpaChat add loading states to the lobby flow
:SherpaReview walk through the diff on this branch
:SherpaNext
```

Most popup commands submit with `<C-s>` and cancel with `<Esc><Esc>`.
`:SherpaChat` opens a persistent log plus compose buffer; with arguments it
prefills compose so you can edit before sending.

## Features

- Planned reviews: `:SherpaReview` builds a full ordered set of stops up front.
  `:SherpaNext` and `:SherpaPrev` navigate mechanically; `:SherpaNext!`
  accepts the current stop before advancing.
- Dedicated lanes: main chat, flow work (`Q`/search/patch), and review each
  have their own transcript and in-flight state.
- Scoped guardrails: review/search/plan are read-only; patch prompts are
  selection-scoped and intended for small local edits.
- Native Neovim UI: logs, compose buffers, floating editors, quickfix/pickers,
  inline review annotations, comments, and touched-file navigation.
- Useful transcript rendering: edit tools show inline diff rows; read/write
  output keeps syntax-highlighted code fences; command/search output uses
  compact rows that do not accidentally render as markdown.
- pi controls in compose: `/models`, `/tree`, `/thinking`, `/compact`, `/new`,
  `/fork`, `/export`, and `/resume`.
- Status and control surfaces: `:SherpaStatus` summarizes lane state, context,
  cost, review progress, pending controls, and recent errors.

## Install

Lazy:

```lua
{
  dir = "~/dev/sherpa", -- or your clone path / plugin spec
  config = function()
    require("sherpa").setup()
  end,
}
```

Manual:

```lua
vim.opt.rtp:append(vim.fn.expand("~/dev/sherpa"))
vim.cmd("runtime plugin/sherpa.lua")
require("sherpa").setup()
```

## Requirements

- Neovim 0.10+
- `pi` on `$PATH` with at least one model/provider configured
- `nvim-treesitter` with `markdown`, `markdown_inline`, and language parsers
  for files you expect to inspect
- `render-markdown.nvim`
- `telescope.nvim` or `fzf-lua` optional; Sherpa falls back to `vim.ui.select`

## Core Commands

| Command | Purpose |
|---|---|
| `:SherpaChat [prompt]` | Main chat log + compose |
| `:SherpaReview [prompt]` | Planned review walkthrough or current-stop question |
| `:SherpaSearch {prompt}` | Structured code search |
| `:SherpaQ [prompt]` | One-shot flow-lane side question |
| `:'<,'>SherpaPatch [prompt]` | Selection-scoped patch |
| `:SherpaNext` / `:SherpaPrev` | Move through review stops |
| `:SherpaComment [text]` | Record a review comment |
| `:SherpaStatus` | Show lane/status/control summary |
| `:SherpaStop` | Abort the active turn |

See [docs/usage.md](docs/usage.md) for the full command list and workflow
details.

## Development

Run pi against this extension only:

```bash
pi --no-extensions --extension ./pi/sherpa-stepper.ts
pi --mode rpc --no-extensions --extension ./pi/sherpa-stepper.ts
```

Run the fake-backend test suite:

```bash
python3 -m unittest tests.test_tmux_search tests.test_tmux_review tests.test_tmux_popups tests.test_tmux_tangent tests.test_tmux_log_rendering tests.test_rpc_commands tests.test_plan_helpers tests.test_review_render tests.test_count_lines
```

Optional real-pi smoke test:

```bash
SHERPA_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

## Docs

- [docs/usage.md](docs/usage.md) - commands and workflow details
- [docs/architecture.md](docs/architecture.md) - components, flows, RPC events
- [docs/review-mode.md](docs/review-mode.md) - review lifecycle and state
- [docs/review-planning.md](docs/review-planning.md) - review planning design
- [docs/clarify-plan.md](docs/clarify-plan.md) - clarify tool design notes
- [docs/message-queue.md](docs/message-queue.md) - planned editable follow-up queue
- [recordings/README.md](recordings/README.md) - demo recording workflow
