"""Tests for rich log rendering of tool calls: fenced read/write output,
compact bash/grep/ls/find rows, inline diff rows after edit, and
accent-colored file paths in tool headers.

These exercise the UI surface end-to-end through a real Neovim session
with the fake pi backend. The fake already emits the event shapes these
paths read (result.content[].text for tool output, result.details.diff
for edit), so no fake_pi changes are needed.
"""
import json
import time
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxLogRenderingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_edit_tool_emits_inline_diff_rows(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: any(line.lstrip().startswith("+") for line in h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                self.assertIn("• Edited", log)
                self.assertRegex(log, r"• Edited .+\(\+1 -1\)")
                self.assertNotIn("• Diff", log)
                self.assertNotIn("```diff", log)
                self.assertNotIn("└ edit ", log)
                self.assertIn("-2 │   return <main>Hello from fixture app</main>", log)
                self.assertIn("+2 │   return <main>Loading fixture app</main>", log)
                # Diff lines are indented with 2 spaces under the edit line.
                diff_lines = [
                    line for line in h.log_lines()
                    if line.lstrip().startswith("+") or line.lstrip().startswith("-")
                ]
                self.assertTrue(
                    len(diff_lines) >= 1,
                    f"expected at least one +/- diff line, got log:\n{log}",
                )

    def test_inline_diff_rows_have_line_highlighting_extmarks(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: any(line.lstrip().startswith("+") for line in h.log_lines()),
                    timeout=5.0,
                )

                has_diff_hl = h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('sherpa://log'); "
                    "  if buf <= 0 then return false end; "
                    "  local ns = vim.api.nvim_create_namespace('sherpa-log'); "
                    "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true}); "
                    "  local seen = {}; "
                    "  for _, m in ipairs(marks) do "
                    "    local hl = m[4] and m[4].hl_group or ''; "
                    "    if type(hl) == 'table' then "
                    "      for _, item in ipairs(hl) do seen[item] = true end "
                    "    else "
                    "      seen[hl] = true "
                    "    end "
                    "  end; "
                    "  return seen.SherpaLogDiffAdd and seen.SherpaLogDiffRemove "
                    "    and seen.SherpaLogDiffLineNumber and seen.SherpaLogDiffGutter "
                    "end)()"
                )
                self.assertTrue(has_diff_hl, "expected diff line/gutter highlighting extmarks in the log")

                has_syntax_hl = h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('sherpa://log'); "
                    "  if buf <= 0 then return false end; "
                    "  local ns = vim.api.nvim_create_namespace('sherpa-log'); "
                    "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true}); "
                    "  for _, m in ipairs(marks) do "
                    "    local hl = m[4] and m[4].hl_group or ''; "
                    "    if type(hl) == 'string' and vim.startswith(hl, '@') then return true end "
                    "  end; "
                    "  return false "
                    "end)()"
                )
                self.assertTrue(has_syntax_hl, "expected treesitter capture extmarks on diff content")

    def test_read_tool_renders_fenced_output(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "• Explored" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: "Finished a broader work pass" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                self.assertIn("export function App", log,
                    f"expected read content in log; got:\n{log}")
                self.assertIn("```tsx", log,
                    f"expected tsx-tagged fence open; got:\n{log}")
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

    def test_compact_tool_output_has_gutter_counts_and_no_fence(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://log')") == "1",
                    timeout=3.0,
                )
                output = "lua/sherpa/ui.lua:1295:function M.append_tool_output()\n" \
                         "lua/sherpa/rpc.lua:678:ui.append_tool_output(...)"
                h.lua(
                    "(function() "
                    "  require('sherpa.ui').append_compact_tool_output("
                    + json.dumps(output)
                    + ", { kind = 'grep', count_singular = 'match', count_plural = 'matches' }, 'main'); "
                    "  return true "
                    "end)()"
                )
                log = "\n".join(h.log_lines())
                self.assertIn("2 matches", log)
                self.assertIn("│ lua/sherpa/ui.lua", log)
                self.assertNotIn("```", log, f"compact output should not use markdown fences; got:\n{log}")

                has_compact_hl = h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('sherpa://log'); "
                    "  local ns = vim.api.nvim_create_namespace('sherpa-log'); "
                    "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }); "
                    "  local seen = {}; "
                    "  for _, m in ipairs(marks) do "
                    "    local hl = m[4] and m[4].hl_group or ''; "
                    "    seen[hl] = true "
                    "  end; "
                    "  return seen.SherpaLogToolOutputGutter and seen.SherpaLogToolOutputMeta "
                    "    and seen.SherpaLogToolOutput "
                    "end)()"
                )
                self.assertTrue(has_compact_hl, "expected compact output gutter/body/meta extmarks")

    def test_rpc_routes_grep_output_to_compact_renderer(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat show compact tool output")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(lambda: "2 matches" in "\n".join(h.log_lines()), timeout=5.0)
                log = "\n".join(h.log_lines())
                self.assertIn("• Explored", log)
                self.assertIn('└ grep "fixture" in src', log)
                self.assertIn("2 matches", log)
                self.assertIn("│ # heading-like output", log)
                self.assertIn("│ src/App.tsx:1:export function App() {", log)
                self.assertNotIn("```", log, f"grep output should not use markdown fences; got:\n{log}")

    def test_rpc_tool_headers_include_search_args(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat show tool argument headers")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "Finished tool argument header pass" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log = "\n".join(h.log_lines())
                self.assertIn('└ grep "fixture" in src (glob *.tsx, limit 5)', log)
                self.assertIn("└ find *.lua in lua/sherpa (limit 3)", log)
                self.assertIn("└ ls lua/sherpa (limit 2)", log)

    def test_compact_tool_output_truncates_above_rows(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://log')") == "1",
                    timeout=3.0,
                )
                output = "\n".join(f"entry {i}" for i in range(1, 21))
                h.lua(
                    "(function() "
                    "  require('sherpa.ui').append_compact_tool_output("
                    + json.dumps(output)
                    + ", { kind = 'ls', count_singular = 'entry', count_plural = 'entries' }, 'main'); "
                    "  return true "
                    "end)()"
                )
                log = "\n".join(h.log_lines())
                self.assertIn("20 entries", log)
                self.assertIn("5 earlier lines…", log)
                self.assertNotIn("entry 1\n", log)
                self.assertIn("│ entry 6", log)
                self.assertIn("│ entry 20", log)
                self.assertLess(log.find("5 earlier lines…"), log.find("│ entry 6"))

    def test_compact_tool_output_preserves_markdown_leaders(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://log')") == "1",
                    timeout=3.0,
                )
                output = "# heading\n- item\n> quote\n1. ordered\n```md\n| table |"
                h.lua(
                    "(function() "
                    "  require('sherpa.ui').append_compact_tool_output("
                    + json.dumps(output)
                    + ", { kind = 'bash' }, 'main'); "
                    "  return true "
                    "end)()"
                )
                log = "\n".join(h.log_lines())
                self.assertIn("│ # heading", log)
                self.assertIn("│ - item", log)
                self.assertIn("│ > quote", log)
                self.assertIn("│ 1. ordered", log)
                self.assertIn("│ ```md", log)
                self.assertIn("│ | table |", log)
                self.assertNotIn("\\# heading", log)
                self.assertNotIn("\\- item", log)
                self.assertNotRegex(log, r"(?m)^```md")

    def test_tool_header_path_has_extmark(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat update the fixture app")
                h.wait_until(lambda: h.current_state()["buf"] == "sherpa://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "• Explored" in "\n".join(h.log_lines()),
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
                self.assertTrue(has_path_hl, "expected SherpaLogPath extmark on a tool header")

    def test_log_pin_shows_last_user_message_preview(self) -> None:
        pin_state = (
            "(function() "
            "  local buf = vim.fn.bufnr('sherpa://log'); "
            "  if buf <= 0 then return {height = 0, lines = {}} end; "
            "  local win = vim.fn.win_findbuf(buf)[1]; "
            "  if not win then return {height = 0, lines = {}} end; "
            "  local pin = vim.w[win].sherpa_log_pin_win; "
            "  if not pin or not vim.api.nvim_win_is_valid(pin) then return {height = 0, lines = {}} end; "
            "  local pbuf = vim.api.nvim_win_get_buf(pin); "
            "  return {height = vim.api.nvim_win_get_height(pin), lines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)} "
            "end)()"
        )

        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                message = " ".join(["sticky"] * 60)
                h.lua(
                    "(function() "
                    "  local state = require('sherpa.state'); "
                    "  local ui = require('sherpa.ui'); "
                    "  state.ensure_session('main', vim.fn.getcwd()); "
                    "  ui.open_log({}, 'main'); "
                    "  local log_win = vim.fn.win_findbuf(vim.fn.bufnr('sherpa://log'))[1]; "
                    "  vim.api.nvim_win_set_width(log_win, 28); "
                    "  ui.append_block('user', " + json.dumps(message) + ", 'main'); "
                    "  for i = 1, 80 do ui.append({'assistant ' .. i}, 'main') end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.json_expr(f"luaeval({json.dumps(pin_state)})")["height"] > 0, timeout=3.0)
                state = h.json_expr(f"luaeval({json.dumps(pin_state)})")
                self.assertLessEqual(state["height"], 5)
                self.assertEqual(state["height"], len(state["lines"]))
                self.assertEqual(state["height"], 5)
                self.assertTrue(state["lines"][0].startswith("› sticky"), state)
                self.assertTrue(state["lines"][-1].endswith("…"), state)

    def test_log_follow_pauses_when_scrolled_up_and_resumes_at_bottom(self) -> None:
        log_at_bottom = (
            "(function() "
            "  local buf = vim.fn.bufnr('sherpa://log'); "
            "  if buf <= 0 then return false end; "
            "  local win = vim.fn.win_findbuf(buf)[1]; "
            "  if not win then return false end; "
            "  return vim.api.nvim_win_call(win, function() "
            "    return vim.fn.line('w$') >= vim.fn.line('$') "
            "  end) "
            "end)()"
        )
        log_following = (
            "(function() "
            "  local buf = vim.fn.bufnr('sherpa://log'); "
            "  if buf <= 0 then return false end; "
            "  local win = vim.fn.win_findbuf(buf)[1]; "
            "  if not win then return false end; "
            "  return vim.w[win].sherpa_log_follow == true "
            "end)()"
        )

        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  local state = require('sherpa.state'); "
                    "  local ui = require('sherpa.ui'); "
                    "  state.ensure_session('main', vim.fn.getcwd()); "
                    "  ui.open_log({}, 'main'); "
                    "  for i = 1, 80 do ui.append({'initial ' .. i}, 'main') end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.lua_bool(log_at_bottom), timeout=3.0)

                h.send("g", "g", pause=0.2)
                h.wait_until(lambda: not h.lua_bool(log_at_bottom), timeout=3.0)
                h.wait_until(lambda: not h.lua_bool(log_following), timeout=3.0)

                h.lua("(function() require('sherpa.ui').append({'after paused'}, 'main'); return true end)()")
                time.sleep(0.2)  # allow the debounced follow-scroll timer to fire
                self.assertIn("after paused", "\n".join(h.log_lines()))
                self.assertFalse(h.lua_bool(log_at_bottom), "paused log window should not jump to the tail")

                h.send("G", pause=0.2)
                h.wait_until(lambda: h.lua_bool(log_at_bottom), timeout=3.0)
                h.wait_until(lambda: h.lua_bool(log_following), timeout=3.0)

                h.lua("(function() require('sherpa.ui').append({'after relocked'}, 'main'); return true end)()")
                h.wait_until(lambda: h.lua_bool(log_at_bottom), timeout=3.0)
                self.assertIn("after relocked", "\n".join(h.log_lines()))


if __name__ == "__main__":
    unittest.main()
