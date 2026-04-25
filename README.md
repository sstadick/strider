# strider

Strider is a Neovim-first interface for a pi-backed coding workflow. It keeps
main chat, flow work, and review on dedicated lanes, with scoped commands for
search, patch, side questions, and walkthroughs.

Strider uses your existing pi setup: models, providers, extensions, skills,
prompt templates, project instructions, session tree, and cost tracking.

## Examples

Search the codebase without opening the main chat:

```vim
:StriderSearch where is the main entrypoint?
:StriderSearch all websocket entrypoints
```

Start a planned code walkthrough:

```vim
:StriderReview walk me through the authentication flow
:StriderReview walk through the changes on this branch vs main
:'<,'>StriderReview explain what this block does
```

Ask about the current review stop:

```vim
:StriderReview why does this block matter?
:'<,'>StriderReview what assumption breaks here?
```

Leave review comments:

```vim
:'<,'>StriderComment this branch needs a clearer name
:'<,'>StriderComment
```

Patch a small selected range:

```vim
:'<,'>StriderPatch change the greeting literal from hi to hello
```

Ask a side question on the flow lane:

```vim
:StriderQ what does this flag actually do?
:'<,'>StriderQ why is this loop written this way?
```

Browse or resume pi sessions:

```vim
:StriderSessions
:StriderResume 0196f3a
:StriderResume ./some-session.jsonl
```

Work, then review the diff:

```vim
:StriderChat add loading states to the lobby flow
:StriderReview walk through the diff on this branch
:StriderNext
```

Most popup commands submit with `<C-s>` and cancel with `<Esc><Esc>`.
`:StriderChat` opens a persistent log plus compose buffer; with arguments it
prefills compose so you can edit before sending.

## Features

- Planned reviews: `:StriderReview` builds a full ordered set of stops up front.
  `:StriderNext` and `:StriderPrev` navigate mechanically; `:StriderNext!`
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
  `/fork`, `/export`, `/sessions`, `/resume`, and `/switch_session`.
- Status and control surfaces: `:StriderStatus` summarizes lane state, context,
  cost, review progress, pending controls, and recent errors.

## Install

Lazy:

```lua
{
  dir = "~/dev/strider", -- or your clone path / plugin spec
  config = function()
    require("strider").setup()
  end,
}
```

Manual:

```lua
vim.opt.rtp:append(vim.fn.expand("~/dev/strider"))
vim.cmd("runtime plugin/strider.lua")
require("strider").setup()
```

## Requirements

- Neovim 0.10+
- `pi` on `$PATH` with at least one model/provider configured
- `nvim-treesitter` with `markdown`, `markdown_inline`, and language parsers
  for files you expect to inspect
- `render-markdown.nvim`
- `telescope.nvim` or `fzf-lua` optional; Strider falls back to `vim.ui.select`

## Core Commands

| Command | Purpose |
|---|---|
| `:StriderChat [prompt]` | Main chat log + compose |
| `:StriderReview [prompt]` | Planned review walkthrough or current-stop question |
| `:StriderSearch {prompt}` | Structured code search |
| `:StriderQ [prompt]` | One-shot flow-lane side question |
| `:'<,'>StriderPatch [prompt]` | Selection-scoped patch |
| `:StriderNext` / `:StriderPrev` | Move through review stops |
| `:StriderComment [text]` | Record a review comment |
| `:StriderStatus` | Show lane/status/control summary |
| `:StriderStop` | Abort the active turn |
| `:StriderSessions` | Browse saved pi sessions for this project |
| `:StriderResume [id-or-path]` | Resume a saved pi session |

See [docs/usage.md](docs/usage.md) for the full command list and workflow
details.

## Session storage

Strider uses pi's existing JSONL session files. To keep sessions repo-local,
add a pi project settings file:

```json
// .pi/settings.json
{
  "sessionDir": ".pi/sessions"
}
```

Then `/sessions` or `:StriderSessions` browses saved sessions in that directory,
and `/resume <id-or-path>` or `:StriderResume <id-or-path>` resumes one directly.
Session files can contain prompts, file contents, command output, and secrets, so
`.pi/sessions/` should usually be added to `.gitignore` unless you explicitly
want to share them.

## Development

Run pi against this extension only:

```bash
pi --no-extensions --extension ./pi/strider-stepper.ts
pi --mode rpc --no-extensions --extension ./pi/strider-stepper.ts
```

Run the fake-backend test suite:

```bash
python3 -m unittest tests.test_tmux_search tests.test_tmux_review tests.test_tmux_popups tests.test_tmux_tangent tests.test_tmux_log_rendering tests.test_rpc_commands tests.test_plan_helpers tests.test_review_render tests.test_count_lines
```

Optional real-pi smoke test:

```bash
STRIDER_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

## Docs

- [docs/usage.md](docs/usage.md) - commands and workflow details
- [docs/architecture.md](docs/architecture.md) - components, flows, RPC events
- [docs/review-mode.md](docs/review-mode.md) - review lifecycle and state
- [docs/review-planning.md](docs/review-planning.md) - review planning design
- [docs/clarify-plan.md](docs/clarify-plan.md) - clarify tool design notes
- [docs/message-queue.md](docs/message-queue.md) - planned editable follow-up queue
- [docs/saved-sessions.md](docs/saved-sessions.md) - session storage and resume flow
- [recordings/README.md](recordings/README.md) - demo recording workflow
