# Tool Output Styling Plan

## Proposal

- Date proposed: 2026-04-24
- Implementation status: not implemented

## Goal

Make non-code tool output feel like the Codex transcript style while keeping
Sherpa's useful pi-style visibility into tool results.

The main change is to stop rendering `bash`, `grep`, `find`, and `ls` output as
markdown code blocks. Instead, render them as compact rows attached to the tool
header. Keep `read` and `write` output as fenced code blocks because their free
syntax highlighting is valuable.

## Target Shape

### Bash success with no output

```text
• Ran command
  luajit -b lua/sherpa/ui.lua /tmp/sherpa-ui.luac
  ✓ exited 0
```

### Bash with output

```text
• Ran command
  pytest tests/test_tmux_log_rendering.py -q
  │ ..F..
  │ FAILED tests/test_tmux_log_rendering.py::test_diff_rows
  ✗ exited 1
```

### Truncated output

```text
• Ran command
  npm test
  42 earlier lines…
  │ PASS src/parser.test.ts
  │ PASS src/queue.test.ts
  │ FAIL src/ui.test.ts
  ✗ exited 1
```

### Grep

```text
• Explored "append_tool_output" lua/sherpa
  3 matches
  │ lua/sherpa/ui.lua:1193  function M.append_tool_output(text, lang, lane, opts)
  │ lua/sherpa/rpc.lua:678  ui.append_tool_output(text, lang, lane, insert_opts)
  │ tests/test_tmux_log_rendering.py:110  require('sherpa.ui').append_tool_output(...)
```

### Find

```text
• Explored message-queue
  2 paths
  │ docs/message-queue.md
  │ docs/plan.md
```

### Ls

```text
• Explored lua/sherpa
  9 entries
  │ init.lua
  │ log_pin.lua
  │ picker.lua
  │ review.lua
  │ rpc.lua
```

## Rules

1. Keep `read` and `write` on the existing fenced-code renderer.
2. Keep `edit` on inline diff rows.
3. Render `bash`, `grep`, `find`, and `ls` through a compact output renderer.
4. Preserve tail truncation: show `N earlier lines…` before visible output rows.
5. Prefix visible output rows with a muted `│` gutter.
6. Highlight output text as secondary log text, not as syntax-highlighted code.
7. Treat compact output as inert transcript text, not markdown.
   - Do not insert raw output lines where markdown can reinterpret them as
     headings, lists, blockquotes, tables, or fences.
   - Escape markdown-sensitive leading text after the gutter, including `#`,
     `>`, `-`, `*`, `+`, numbered lists like `1.`, and fence markers like
     ```` ``` ````.
   - Preserve the user's visible output as closely as possible; escaping should
     prevent rendering side effects, not rewrite the content semantically.
8. Show a count line for result-list tools when cheap to infer:
   - `grep`: `N matches`
   - `find`: `N paths`
   - `ls`: `N entries`
9. Show command exit status only when pi provides reliable status metadata.
   Until then, v1 should not invent `✓ exited 0` or `✗ exited N`.

## Implementation Plan

1. Add a compact renderer in `lua/sherpa/ui.lua`.
   - Suggested API: `append_compact_tool_output(text, opts, lane, insert_opts)`.
   - `opts.kind`: `bash`, `grep`, `find`, or `ls`.
   - `opts.count_label`: optional plural label such as `matches`.
   - `opts.status`: optional command status for future bash metadata.
   - Reuse the existing tail limit and sentinel stripping behavior where possible.
   - Add a small markdown-neutralization helper for compact output row bodies.
     The helper should run before lines are inserted into the markdown log
     buffer.

2. Add highlight groups in `lua/sherpa/ui.lua`.
   - `SherpaLogToolOutputGutter`: muted `│`.
   - `SherpaLogToolOutputMeta`: muted count/truncation/status lines.
   - `SherpaLogToolOutputError`: red status line for failed commands.
   - Keep `SherpaLogToolOutput` for row body text.

3. Route non-code tools in `lua/sherpa/rpc.lua`.
   - Keep `read` / `write` calling `append_tool_output(text, lang, ...)`.
   - Route `bash`, `grep`, `find`, and `ls` to the compact renderer.
   - Leave result parsing conservative: line-count-based counts are fine for v1.

4. Preserve insertion behavior.
   - Continue using `ui.pop_tool_insert_row` so output stays attached to the
     matching tool header even when tools interleave.
   - Avoid adding another `•` block for compact output.

5. Add tmux tests in `tests/test_tmux_log_rendering.py`.
   - `read` still renders fenced output.
   - `bash` / `grep` / `find` / `ls` output has no markdown fences.
   - Compact output rows include the `│` gutter.
   - Truncation marker appears above compact rows.
   - Output extmarks include gutter/body/meta highlight groups.
   - Markdown-looking output remains literal. Include cases such as
     `# heading`, `- item`, `> quote`, `1. item`, and ```` ``` ````.

## Open Questions

1. Confirm real pi bash result metadata for exit code and stderr.
   - If metadata is reliable, render explicit success/failure status.
   - If only text is available, v1 should show text rows only.

2. Decide whether `grep` paths should get path-specific extmarks inside output
   rows. This is useful, but can wait until the compact renderer exists.

3. Decide whether compact output should have a different tail limit from code
   blocks. A smaller default, such as 10 lines, may scan better.

## Estimated Size

Expected implementation size: roughly 160-310 LOC.

- `lua/sherpa/ui.lua`: 80-140 LOC
- `lua/sherpa/rpc.lua`: 30-70 LOC
- `tests/test_tmux_log_rendering.py`: 50-100 LOC
