# Strider demos

GIF demos rendered with [vhs](https://github.com/charmbracelet/vhs). Each
scenario is a `.tape` script under `recordings/vhs/` that drives a real
Neovim session against the bundled fake pi backend and fixture projects.

## Prerequisites

```bash
brew install vhs
```

## Render all demos

```bash
recordings/vhs/render-all.sh
```

The script validates every tape, renders each GIF, then prints `ffprobe`
metadata when `ffprobe` is available. Run it from the repo root after UI
changes that affect command names, layouts, fake pi responses, or fixture
content.

## Render one demo

```bash
vhs recordings/vhs/patch.tape
```

Output gif lands next to the tape name, e.g. `recordings/patch.gif`.

## Update a demo

1. Edit the matching `recordings/vhs/*.tape` file.
2. Run `vhs validate recordings/vhs/*.tape`.
3. Render the changed tape with `vhs recordings/vhs/<name>.tape`.
4. Open the GIF and check that it starts after setup, has no error prompts,
   and ends on the intended Strider surface.
5. Run `recordings/vhs/render-all.sh` before committing a full refresh.

## Demos

- `search.gif` — `:StriderSearch` jumps to the entrypoint
- `review-file.gif` — `:StriderReview file`, `:StriderNext!` acceptance, `:StriderStatus`, and `:StriderPrev`
- `review-diff.gif` — `:StriderReview diff` on an uncommitted change
- `review-searches.gif` — chain a search into `:StriderReview searches`
- `review-selection.gif` — ask about a visual range inside an active review
- `review-comment.gif` — leave a multi-line comment with the `:StriderComment` editor
- `review-popup.gif` — `:StriderReview` with no args opens the floating editor; first word picks the scope, then a follow-up shows the in-review question editor
- `patch.gif` — `:StriderPatch` on a visual-line selection
- `chat-review.gif` — `:StriderChat` followed by reviewing the resulting diff
- `reasoning-log.gif` — a chat turn showing faint reasoning text, compact tool output, inline diff rows, and the final answer
- `tangent.gif` — `:StriderQ` opens a flow-lane tangent, asks an unrelated question, and keeps the main chat surfaces out of the way

## How it works

Each tape:

1. Uses `recordings/vhs/prep.sh <scenario> <fixture> [--git|--diff]` to copy a
   fixture from `tests/fixtures/` into `recordings/_workspace/<scenario>`.
2. Launches Neovim via `recordings/vhs/run-nvim.sh`, which wires up the
   fake pi (`STRIDER_TEST_REAL_PI=0`) and the repo-local `minimal_init.lua`.
3. Drives the UI with `Type` / `Sleep` / `Enter` directives.

The prep + launch steps run inside a `Hide` block so the rendered gif opens
directly on Neovim. Fake pi responses keep the demos fast and deterministic.

VHS starts a local terminal server while rendering. If it fails before opening
Neovim with a localhost bind or `randomPort` error, rerun the render from a
normal local shell rather than a sandboxed environment.
