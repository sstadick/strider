# Strider demos

GIF demos rendered with [vhs](https://github.com/charmbracelet/vhs). Each
scenario is a `.tape` script under `recordings/vhs/` that drives a real
Neovim session against the bundled fake pi backend and fixture projects.

## Prerequisites

```bash
brew install vhs
```

The renderer also expects `nvim`, `python3`, and `git` on `$PATH`. `ffprobe`
from ffmpeg is optional; when present, the render script prints GIF metadata
after each run.

## Render all demos

```bash
recordings/vhs/render-all.sh
```

The script validates every tape, renders each GIF, then prints `ffprobe`
metadata when `ffprobe` is available. Run it from the repo root after UI
changes that affect command names, layouts, fake pi responses, or fixture
content.

To check whether any tape output is missing or older than its source:

```bash
python3 scripts/check_recordings.py
```

## Render one demo

```bash
recordings/vhs/render-all.sh patch
```

You can pass a demo name (`patch`) or a tape path
(`recordings/vhs/patch.tape`). Output GIFs land under `recordings/`, e.g.
`recordings/patch.gif`.

Useful render options:

```bash
VHS_VALIDATE=0 recordings/vhs/render-all.sh patch
VHS_QUIET=1 recordings/vhs/render-all.sh search review-file
VHS_BIN=/opt/homebrew/bin/vhs recordings/vhs/render-all.sh
```

## Update a demo

1. Edit the matching `recordings/vhs/*.tape` file.
2. Render the changed tape with `recordings/vhs/render-all.sh <name>`.
   The script validates selected tapes before rendering.
3. For commands that open a Strider popup or compose buffer, include the
   explicit `Ctrl+S` submit step in the tape after the command-line `Enter`.
4. Open the GIF and check that it starts after setup, has no error prompts,
   and ends on the intended Strider surface.
5. Run `python3 scripts/check_recordings.py` to confirm the GIF is fresh.
6. Run `recordings/vhs/render-all.sh` before committing a full refresh.

## Demos

- `search.gif` — `:StriderSearch` jumps to the entrypoint
- `review-file.gif` — `:StriderReview file`, `:StriderNext!` acceptance, `:StriderStatus`, and `:StriderPrev`
- `review-diff.gif` — `:StriderReview diff` on an uncommitted change
- `review-searches.gif` — chain a search into `:StriderReview searches`
- `review-selection.gif` — ask about a visual range inside an active review
- `review-comment.gif` — leave a multi-line comment with the `:StriderComment` editor
- `review-popup.gif` — `:StriderReview` with no args opens the floating editor; first word picks the scope, then a follow-up shows the in-review question editor
- `patch.gif` — `:StriderPatch` on a visual-line selection, then `:StriderPatchLatest` to pull up the summary
- `chat-review.gif` — `:StriderChat` followed by reviewing the resulting diff
- `chat-readonly.gif` — `:StriderChatReadOnly` adds an `RO` badge and read-only prompt guard for chat
- `reasoning-log.gif` — a chat turn showing faint reasoning text, compact tool output, inline diff rows, and the final answer
- `tangent.gif` — `:StriderQ` asks a side question, records the answer for `:StriderQs`, and keeps the main chat surfaces out of the way

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
