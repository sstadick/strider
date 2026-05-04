"""Tests for flow-card behavior shared by StriderQ and patch."""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxFlowCardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

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

    def test_multiple_striderq_cards_are_named_and_latest_command_opens_latest(self) -> None:
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

                h.ex("StriderQLatest")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://flow-card/q/2", timeout=3.0)
                self.assertTrue(h.lua_bool("vim.api.nvim_win_get_config(0).relative == ''"))
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

    def test_q_picker_opens_selected_answer_as_normal_split(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)

                h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  ui.open_q_answer('queued question', 'q', { new = true }); "
                    "  ui.finish_q_answer('queued answer', 'success', 'q'); "
                    "  return true "
                    "end)()"
                )
                h.lua(
                    "(function() "
                    "  local picker = require('strider.picker'); "
                    "  local original_select = picker.select; "
                    "  picker.select = function(_, items, on_select) "
                    "    on_select(items[1]); "
                    "    return true "
                    "  end; "
                    "  local ok, err = pcall(function() return require('strider').q_cards() end); "
                    "  picker.select = original_select; "
                    "  if not ok then error(err) end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.current_state()["buf"] == "strider://StriderQAnswer", timeout=3.0)
                self.assertTrue(h.lua_bool("vim.api.nvim_win_get_config(0).relative == ''"))
                self.assertIn("queued answer", "\n".join(h.buffer_lines("strider://StriderQAnswer")))

    def test_chat_and_q_answer_windows_keep_markdown_conceal(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                opts = h.lua(
                    "(function() "
                    "  local state = require('strider.state'); "
                    "  local ui = require('strider.ui'); "
                    "  state.ensure_session('main', vim.fn.getcwd()); "
                    "  ui.open_chat_split(function() return true end); "
                    "  state.ensure_session('q', vim.fn.getcwd()); "
                    "  ui.open_q_answer('why **bold**?', 'q', { new = true }); "
                    "  ui.finish_q_answer('answer with **bold**', 'success', 'q'); "
                    "  ui.open_q_answer_split(nil, 'q'); "
                    "  local function options(name) "
                    "    local buf = vim.fn.bufnr(name); "
                    "    local win = vim.fn.win_findbuf(buf)[1]; "
                    "    if not win then return 'missing' end; "
                    "    local level = vim.api.nvim_get_option_value('conceallevel', { scope = 'local', win = win }); "
                    "    local cursor = vim.api.nvim_get_option_value('concealcursor', { scope = 'local', win = win }); "
                    "    return tostring(level) .. ':' .. cursor; "
                    "  end; "
                    "  return options('strider://log') .. ',' .. options('strider://StriderQAnswer') "
                    "end)()"
                ).split(",")
                self.assertEqual(["3:nvic", "3:nvic"], opts)

    def test_card_keymaps_open_log_and_dismiss(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderQ why is this card dismissible")
                h.submit_popup()
                h.wait_until(
                    lambda: "Answer ready" in "\n".join(h.buffer_lines("strider://StriderQAnswer")),
                    timeout=5.0,
                )

                h.lua("(function() require('strider.ui').open_q_answer_split(nil, 'q'); return true end)()")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
                h.send("o", pause=0.3)
                h.wait_until(
                    lambda: "strider://StriderLogQ" in h.json_expr("map(getwininfo(), {_, v -> bufname(v.bufnr)})"),
                    timeout=3.0,
                )

                h.lua("(function() require('strider.ui').open_q_answer_split(nil, 'q'); return true end)()")
                h.wait_until(lambda: h.expr("bufname('%')") == "strider://StriderQAnswer", timeout=3.0)
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
