import unittest
from pathlib import Path

from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_removed_legacy_commands_are_not_registered(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            self.assertEqual("0", h.expr("exists(':SherpaQ')"))
            self.assertEqual("0", h.expr("exists(':SherpaTeach')"))
            self.assertEqual("2", h.expr("exists(':SherpaReview')"))

    def test_selection_review_populates_current_explanation(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("1,2SherpaReview why does this block matter?")
            h.wait_until(lambda: "This range is part of the current review" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("Current explanation", review_text)
            self.assertIn("This range is part of the current review", review_text)

    def test_file_review_populates_current_explanation(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(lambda: "Current explanation" in "\n".join(h.buffer_lines("sherpa://review")) and "Waiting" not in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("Current explanation", review_text)
            self.assertNotIn("Waiting for the explanation", review_text)

    def test_multiline_comment_editor_records_comment(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            h.ex("1,2SherpaComment")
            h.wait_until(lambda: h.expr("bufexists('sherpa://comment')") == "1")
            h.send("This needs more context", "Enter", "And a second line", "C-s", pause=1.0)
            h.wait_until(lambda: h.expr("luaeval(\"#require('sherpa.state').get_session().review.comments\")") == "1")

            comment_text = h.expr("luaeval(\"require('sherpa.state').get_session().review.comments[1].text\")")
            self.assertIn("This needs more context", comment_text)
            self.assertIn("And a second line", comment_text)

    def test_review_comment_is_recorded_and_used_at_end_of_review(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")

            h.wait_until(
                lambda: h.lua_bool("require('sherpa.review').has_active_review()")
                and "Current explanation" in "\n".join(h.buffer_lines("sherpa://review"))
            )
            self.assertTrue(h.lua_bool("require('sherpa.review').has_active_review()"))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("# Sherpa Review", review_text)
            self.assertIn("src/main.tsx", review_text)

            h.ex("1,2SherpaComment why does this mount App?")
            h.wait_until(lambda: h.expr("luaeval(\"#require('sherpa.state').get_session().review.comments\")") == "1")
            comment_text = h.expr("luaeval(\"require('sherpa.state').get_session().review.comments[1].text\")")
            self.assertEqual("why does this mount App?", comment_text)

            h.ex("SherpaNext")
            h.wait_until(
                lambda: (not h.lua_bool("require('sherpa.review').has_active_review()"))
                and "I found unresolved review comments" in "\n".join(h.buffer_lines("sherpa://review"))
            )

            log_text = "\n".join(h.log_lines())
            self.assertIn("Summarize unresolved review comments", log_text)
            self.assertIn("I found unresolved review comments", log_text)

            final_review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("Review summary", final_review_text)
            self.assertIn("I found unresolved review comments", final_review_text)


if __name__ == "__main__":
    unittest.main()
