# Sherpa demos

GIF demos rendered with [vhs](https://github.com/charmbracelet/vhs). Each
scenario is a `.tape` script under `recordings/vhs/` that drives a real
Neovim session against the bundled fake pi backend and fixture projects.

## Prerequisites

```bash
brew install vhs
```

## Render all demos

```bash
for tape in recordings/vhs/*.tape; do vhs "$tape"; done
```

## Render one demo

```bash
vhs recordings/vhs/patch.tape
```

Output gif lands next to the tape name, e.g. `recordings/patch.gif`.

## Demos

- `search.gif` — `:SherpaSearch` jumps to the entrypoint
- `review-file.gif` — `:SherpaReview file`, `:SherpaNext!` acceptance, `:SherpaStatus`, and `:SherpaPrev`
- `review-diff.gif` — `:SherpaReview diff` on an uncommitted change
- `review-searches.gif` — chain a search into `:SherpaReview searches`
- `review-selection.gif` — ask about a visual range inside an active review
- `review-comment.gif` — leave a multi-line comment with the `:SherpaComment` editor
- `review-popup.gif` — `:SherpaReview` with no args opens the floating editor; first word picks the scope, then a follow-up shows the in-review question editor
- `patch.gif` — `:SherpaPatch` on a visual-line selection
- `chat-review.gif` — `:SherpaChat` followed by reviewing the resulting diff
- `reasoning-log.gif` — a chat turn showing faint reasoning text in the log before tools and the final answer
- `tangent.gif` — `:SherpaQ` opens a tangent, asks an unrelated question, then ends so the branch drops from the active path

## How it works

Each tape:

1. Uses `recordings/vhs/prep.sh <scenario> <fixture> [--git|--diff]` to copy a
   fixture from `tests/fixtures/` into `recordings/_workspace/<scenario>`.
2. Launches Neovim via `recordings/vhs/run-nvim.sh`, which wires up the
   fake pi (`SHERPA_TEST_REAL_PI=0`) and the repo-local `minimal_init.lua`.
3. Drives the UI with `Type` / `Sleep` / `Enter` directives.

The prep + launch steps run inside a `Hide` block so the rendered gif opens
directly on Neovim. Fake pi responses keep the demos fast and deterministic.
