"""Tests for :StriderQ.

Q now uses the floating prompt editor for input, dispatches a one-shot
background tangent, and does not pop open the chat surfaces.
"""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


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
