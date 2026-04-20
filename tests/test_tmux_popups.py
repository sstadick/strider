"""Tests for the floating prompt editors used when Sherpa commands are called
with no arguments. Exercises search/review/work/patch popups end-to-end through
a real Neovim session with the fake pi backend.
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

            # Popup should close and the search should run through the pipeline
            # (single fixture match jumps to src/main.tsx).
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.current_state()["buf"].endswith("src/main.tsx"))

    def test_empty_search_cancels_on_escape(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaSearch")
            h.wait_until(lambda: _popup_open(h))

            h.send("Escape", "Escape", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            # No search ran, so the quickfix list stays empty.
            state = h.current_state()
            self.assertEqual(0, len(state["qf"]["items"]))

    def test_empty_work_opens_popup_and_dispatches(self) -> None:
        # Use a fixture copy because the fake-pi work response mutates App.tsx.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaWork")
                h.wait_until(lambda: _popup_open(h))

                h.send("add a banner", "C-s", pause=0.3)
                h.wait_until(lambda: not _popup_open(h))

                # The fake backend logs the /work prompt; we only care that the
                # popup closed and dispatch reached the log.
                log_text = "\n".join(h.log_lines())
                self.assertIn("add a banner", log_text)

    def test_empty_review_without_active_session_opens_popup_with_scope_hint(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            # First word is a scope key. Submitting "file" starts a file review.
            h.send("file", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

    def test_empty_review_during_active_session_asks_a_question(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            # Empty-args while a review is active opens the question editor.
            h.ex("SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("why does this mount App?", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            log_text = "\n".join(h.log_lines())
            self.assertIn("why does this mount App?", log_text)


if __name__ == "__main__":
    unittest.main()
