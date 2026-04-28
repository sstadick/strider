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

                q_log = "\n".join(h.q_log_lines())
                self.assertIn("Checking the relevant files first", q_log)
                self.assertIn("Finished a broader work pass", q_log)

    def test_q_card_toggle_and_followup_compose(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.ex("StriderQ")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQCompose", timeout=3.0)
                self.assertIn("strider://StriderQCompose", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))

                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  local session = state.get_session('q'); "
                    "  local card = require('strider.ui.flow_cards').get_card(session.q_answer_card_id, 'q'); "
                    "  ui.refresh_q_answer_layouts(); "
                    "  local buf = card.compose_buf; "
                    "  local win = card.compose_win; "
                    "  vim.api.nvim_set_current_win(win); "
                    "  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'what about follow ups?'}); "
                    "  return true "
                    "end)()"
                )
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "what about follow ups?" in "\n".join(h.q_log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request('q') == nil"),
                    timeout=5.0,
                )
                threaded = "\n".join(h.buffer_lines("strider://StriderQAnswer"))
                self.assertIn("what does this flag do", threaded)
                self.assertIn("what about follow ups?", threaded)

                h.ex("StriderQ")
                folded_height = int(h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  local win = vim.fn.win_findbuf(buf)[1]; "
                    "  require('strider.ui').refresh_q_answer_layouts(); "
                    "  return tostring(vim.api.nvim_win_get_height(win)); "
                    "end)()"
                ))
                self.assertLessEqual(folded_height, 3)
                self.assertNotIn("strider://StriderQCompose", h.json_expr(
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

                patch_log = "\n".join(h.patch_log_lines())
                self.assertIn("Applied the requested local patch.", patch_log)
                self.assertIn("Hello from patched fixture app", patch_log)

    def test_chat_q_and_patch_cards_stack_without_overlap(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                rows = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('main', vim.fn.getcwd()); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  state.ensure_session('patch', vim.fn.getcwd()); "
                    "  ui.show_chat_card(); "
                    "  ui.open_patch_card('change the greeting', { target = { path = vim.fn.getcwd() .. '/src/App.tsx', startLine = 1, endLine = 3 } }, 'patch'); "
                    "  ui.open_q_answer('where does this render?', 'q'); "
                    "  require('strider.ui.flow_cards').refresh_layouts(); "
                    "  local function row(name) "
                    "    local win = vim.fn.win_findbuf(vim.fn.bufnr(name))[1]; "
                    "    local cfg = vim.api.nvim_win_get_config(win); "
                    "    return type(cfg.row) == 'table' and (cfg.row[false] or cfg.row[1]) or cfg.row "
                    "  end; "
                    "  return string.format('%d,%d,%d', row('strider://StriderChatCard'), row('strider://StriderQAnswer'), row('strider://flow-card/patch/1')); "
                    "end)()"
                ).split(",")
                chat_row, q_row, patch_row = map(int, rows)
                self.assertGreater(chat_row, q_row)
                self.assertGreater(q_row, patch_row)

    def test_q_and_patch_use_distinct_workers(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').get_session('q') ~= nil"),
                    timeout=5.0,
                )

                h.ex("edit src/App.tsx")
                h.ex("1,3StriderPatch change the greeting literal")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').get_session('patch') ~= nil"),
                    timeout=5.0,
                )

                job_ids = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local q = state.get_session('q'); "
                    "  local p = state.get_session('patch'); "
                    "  return tostring(q and q.job_id or '') .. ',' .. tostring(p and p.job_id or '') "
                    "end)()"
                ).split(",")
                self.assertTrue(job_ids[0])
                self.assertTrue(job_ids[1])
                self.assertNotEqual(job_ids[0], job_ids[1])

    def test_multiple_striderq_cards_are_named_and_latest_toggles(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ first card question")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request('q') == nil"),
                    timeout=5.0,
                )

                h.ex("StriderQ second card question")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://flow-card/q/2")),
                    timeout=5.0,
                )

                names = h.lua(
                    "(function() "
                    "  local cards = require('strider.state').get_session('q').flow_cards; "
                    "  local names = vim.tbl_map(function(card) return card.name end, cards); "
                    "  return table.concat(names, '\\n') "
                    "end)()"
                ).split("\n")
                self.assertEqual(["StriderQ #1: first card question", "StriderQ #2: second card question"], names)

                h.ex("StriderQ")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://flow-card/q-compose/2", timeout=3.0)
                self.assertIn("second card question", "\n".join(h.buffer_lines("strider://flow-card/q/2")))

    def test_striderq_bang_opens_new_prompt_instead_of_toggling_latest(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ existing card")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.ex("StriderQ!")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertEqual("strider://prompt", h.expr("bufname('%')"))

    def test_card_picker_items_have_card_names(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                labels, q_labels = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('main', vim.fn.getcwd()); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  state.ensure_session('patch', vim.fn.getcwd()); "
                    "  ui.show_chat_card(); "
                    "  ui.open_q_answer('why is this named?', 'q', { new = true }); "
                    "  ui.open_patch_card('change the greeting', { target = { path = vim.fn.getcwd() .. '/src/App.tsx', startLine = 1, endLine = 3 } }, 'patch'); "
                    "  local picker = require('strider.ui.card_picker'); "
                    "  local labels = vim.tbl_map(function(item) return item.label end, picker.items()); "
                    "  local q_labels = vim.tbl_map(function(item) return item.label end, picker.items({ kind = 'q' })); "
                    "  return table.concat(labels, '\\n') .. '\\f' .. table.concat(q_labels, '\\n') "
                    "end)()"
                ).split("\f")
                labels = labels.split("\n")
                q_labels = q_labels.split("\n")
                self.assertIn("StriderChat · collapsed", labels)
                self.assertIn("StriderQ #1: why is this named? · running", labels)
                self.assertIn("StriderPatch #1: change the greeting · running", labels)
                self.assertEqual(["StriderQ #1: why is this named? · running"], q_labels)

    def test_card_keymaps_open_log_and_dismiss(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ why is this card dismissible")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1]); "
                    "  return true "
                    "end)()"
                )
                h.send("o", pause=0.3)
                h.wait_until(
                    lambda: "strider://StriderLogQ" in h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})"),
                    timeout=3.0,
                )

                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://StriderQAnswer'); "
                    "  vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1]); "
                    "  return true "
                    "end)()"
                )
                h.send("d", pause=0.3)
                self.assertNotIn("strider://StriderQAnswer", h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})"))
                labels = h.lua(
                    "(function() "
                    "  local labels = vim.tbl_map(function(item) return item.label end, require('strider.ui.card_picker').items({ kind = 'q' })); "
                    "  return table.concat(labels, '\\n') "
                    "end)()"
                )
                self.assertEqual("", labels)

    def test_strider_cards_clear_dismisses_completed_cards(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ clear me later")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )
                h.ex("StriderCardsClear")
                h.wait_until(
                    lambda: h.lua("(function() return tostring(#require('strider.ui.card_picker').items({ kind = 'q' })) end)()") == "0",
                    timeout=3.0,
                )
                self.assertNotIn("strider://StriderQAnswer", h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})"))

    def test_q_card_bracket_navigation_focuses_adjacent_card(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); local ui = require('strider.ui'); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  ui.open_q_answer('first nav card', 'q', { new = true }); "
                    "  ui.finish_q_answer('one', 'success', 'q'); "
                    "  ui.open_q_answer('second nav card', 'q', { new = true }); "
                    "  ui.finish_q_answer('two', 'success', 'q'); "
                    "  require('strider.ui').toggle_q_answer('q'); "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://flow-card/q-compose/2", timeout=3.0)
                h.lua(
                    "(function() "
                    "  vim.cmd('stopinsert'); "
                    "  local buf = vim.fn.bufnr('strider://flow-card/q/2'); "
                    "  vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1]); "
                    "  return true "
                    "end)()"
                )
                h.send("[", "c", pause=0.3)
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                self.assertIn("first nav card", "\n".join(h.buffer_lines("strider://StriderQAnswer")))

    def test_striderq_bang_starts_another_worker_while_q_is_busy(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ __strider_stream_delay__ slow first question")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request('q') ~= nil"),
                    timeout=3.0,
                )

                h.ex("StriderQ! second question")
                h.submit_popup()

                h.wait_until(lambda: h.lua_bool("require('strider.state').get_session('q-2') ~= nil"), timeout=5.0)
                job_ids = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local q1 = state.get_session('q'); local q2 = state.get_session('q-2'); "
                    "  return tostring(q1 and q1.job_id or '') .. ',' .. tostring(q2 and q2.job_id or '') "
                    "end)()"
                ).split(",")
                self.assertTrue(job_ids[0])
                self.assertTrue(job_ids[1])
                self.assertNotEqual(job_ids[0], job_ids[1])
                self.assertIn("second question", "\n".join(h.buffer_lines("strider://StriderLogQ-2")))
                self.assertFalse(h.popup_open())


if __name__ == "__main__":
    unittest.main()
