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
                    lambda: "what does this flag do" in "\n".join(h.q_log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: not h.lua_bool("require('strider.ui').chat_is_visible()"),
                    timeout=3.0,
                )

    def test_q_default_model_is_fast(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ quick model check")
                h.submit_popup()
                h.wait_until(lambda: h.lua_bool("require('strider.state').get_session('q') ~= nil"), timeout=5.0)

                command = h.lua("(function() return table.concat(require('strider.rpc').command_list('q'), ' ') end)()")
                self.assertIn("--model codex-spark", command)
                self.assertEqual("fast", h.lua("require('strider.state').get_session('q').model_label"))

    def test_q_deep_flag_uses_chat_model(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  require('strider').setup({ lane_models = { chat = { default = { model = 'chat-deep', reasoning = 'high' } } } }); "
                    "  return true "
                    "end)()"
                )
                h.ex("StriderQ --deep explain with chat model")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("explain with chat model", "\n".join(h.buffer_lines("strider://prompt")))
                self.assertNotIn("--deep", "\n".join(h.buffer_lines("strider://prompt")))
                h.submit_popup()
                h.wait_until(lambda: h.lua_bool("require('strider.state').get_session('q') ~= nil"), timeout=5.0)

                command = h.lua("(function() return table.concat(require('strider.rpc').command_list('q'), ' ') end)()")
                self.assertIn("--model chat-deep", command)
                self.assertIn("--thinking high", command)
                self.assertEqual("deep", h.lua("require('strider.state').get_session('q').model_label"))

    def test_q_with_range_submits_without_opening_chat(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("1,2StriderQ why is this bootstrapped here?")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("why is this bootstrapped here?", "\n".join(h.buffer_lines("strider://prompt")))

                h.submit_popup()
                h.wait_until(
                    lambda: "why is this bootstrapped here?" in "\n".join(h.q_log_lines()),
                    timeout=5.0,
                )
                self.assertFalse(h.lua_bool("require('strider.ui').chat_is_visible()"))

    def test_q_answer_waits_in_picker_and_opens_as_split(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("StriderQ what does this flag do")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                h.submit_popup()

                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )
                windows = h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})")
                self.assertNotIn("strider://StriderQAnswer", windows)

                folded = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("what does this flag do", folded)
                self.assertIn("Answer ready", folded)
                self.assertNotIn("Finished a broader work pass", folded)

                h.lua(
                    "(function() "
                    "  local picker = require('strider.picker'); "
                    "  local original_select = picker.select; "
                    "  picker.select = function(_, items, on_select) on_select(items[1]); return true end; "
                    "  local ok, err = pcall(function() return require('strider').q_cards() end); "
                    "  picker.select = original_select; "
                    "  if not ok then error(err) end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                is_regular = h.lua_bool(
                    "(function() return vim.api.nvim_win_get_config(0).relative == '' end)()"
                )
                self.assertTrue(is_regular)

                answer = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("Finished a broader work pass", answer)
                self.assertNotIn("Checking the relevant files first", answer)
                self.assertNotIn("Explored", answer)

                q_log = "\n".join(h.q_log_lines())
                self.assertIn("Checking the relevant files first", q_log)
                self.assertIn("Finished a broader work pass", q_log)

    def test_q_answer_split_followup_reuses_worker_and_record(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ first question")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.lua("(function() require('strider.ui').open_q_answer_split(nil, 'q'); return true end)()")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                before = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui.flow_cards'); "
                    "  local session = state.get_session('q'); "
                    "  local card = ui.get_card(session.q_answer_card_id, 'q'); "
                    "  return table.concat({ card.id, card.worker_lane or '', tostring(#card.turns), card.model_label or '' }, ',') "
                    "end)()"
                ).split(",")

                h.send("a", pause=0.3)
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertNotIn("strider://StriderQCompose", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))
                h.submit_popup("what about follow ups?")
                h.wait_until(
                    lambda: "what about follow ups?" in "\n".join(h.q_log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: h.lua_bool(
                        "(function() "
                        "  local state = require('strider.state'); "
                        "  local ui = require('strider.ui.flow_cards'); "
                        "  local session = state.get_session('q'); "
                        "  local card = ui.get_card(session.q_answer_card_id, 'q'); "
                        "  return #card.turns == 2 and card.turns[2].status ~= 'running' "
                        "end)()"
                    ),
                    timeout=5.0,
                )

                after = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui.flow_cards'); "
                    "  local session = state.get_session('q'); "
                    "  local card = ui.get_card(session.q_answer_card_id, 'q'); "
                    "  return table.concat({ card.id, card.worker_lane or '', tostring(#card.turns), card.model_label or '' }, ',') "
                    "end)()"
                ).split(",")
                self.assertEqual(before[0], after[0])
                self.assertEqual(before[1], after[1])
                self.assertEqual("2", after[2])
                self.assertEqual("fast", after[3])
                self.assertFalse(h.lua_bool("require('strider.state').get_session('q-2') ~= nil"))
                self.assertEqual("strider://StriderQAnswer", h.expr("bufname('%')"))
                self.assertTrue(h.lua_bool("vim.api.nvim_win_get_config(0).relative == ''"))
                answer = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("› first question", answer)
                self.assertIn("↳ what about follow ups?", answer)
                self.assertTrue(h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local ns = vim.api.nvim_create_namespace('strider-flow-cards'); "
                    "  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do "
                    "    if mark[4] and mark[4].hl_group == 'StriderLogFollowup' then return true end "
                    "  end; "
                    "  return false "
                    "end)()"
                ))
                self.assertIn("↳ what about follow ups?", "\n".join(h.q_log_lines()))
                self.assertNotIn("strider://StriderQCompose", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))

    def test_bare_q_after_answer_opens_new_prompt_not_card_toggle(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.ex("StriderQ")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://prompt", timeout=3.0)
                windows = h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})")
                self.assertNotIn("strider://StriderQCompose", windows)
                self.assertNotIn("strider://StriderQAnswer", windows)

    def test_q_answer_split_quit_closes_without_dismissal(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.lua("(function() require('strider.ui').open_q_answer_split(nil, 'q'); return true end)()")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                h.send("q", pause=0.3)
                windows = h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})")
                self.assertNotIn("strider://StriderQAnswer", windows)
                self.assertEqual(
                    "1",
                    h.lua("(function() return tostring(#require('strider.ui.card_picker').items({ kind = 'q' })) end)()"),
                )

    def test_q_answer_split_d_dismisses_card(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ dismiss the answer card")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.lua("(function() require('strider.ui').open_q_answer_split(nil, 'q'); return true end)()")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                h.send("d", pause=0.3)
                h.wait_until(
                    lambda: h.lua(
                        "(function() return tostring(#require('strider.ui.card_picker').items({ kind = 'q' })) end)()"
                    ) == "0",
                    timeout=3.0,
                )
                self.assertNotIn("strider://StriderQAnswer", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))

    def test_q_answer_winbar_uses_flow_stop_command(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  ui.open_q_answer('slow question', 'q'); "
                    "  ui.start_activity('StriderQ running...', 'q', 'q', 'q'); "
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
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  ui.open_q_answer('where does this render?', 'q'); "
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
                    "  require('strider.ui').update_q_answer('Here is the focused answer text.', 'q'); "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  local cfg = vim.api.nvim_win_get_config(win); "
                    "  local row = type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row; "
                    "  return string.format('%d,%d', vim.api.nvim_win_get_height(win), row); "
                    "end)()"
                ).split(","))
                self.assertEqual(folded_height, initial_height)
                self.assertEqual(folded_row, initial_row)

                expanded_height, expanded_row, compose_height, compose_row, ui_height = map(int, h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  vim.api.nvim_set_current_win(win); "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  local cfg = vim.api.nvim_win_get_config(win); "
                    "  local row = type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row; "
                    "  local cbuf = vim.fn.bufnr('strider://StriderQCompose'); "
                    "  local cwin = vim.fn.win_findbuf(cbuf)[1]; "
                    "  local ccfg = vim.api.nvim_win_get_config(cwin); "
                    "  local crow = type(ccfg.row) == 'table' and (ccfg.row[false] or ccfg.row[1]) or ccfg.row; "
                    "  local ui_info = vim.api.nvim_list_uis()[1]; "
                    "  return string.format('%d,%d,%d,%d,%d', vim.api.nvim_win_get_height(win), row, vim.api.nvim_win_get_height(cwin), crow, ui_info.height); "
                    "end)()"
                ).split(","))
                self.assertGreater(expanded_height, folded_height)
                self.assertGreater(compose_height, 0)
                self.assertGreater(compose_row, expanded_row)
                self.assertGreaterEqual(expanded_height + compose_height, ui_height - 8)
                self.assertGreater(folded_row, expanded_row)

                sticky_height = int(h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  for _, candidate in ipairs(vim.api.nvim_list_wins()) do "
                    "    if candidate ~= win and vim.api.nvim_win_get_config(candidate).relative == '' then "
                    "      vim.api.nvim_set_current_win(candidate); break "
                    "    end "
                    "  end; "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  return tostring(vim.api.nvim_win_get_height(win)); "
                    "end)()"
                ))
                self.assertEqual(expanded_height, sticky_height)

                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1]); "
                    "  return true "
                    "end)()"
                )
                h.send("q", pause=0.3)
                folded_after_explicit_action = int(h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  return tostring(vim.api.nvim_win_get_height(win)); "
                    "end)()"
                ))
                self.assertEqual(folded_height, folded_after_explicit_action)
                self.assertNotIn("strider://StriderQCompose", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))

    def test_q_completion_clears_pending_request(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request('q') == nil"),
                    timeout=5.0,
                )

    def test_q_completion_echoes_green_dot_even_when_q_log_visible(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderLogQ")
                h.wait_until(
                    lambda: "strider://StriderLogQ" in h.json_expr('map(getwininfo(), {_, v -> bufname(v.bufnr)})'),
                    timeout=3.0,
                )

                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: "StriderQ answer is ready" in h.expr("execute('messages')"),
                    timeout=5.0,
                )



if __name__ == "__main__":
    unittest.main()
