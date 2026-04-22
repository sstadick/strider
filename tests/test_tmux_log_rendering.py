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

    def test_read_tool_renders_output_inline(self) -> None:
        # Same flow as above — prompt_response in fake_pi emits a `read`
        # tool before the edit. The read result carries content text,
        # which Sherpa renders inline (no [tool-output] header; plain
        # lines between the [tool] header and the next block). We assert
        # that content from the fake fixture (`src/App.tsx`) lands in
        # the log after the [tool] read header.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(
                    lambda: "[tool] read" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                # Wait for the turn to settle so the full output is in.
                h.wait_until(
                    lambda: "[assistant]" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                # fake_pi's src/App.tsx fixture contains `export function App`.
                # The inlined tool output should carry that substring.
                self.assertIn("export function App", log,
                    f"expected read content inlined in log; got:\n{log}")
                # Confirm we did NOT revert to a [tool-output] block
                # header — the user asked for no header.
                self.assertNotIn("[tool-output]", log)

    def test_tool_header_path_has_extmark(self) -> None:
        # The [tool] <name> <path> header line should carry a
        # SherpaLogPath extmark covering the path substring. We query
        # extmarks directly via nvim_buf_get_extmarks since log_lines()
        # strips styling. Any extmark with hl_group SherpaLogPath on the
        # log buffer is evidence path-highlighting is wired.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
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
