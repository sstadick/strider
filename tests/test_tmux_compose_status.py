"""Tests for compose winbars, status, and review prompt editors."""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


def _popup_open(h, name: str = "strider://prompt") -> bool:
    return h.expr(f"bufexists('{name}')") == "1"


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


def _compose_hint(h) -> str:
    return h.lua(
        "(function() "
        "  local buf = vim.fn.bufnr('strider://compose'); "
        "  if buf <= 0 then return '' end; "
        "  local ns = vim.api.nvim_create_namespace('strider-compose-hint'); "
        "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }); "
        "  for _, mark in ipairs(marks) do "
        "    local chunks = mark[4] and mark[4].virt_text or {}; "
        "    local parts = {}; "
        "    for _, chunk in ipairs(chunks) do table.insert(parts, chunk[1] or '') end; "
        "    if #parts > 0 then return table.concat(parts, '') end "
        "  end; "
        "  return '' "
        "end)()"
    )


class TmuxComposeStatusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_compose_buffer_identity_is_stable(self) -> None:
        # The compose buffer is created once and reused. After a send +
        # toggle-cycle, its bufnr stays the same - we're not leaking a
        # new buffer on every open.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                first_id = h.expr("bufnr('strider://compose')")
                h.send("first", "C-s", pause=0.3)
                # Toggle off (both visible -> hide both), then back on.
                h.ex("StriderChat")
                h.ex("StriderChat")
                second_id = h.expr("bufnr('strider://compose')")
                self.assertEqual(first_id, second_id)

    def test_chat_with_range_focuses_visible_compose_at_end(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                source_buf = int(h.lua("vim.api.nvim_get_current_buf()"))
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.lua(
                    "(function() "
                    f"  for _, win in ipairs(vim.fn.win_findbuf({source_buf})) do "
                    "    if vim.api.nvim_win_get_config(win).relative == '' then "
                    "      vim.api.nvim_set_current_win(win); return true "
                    "    end "
                    "  end; "
                    "  return false "
                    "end)()"
                )

                h.ex("1,2StriderChat")

                h.wait_until(
                    lambda: h.lua_bool(
                        "(function() "
                        "  if vim.fn.bufname('%') ~= 'strider://compose' then return false end; "
                        "  local cursor = vim.api.nvim_win_get_cursor(0); "
                        "  local last = vim.api.nvim_buf_line_count(0); "
                        "  local line = vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1] or ''; "
                        "  return cursor[1] == last and cursor[2] == #line "
                        "end)()"
                    ),
                    timeout=3.0,
                )
                self.assertIn("src/main.tsx:1-2", "\n".join(h.buffer_lines("strider://compose")))

    def test_compose_winbar_is_idle_when_chat_opens(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Strider is ready" in _winbar_for_buffer(h, "strider://compose"),
                    timeout=3.0,
                )
                hint = _compose_hint(h)
                self.assertIn("<C-s> send prompt", hint)
                self.assertIn("<C-s> steers", hint)

    def test_compose_winbar_shows_pending_turn_controls(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.lua(
                    "(function() "
                    "  require('strider.state').set_pending_request('prompt', {}); "
                    "  require('strider.ui').refresh_compose_winbar('main'); "
                    "  require('strider.ui').refresh_compose_hint(); "
                    "  return true "
                    "end)()"
                )

                h.wait_until(
                    lambda: "sends steer" in _winbar_for_buffer(h, "strider://compose")
                    and ":StriderStop" in _winbar_for_buffer(h, "strider://compose"),
                    timeout=3.0,
                )
                self.assertIn("<C-s> send steer", _compose_hint(h))

    def test_status_surface_lists_lanes_and_controls(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.ex("StriderStatus")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://status')") == "1",
                    timeout=3.0,
                )

                status_text = "\n".join(h.buffer_lines("strider://status"))
                self.assertIn("## main", status_text)
                self.assertIn("## flow", status_text)
                self.assertIn("## q", status_text)
                self.assertIn("## patch", status_text)
                self.assertIn("## review", status_text)
                self.assertIn(":StriderStop", status_text)
                self.assertIn(":StriderNext!", status_text)

    def test_compose_winbar_tracks_and_rotates_activity(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.lua(
                    "(function() "
                    "  require('strider.ui').start_activity('Strider review running...', 'log', 'review', 'main'); "
                    "  return true "
                    "end)()"
                )
                h.wait_until(
                    lambda: "Working (" in _winbar_for_buffer(h, "strider://compose")
                    and ":StriderStop to interrupt" in _winbar_for_buffer(h, "strider://compose"),
                    timeout=3.0,
                )
                active = _winbar_for_buffer(h, "strider://compose")
                self.assertRegex(active, r"Working \((?:\d+s|\d+m\d{2}s|\d+h\d{2}m)\)")
                self.assertIn(":StriderStop to interrupt", active)
                first = active
                # Elapsed time updates every second; wait for at least
                # one tick so the winbar changes.
                h.wait_until(
                    lambda: _winbar_for_buffer(h, "strider://compose") != first,
                    timeout=4.5,
                    interval=0.2,
                )
                h.lua(
                    "(function() require('strider.ui').finish_activity('done', 'success', 'main'); return true end)()"
                )
                h.wait_until(
                    lambda: "Working" not in _winbar_for_buffer(h, "strider://compose"),
                    timeout=3.0,
                )

    def test_empty_review_without_active_session_opens_context_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("StriderReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("focus on the mount flow", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))

            log_text = "\n".join(h.review_log_lines())
            self.assertIn("focus on the mount flow", log_text)

    def test_review_start_can_copy_main_chat_context(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat remember the login timeout decision")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request('main') == nil"),
                    timeout=5.0,
                )

                h.ex("StriderReview")
                h.wait_until(lambda: _popup_open(h))
                h.send("C-g", "c", pause=0.2)
                h.send("walk through the branch", "C-s", pause=0.3)
                h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))

                log_text = "\n".join(h.review_log_lines())
                self.assertIn("<MAIN_CHAT_CONTEXT>", log_text)
                self.assertIn("remember the login timeout decision", log_text)

    def test_empty_selection_review_opens_context_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("1,2StriderReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("explain the bootstrap path", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))

            review_text = "\n".join(h.buffer_lines("strider://review"))
            self.assertIn("src/main.tsx:1-2", review_text)

    def test_empty_review_during_active_session_opens_question_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderReview explain src/main.tsx")
            h.submit_popup()
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(lambda: not h.lua_bool("require('strider.review').is_planning()"), timeout=8.0)
            h.ex("StriderNext")
            h.wait_until(
                lambda: int(h.lua("require('strider.state').get_session('review').review.current_index")) == 1,
                timeout=5.0,
            )

            h.ex("StriderReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("why does this mount App?", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            log_text = "\n".join(h.review_log_lines())
            self.assertIn("why does this mount App?", log_text)


if __name__ == "__main__":
    unittest.main()
