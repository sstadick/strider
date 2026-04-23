"""Tests for :SherpaQ.

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
                h.ex("SherpaQ")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)

    def test_q_with_prompt_prefills_popup_and_stays_out_of_chat(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ what does this flag do")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("what does this flag do", "\n".join(h.buffer_lines("sherpa://prompt")))

                h.submit_popup()
                h.wait_until(
                    lambda: "what does this flag do" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                h.wait_until(
                    lambda: not h.lua_bool("require('sherpa.ui').chat_is_visible()"),
                    timeout=3.0,
                )

    def test_q_with_range_submits_without_opening_chat(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("1,2SherpaQ why is this bootstrapped here?")
                h.wait_until(lambda: h.popup_open(), timeout=3.0)
                self.assertIn("why is this bootstrapped here?", "\n".join(h.buffer_lines("sherpa://prompt")))

                h.submit_popup()
                h.wait_until(
                    lambda: "why is this bootstrapped here?" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                self.assertFalse(h.lua_bool("require('sherpa.ui').chat_is_visible()"))

    def test_q_completion_clears_pending_request(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ what does this flag do")
                h.submit_popup()
                h.wait_until(
                    lambda: h.lua_bool("require('sherpa.state').peek_pending_request() == nil"),
                    timeout=5.0,
                )


if __name__ == "__main__":
    unittest.main()
