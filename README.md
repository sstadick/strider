# sherpa

Sherpa is a Neovim plugin for guided code generation, search, review, and patch flows powered by pi.

It keeps the user in Neovim and jumps to touched files or reviewed ranges. Review is the primary walkthrough surface; the four product flows are `SherpaSearch`, `SherpaReview`, `SherpaPatch`, and `SherpaWork`.

## Requirements

- Neovim 0.10+
- `pi` installed and available on `$PATH`
- a configured pi model/provider

## Install

### Local plugin development

Add the repository to your runtime path and load the plugin:

```lua
vim.opt.rtp:append(vim.fn.expand("~/dev/sherpa"))
vim.cmd("runtime plugin/sherpa.lua")
require("sherpa").setup()
```

## Features

- Search — `:SherpaSearch {prompt}` and `:SherpaSearches`
- Review — `:SherpaReview [scope] [prompt]`, `:SherpaNext`, `:SherpaPrev`
- Review comments — `:SherpaComment {text}` and `:SherpaComments`
- Targeted edit — `:'<,'>SherpaPatch {prompt}`
- Broader run + review — `:SherpaWork {prompt}` then `:SherpaReview diff|last|searches`

Any of the text-input commands (`:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`,
`:SherpaWork`, `:SherpaComment`) called with no arguments opens a floating
editor with ghost-text guidance. Submit with `<C-s>`, cancel with `<Esc><Esc>`.

## Commands

### Search

- `:SherpaSearch {prompt}` — run structured Sherpa search
- `:SherpaSearches` — reopen recent search result sets

Search uses a p99-style structured result format.
A single match jumps directly to the file and highlights the range.
Multiple matches use a wrapped telescope/fzf picker when available and otherwise fall back to quickfix.

### Review

- `:SherpaReview [scope] [prompt]` — start review or ask about the active review item
- `:SherpaNext` — move to the next review item
- `:SherpaPrev` — move to the previous review item
- `:SherpaReviewItems` — open the current review item list
- `:SherpaLog` — reopen the transcript / agent buffer

Review scopes:
- `file` — review the current file
- `diff` — review git diff hunks
- `last` — review the latest useful result set, diff, or file fallback
- `searches` — review the latest Sherpa search result set
- visual selection — use `:'<,'>SherpaReview {question}` on a range instead of a named scope

Rules of thumb:
- `:SherpaReview` with no args opens the review popup. With no active review, the first word picks the scope (`file | diff | last | searches | branch <ref>`); with an active review, the popup asks a question about the current item.
- `:SherpaReview diff` starts diff review
- `:SherpaReview searches` reviews the latest search results
- `:SherpaReview why does this matter?` asks about the current active review item
- `:SherpaLog` brings the transcript buffer back when the review pane is the primary surface

Review is read-only.
Comments are local to Sherpa for now and are fed back to the agent when review ends.
They are shaped to leave room for future GitHub PR review integration, but Sherpa does not submit or sync them yet.

### Comments

- `:SherpaComment {text}` — comment on the current review item
- `:'<,'>SherpaComment {text}` — comment on the selected range inside the active review
- `:SherpaComment` with no text opens a multiline comment editor
- `:SherpaComments` — browse recorded review comments

### Targeted edit

- `:'<,'>SherpaPatch {prompt}` — patch the selected range
- `:SherpaPatch {prompt}` — patch the active review item if one is selected

### Broader run

- `:SherpaWork {prompt}` — run a broader implementation request

## Examples

### Search

```vim
:SherpaSearch where is the main entrypoint?
:SherpaSearch show me all websocket entrypoints
```

### Review a file

```vim
:SherpaReview file
:SherpaNext
:SherpaPrev
```

### Review a diff

```vim
:SherpaReview diff
```

### Review search results

```vim
:SherpaSearch where is auth handled?
:SherpaReview searches
```

### Ask about a selected range during review

```vim
:'<,'>SherpaReview why does this block matter?
```

### Leave a range comment during review

```vim
:'<,'>SherpaComment this branch needs a clearer name
```

Or open a multiline comment editor:

```vim
:'<,'>SherpaComment
```

### Targeted edit

```vim
:'<,'>SherpaPatch change this greeting from hi to hello and only touch this line
```

### Full run + review

```vim
:SherpaWork add loading states to the lobby flow
:SherpaReview diff
:'<,'>SherpaComment this branch needs a clearer empty state
:SherpaNext
```

## Development

Sherpa loads the extension in `pi/sherpa-stepper.ts`.

From the repo root, you can start pi with only this extension loaded:

```bash
pi --no-extensions --extension ./pi/sherpa-stepper.ts
```

To mirror Sherpa's backend setup more closely, start pi in RPC mode:

```bash
pi --mode rpc --no-extensions --extension ./pi/sherpa-stepper.ts
```

## Tests

Fast tmux+nvim end-to-end tests live under `tests/` and use a fake pi backend by default.
Optional real-pi smoke tests use the bundled zero-dependency Python fixture project:

```bash
SHERPA_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

See `tests/README.md` for details.

## Notes

- Sherpa uses pi's built-in session history and labels accepted chunks or stops as checkpoints.
- Assistant output is written to a scratch log buffer.
- File jumps currently follow `read`, `edit`, and `write` tool calls.
- `:SherpaReview` is the main walkthrough/review surface.
- `:SherpaSearch` is read-only and returns structured locations into quickfix plus picker-backed selection.
- `:SherpaReview diff|file|last|searches` creates explicit review sessions with range highlighting and a dedicated review pane.
- While waiting on long-running agent responses, Sherpa marks its review/log buffers busy and emits built-in Neovim progress messages.
- `:'<,'>SherpaComment` comments on a visual selection inside the active review, and `:SherpaComment` can open a multiline editor.
- `:SherpaPatch` is selection-first and intended for small local edits.
- Code restoration is not implemented yet; checkpoints are history anchors for now, not workspace restores.
