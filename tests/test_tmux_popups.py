"""Tests for the floating prompt editors used when Sherpa commands are called
with no arguments. Exercises search/review/prompt/patch popups end-to-end
through a real Neovim session with the fake pi backend.
"""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


def _popup_open(h, name: str = "sherpa://prompt") -> bool:
    return h.expr(f"bufexists('{name}')") == "1"


class TmuxPopupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_empty_search_opens_popup_and_dispatches_on_submit(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaSearch")
            h.wait_until(lambda: _popup_open(h))

            h.send("where is the main entrypoint?", "C-s", pause=0.3)

            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 1)

    def test_empty_search_cancels_on_escape(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaSearch")
            h.wait_until(lambda: _popup_open(h))

            h.send("Escape", "Escape", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            # No search ran, so the quickfix list stays empty.
            state = h.current_state()
            self.assertEqual(0, len(state["qf"]["items"]))

    def test_empty_prompt_draft_cancel_clears_region(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaPrompt")
                h.wait_until(
                    lambda: h.lua_bool("require('sherpa.ui').has_active_draft()"),
                    timeout=3.0,
                )
                # Cancel with <Esc><Esc> while in insert mode.
                h.send("Escape", "Escape", pause=0.3)
                h.wait_until(
                    lambda: not h.lua_bool("require('sherpa.ui').has_active_draft()"),
                    timeout=3.0,
                )

    def test_empty_prompt_opens_log_draft_and_dispatches(self) -> None:
        # :SherpaPrompt with no args opens the log buffer with a draft
        # scaffold. The user types into the draft region and hits <C-s>
        # to send. The draft lines stay in the log as history.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaPrompt")
                # A draft extmark should exist on the log buffer.
                h.wait_until(
                    lambda: h.lua_bool("require('sherpa.ui').has_active_draft()"),
                    timeout=3.0,
                )
                # Type into the draft and send.
                h.send("add a banner", "C-s", pause=0.3)
                # The draft extmark should clear after sending.
                h.wait_until(
                    lambda: not h.lua_bool("require('sherpa.ui').has_active_draft()"),
                    timeout=3.0,
                )
                # Message reached the fake backend.
                log_text = "\n".join(h.log_lines())
                self.assertIn("add a banner", log_text)

    def test_empty_review_without_active_session_opens_context_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("focus on the mount flow", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            log_text = "\n".join(h.log_lines())
            self.assertIn("focus on the mount flow", log_text)

    def test_empty_selection_review_opens_context_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("1,2SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("explain the bootstrap path", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("src/main.tsx:1-2", review_text)

    def test_empty_review_during_active_session_opens_question_editor(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview explain src/main.tsx")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            h.ex("SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("why does this mount App?", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            log_text = "\n".join(h.log_lines())
            self.assertIn("why does this mount App?", log_text)


if __name__ == "__main__":
    unittest.main()
