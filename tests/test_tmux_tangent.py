"""Tests for :StriderQ.

Q now uses the floating prompt editor for input, dispatches a one-shot
background tangent, and does not pop open the chat surfaces.
"""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


def _winbar_for_buffer(h, name: str) -> str:
    return h.lua(
        "(function() "
        f"  local buf = vim.fn.bufnr('{name}'); "
        "  if buf <= 0 then return '' end; "
        "  for _, win in ipairs(vim.fn.win_findbuf(buf)) do "
        "    if vim.api.nvim_win_is_valid(win) then "
        "      local value = vim.wo[win].winbar or ''; "
        "      local ok, evaluated = pcall(vim.api.nvim_eval_statusline, value, { winid = win, maxwidth = 10000 }); "
        "      if ok and evaluated and evaluated.str then return evaluated.str end; "
        "      return value "
        "    end "
        "  end; "
        "  return '' "
        "end)()"
    )


class TmuxTangentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_q_no_args_opens_popup(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)

    def test_q_with_prompt_prefills_popup_and_stays_out_of_chat(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("what does this flag do", "\n".join(h.buffer_lines("strider://prompt")))

                h.submit_popup()
                h.wait_until(
                    lambda: "what does this flag do" in "\n".join(h.flow_log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: not h.lua_bool("require('strider.ui').chat_is_visible()"),
                    timeout=3.0,
                )

    def test_q_with_range_submits_without_opening_chat(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("1,2StriderQ why is this bootstrapped here?")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("why is this bootstrapped here?", "\n".join(h.buffer_lines("strider://prompt")))

                h.submit_popup()
                h.wait_until(
                    lambda: "why is this bootstrapped here?" in "\n".join(h.flow_log_lines()),
                    timeout=5.0,
                )
                self.assertFalse(h.lua_bool("require('strider.ui').chat_is_visible()"))

    def test_q_answer_surface_opens_without_focus_and_filters_transcript(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("StriderQ what does this flag do")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                h.submit_popup()

                h.wait_until(
                    lambda: "strider://StriderQAnswer" in h.json_expr(
                        "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                    ),
                    timeout=3.0,
                )
                self.assertNotEqual("strider://StriderQAnswer", h.expr("bufname('%')"))

                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )
                folded = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("what does this flag do", folded)
                self.assertIn("Answer ready", folded)
                self.assertNotIn("Finished a broader work pass", folded)

                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  vim.api.nvim_set_current_win(win); "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  return true "
                    "end)()"
                )
                answer = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("Finished a broader work pass", answer)
                self.assertNotIn("Checking the relevant files first", answer)
                self.assertNotIn("Explored", answer)

                flow_log = "\n".join(h.flow_log_lines())
                self.assertIn("Checking the relevant files first", flow_log)
                self.assertIn("Finished a broader work pass", flow_log)

    def test_q_answer_winbar_uses_flow_stop_command(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('flow', vim.fn.getcwd()); "
                    "  ui.open_q_answer('slow question', 'flow'); "
                    "  ui.start_activity('Strider Q running...', 'q', 'q', 'flow'); "
                    "  return true "
                    "end)()"
                )
                h.wait_until(
                    lambda: "strider://StriderQAnswer" in h.json_expr(
                        "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                    ),
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Working (" in _winbar_for_buffer(h, "strider://StriderQAnswer"),
                    timeout=3.0,
                )
                winbar = _winbar_for_buffer(h, "strider://StriderQAnswer")
                self.assertIn(":StriderStopFlow to interrupt", winbar)

    def test_q_answer_surface_starts_compact_bottom_right_and_expands_on_focus(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                initial_height, initial_row, initial_col = map(int, h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('flow', vim.fn.getcwd()); "
                    "  ui.open_q_answer('where does this render?', 'flow'); "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  local cfg = vim.api.nvim_win_get_config(win); "
                    "  local row = type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row; "
                    "  local col = type(cfg.col) == 'table' and (cfg.col[false] or cfg.col[1]) or cfg.col; "
                    "  return string.format('%d,%d,%d', vim.api.nvim_win_get_height(win), row, col); "
                    "end)()"
                ).split(","))
                self.assertLessEqual(initial_height, 3)
                self.assertGreater(initial_col, 0)

                folded_height, folded_row = map(int, h.lua(
                    "(function() "
                    "  require('strider.ui').update_q_answer('Here is the focused answer text.', 'flow'); "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  local cfg = vim.api.nvim_win_get_config(win); "
                    "  local row = type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row; "
                    "  return string.format('%d,%d', vim.api.nvim_win_get_height(win), row); "
                    "end)()"
                ).split(","))
                self.assertEqual(folded_height, initial_height)
                self.assertEqual(folded_row, initial_row)

                expanded_height, expanded_row, ui_height = map(int, h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  vim.api.nvim_set_current_win(win); "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  local cfg = vim.api.nvim_win_get_config(win); "
                    "  local row = type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row; "
                    "  local ui_info = vim.api.nvim_list_uis()[1]; "
                    "  return string.format('%d,%d,%d', vim.api.nvim_win_get_height(win), row, ui_info.height); "
                    "end)()"
                ).split(","))
                self.assertGreater(expanded_height, folded_height)
                self.assertGreaterEqual(expanded_height, ui_height - 4)
                self.assertGreater(folded_row, expanded_row)

    def test_q_completion_clears_pending_request(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() == nil"),
                    timeout=5.0,
                )

    def test_q_completion_echoes_green_dot_even_when_flow_log_visible(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderLogFlow")
                h.wait_until(
                    lambda: "strider://StriderLogFlow" in h.json_expr('map(getwininfo(), {_, v -> bufname(v.bufnr)})'),
                    timeout=3.0,
                )

                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: "StriderQ answer is ready" in h.expr("execute('messages')"),
                    timeout=5.0,
                )

    def test_patch_card_opens_without_focus_and_shows_patch_summary(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/App.tsx")
                h.ex("1,3StriderPatch change the greeting literal")
                h.submit_popup()

                card_names_expr = (
                    "filter(map(getwininfo(), {_, v -> bufname(v.bufnr)}), "
                    "{_, n -> stridx(n, 'strider://flow-card/patch/') == 0})"
                )
                h.wait_until(lambda: len(h.json_expr(card_names_expr)) == 1, timeout=3.0)
                card_name = h.json_expr(card_names_expr)[0]
                self.assertNotEqual(card_name, h.expr("bufname('%')"))

                h.wait_until(lambda: "Patch complete" in "\n".join(h.buffer_lines(card_name)), timeout=5.0)
                folded = "\n".join(h.buffer_lines(card_name))
                self.assertIn("change the greeting literal", folded)
                self.assertIn("Patch complete", folded)
                self.assertNotIn("Hello from patched fixture app", folded)

                h.lua(
                    "(function() "
                    f"  local buf = vim.fn.bufnr({card_name!r}); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  vim.api.nvim_set_current_win(win); "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  return true "
                    "end)()"
                )
                expanded = "\n".join(h.buffer_lines(card_name))
                self.assertIn("Target: src/App.tsx:1-3", expanded)
                self.assertIn("Files touched", expanded)
                self.assertIn("src/App.tsx", expanded)
                self.assertIn("```diff", expanded)
                self.assertIn("Hello from patched fixture app", expanded)
                self.assertIn("Applied the requested local patch.", expanded)

                flow_log = "\n".join(h.flow_log_lines())
                self.assertIn("Applied the requested local patch.", flow_log)
                self.assertIn("Hello from patched fixture app", flow_log)

    def test_flow_lane_rejects_new_request_while_busy(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  state.ensure_session('flow', vim.fn.getcwd()); "
                    "  state.set_pending_request('q', {}, 'flow'); "
                    "  return true "
                    "end)()"
                )
                h.ex("StriderSearch where is the main entrypoint?")

                pending = h.lua(
                    "(function() "
                    "  local pending = require('strider.state').peek_pending_request('flow'); "
                    "  return pending and pending.operation or '' "
                    "end)()"
                )
                job_id = h.lua(
                    "(function() "
                    "  local session = require('strider.state').get_session('flow'); "
                    "  return session and tostring(session.job_id or '') or '' "
                    "end)()"
                )
                self.assertEqual("q", pending)
                self.assertEqual("", job_id)


if __name__ == "__main__":
    unittest.main()
