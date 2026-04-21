# sherpa

Sherpa is a Neovim plugin for guided code generation, search, review, and patch flows powered by pi.

It keeps the user in Neovim and jumps to touched files or reviewed ranges. Review is the primary walkthrough surface; the four product flows are `SherpaSearch`, `SherpaReview`, `SherpaPatch`, and `SherpaPrompt`.

## Requirements

- Neovim 0.10+
- `pi` installed and available on `$PATH`
- a configured pi model/provider
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) (recommended — renders markdown in all Sherpa output buffers)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or [fzf](https://github.com/junegunn/fzf) (optional — for search result pickers)

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
- Plain prompt — `:SherpaPrompt {prompt}` (agent turn with clarify available; Sherpa adds no mode-specific behavior beyond making the clarify tool known to the model)

Any of the text-input commands (`:SherpaSearch`, `:SherpaReview`, `:SherpaPatch`,
`:SherpaPrompt`, `:SherpaComment`) called with no arguments opens a floating
editor with ghost-text guidance. Submit with `<C-s>`, cancel with `<Esc><Esc>`.

## Commands

### Search

- `:SherpaSearch {prompt}` — run structured Sherpa search
- `:SherpaSearches` — reopen recent search result sets

Search uses a p99-style structured result format.
Matches open through the same telescope/fzf picker when available for a consistent flow, and otherwise fall back to quickfix.
If only one match exists and no picker is available, Sherpa still highlights that file/range after populating quickfix.

### Review

- `:SherpaReview {prompt}` — start a review (plain prose describing what you want reviewed)
- `:'<,'>SherpaReview {prompt}` — start a review scoped to a visual selection (every line covered)
- `:SherpaReview {question}` — with an active review, ask a question about the current stop
- `:SherpaNext` — move to the next review stop
- `:SherpaPrev` — move to the previous review stop
- `:SherpaReviewItems` — pick any stop from the plan
- `:SherpaLog` — reopen the transcript / agent buffer

How a review works:

1. You give Sherpa a prompt. If you mention a diff, PR, or branch changes,
   the model will plan a diff review; if you gave it a visual selection, it
   plans a selection review; otherwise it's a free-form review.
2. The model produces a full plan up front — an ordered list of stops,
   each with a file range, a title, a `why` hook, a sidebar `summary`,
   and a longer `explanation` rendered inline in the code buffer above
   the stop's start line. Optional pinned annotations call out specific
   lines or sub-ranges. The plan lands via the `sherpa_plan` tool and
   shows up in the review pane as a TOC.
3. `:SherpaNext` / `:SherpaPrev` walk the fixed plan. Navigation is
   instant — explanations were written at plan time, so no per-stop
   model call.
4. For selection and diff reviews, every line in the range / every changed
   line is guaranteed to appear in some stop. Free-form reviews let the
   model pick what matters.
5. `:SherpaReview <question>` with an active review sends a fresh model
   turn scoped to the current stop — that's the only in-review path that
   round-trips the model.
6. Model may append new stops mid-review on free-form plans (via
   `sherpa_append_stops`) if it spots something additional worth visiting.

Review is read-only. Comments are local to Sherpa for now and are fed back
to the agent when review ends. They're shaped to leave room for future
GitHub PR review integration, but Sherpa doesn't submit or sync them yet.

### Comments

- `:SherpaComment {text}` — comment on the current review item
- `:'<,'>SherpaComment {text}` — comment on the selected range inside the active review
- `:SherpaComment` with no text opens a multiline comment editor
- `:SherpaComments` — browse recorded review comments

### Targeted edit

- `:'<,'>SherpaPatch {prompt}` — patch the selected range
- `:SherpaPatch {prompt}` — patch the active review item if one is selected

### Plain prompt

- `:SherpaPrompt {prompt}` — send a plain agent turn. Sherpa adds no
  mode-specific prompting beyond making the `sherpa_clarify` tool
  available; your global pi system prompt governs everything else.

## Examples

### Search

```vim
:SherpaSearch where is the main entrypoint?
:SherpaSearch show me all websocket entrypoints
```

### Review something in the project

```vim
:SherpaReview walk me through the authentication flow
:SherpaNext
:SherpaPrev
```

### Review a diff vs main

```vim
:SherpaReview walk me through the changes on this branch vs main
```

### Review a selection

```vim
:'<,'>SherpaReview explain what this block does
```

### Ask a question about the current stop

```vim
:SherpaReview why does this block matter?
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

### Full prompt + review

```vim
:SherpaPrompt add loading states to the lobby flow
:SherpaReview walk through the diff on this branch
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

### Clarification during prompt / patch

During `:SherpaPrompt` and `:SherpaPatch`, the model may pause to ask a
clarifying question, propose a plan for approval, or confirm a
destructive action. When this happens, Sherpa opens a small floating
editor (or a yes/no picker for confirmations). Submit your reply with
`<C-s>`; cancel with `<Esc><Esc>` — the model treats cancellation as
"don't proceed" and stops with a short explanation.

The model is budgeted to at most one clarification per request. If the
prompt guidance isn't enough to keep it from over-asking, this is the
backstop.

## Notes

- Sherpa uses pi's built-in session history and labels accepted stops as checkpoints.
- Assistant output is written to a scratch log buffer; during review the `sherpa://review` pane is the primary surface.
- Outside of review, file jumps follow `read`, `edit`, and `write` tool calls. During review, the buffer stays on the active planned stop — the model's tool calls don't yank the cursor away.
- `:SherpaReview` is the main walkthrough surface. Reviews are pre-planned: the model produces a full stop list via the `sherpa_plan` tool before walkthrough begins, so `:SherpaNext` advances through a fixed plan.
- Selection and diff reviews guarantee every line is visited; free-form reviews let the model pick what matters.
- `:SherpaSearch` is read-only and returns structured locations into quickfix plus picker-backed selection.
- While waiting on long-running agent responses, Sherpa marks its review/log buffers busy and emits Neovim progress messages.
- `:'<,'>SherpaComment` comments on a visual selection inside the active review, and `:SherpaComment` can open a multiline editor.
- `:SherpaPatch` is selection-first and intended for small local edits.
- Code restoration is not implemented yet; checkpoints are history anchors for now, not workspace restores.
