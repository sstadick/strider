"""Tests for rich log rendering of tool calls: [tool-output] blocks
after bash/read/grep/ls/find/write, [diff] blocks after edit, and
accent-colored file paths in [tool] headers.

These exercise the UI surface end-to-end through a real Neovim session
with the fake pi backend. The fake already emits the event shapes these
paths read (result.content[].text for tool output, result.details.diff
for edit), so no fake_pi changes are needed.
"""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxLogRenderingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_edit_tool_emits_diff_block(self) -> None:
        # `:SherpaChat update the fixture app` drives fake_pi through
        # prompt_response which emits read + edit tool events. The edit
        # carries result.details.diff, which Sherpa should render as a
        # [diff] block with at least one +/- line.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "[diff]" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                self.assertIn("[diff]", log)
                # Pi's diff format uses "+ NUM content" / "- NUM content".
                # fake_pi emits `+ <line> edited` as the diff stub, so we
                # should see at least one line starting with `+`.
                diff_lines = [
                    line for line in h.log_lines()
                    if line.startswith("+") or line.startswith("-")
                ]
                self.assertTrue(
                    len(diff_lines) >= 1,
                    f"expected at least one +/- diff line, got log:\n{log}",
                )

    def test_read_tool_renders_fenced_output(self) -> None:
        # prompt_response in fake_pi emits a `read` on src/App.tsx
        # before the edit. The content lands in the log wrapped in a
        # tsx-tagged fence so treesitter + render-markdown highlight it.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "[tool] read" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: "[assistant]" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                # Body content is present.
                self.assertIn("export function App", log,
                    f"expected read content in log; got:\n{log}")
                # Fence open + close are both present.
                self.assertIn("```tsx", log,
                    f"expected tsx-tagged fence open; got:\n{log}")
                # There should be at least two ``` in total (open + close).
                self.assertGreaterEqual(log.count("```"), 2,
                    f"expected open+close fence; got:\n{log}")

    def test_earlier_lines_marker_shown_above_fence_when_truncated(self) -> None:
        # Direct ui.append_tool_output test: feed a 20-line file so the
        # last-15 rendering leaves 5 hidden. Marker should say `5 earlier
        # lines…` and should appear BEFORE the fence (never inside it —
        # that would break code syntax).
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                # Open chat so the log buffer exists.
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://log')") == "1",
                    timeout=3.0,
                )
                # Push a 20-line synthetic "file" through append_tool_output.
                lines_literal = "\\n".join(f"line {i}" for i in range(1, 21))
                h.lua(
                    "(function() "
                    "  require('sherpa.ui').append_tool_output('"
                    + lines_literal + "', 'lua'); return true end)()"
                )
                log = "\n".join(h.log_lines())
                self.assertIn("5 earlier lines…", log,
                    f"expected '5 earlier lines…' marker; got:\n{log}")
                self.assertIn("```lua", log,
                    f"expected fence open; got:\n{log}")
                # First 5 lines should NOT appear (they were truncated).
                self.assertNotIn("line 1\n", log)
                self.assertNotIn("line 5\n", log)
                # Last lines SHOULD appear.
                self.assertIn("line 20", log)
                # Marker must land ABOVE the fence, not inside it.
                marker_pos = log.find("5 earlier lines…")
                fence_pos = log.find("```lua")
                self.assertGreater(fence_pos, marker_pos,
                    "marker should be above the fence open")

    def test_pi_trailing_sentinel_is_stripped_from_fenced_output(self) -> None:
        # Pi's read tool appends a meta line like
        #   `[24 more lines in file. Use offset=31 to continue.]`
        # when the file is longer than what it read. That line is prose,
        # not code, and landing it inside the fence makes the language
        # parser barf. We strip it before fencing.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://log')") == "1",
                    timeout=3.0,
                )
                # Simulate pi's shape: a few lines of code + the trailing
                # sentinel. We expect the sentinel to be dropped.
                synthetic = (
                    "use serde;\\nuse serde_json;\\n"
                    "[24 more lines in file. Use offset=31 to continue.]"
                )
                h.lua(
                    "(function() "
                    "  require('sherpa.ui').append_tool_output('"
                    + synthetic + "', 'rust'); return true end)()"
                )
                log = "\n".join(h.log_lines())
                self.assertIn("```rust", log)
                self.assertIn("use serde;", log)
                self.assertNotIn("more lines in file", log,
                    f"pi sentinel should be stripped; got:\n{log}")

    def test_tool_header_path_has_extmark(self) -> None:
        # The [tool] <name> <path> header line should carry a
        # SherpaLogPath extmark covering the path substring. We query
        # extmarks directly via nvim_buf_get_extmarks since log_lines()
        # strips styling. Any extmark with hl_group SherpaLogPath on the
        # log buffer is evidence path-highlighting is wired.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "[tool]" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )

                has_path_hl = h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('sherpa://log'); "
                    "  if buf <= 0 then return false end; "
                    "  local ns = vim.api.nvim_create_namespace('sherpa-log'); "
                    "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true}); "
                    "  for _, m in ipairs(marks) do "
                    "    if m[4] and m[4].hl_group == 'SherpaLogPath' then return true end "
                    "  end; "
                    "  return false "
                    "end)()"
                )
                self.assertTrue(has_path_hl, "expected SherpaLogPath extmark on a [tool] header")


if __name__ == "__main__":
    unittest.main()
