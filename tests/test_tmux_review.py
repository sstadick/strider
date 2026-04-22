import tempfile
import unittest
from pathlib import Path

from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def _advance_to_first_stop(self, h: TmuxNvimHarness) -> None:
        h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
        h.wait_until(lambda: not h.lua_bool("require('sherpa.review').is_planning()"), timeout=8.0)
        h.ex("SherpaNext")
        h.wait_until(
            lambda: int(h.lua("require('sherpa.state').get_session().review.current_index")) == 1,
            timeout=5.0,
        )

    def test_removed_legacy_commands_are_not_registered(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            self.assertEqual("0", h.expr("exists(':SherpaQ')"))
            self.assertEqual("0", h.expr("exists(':SherpaTeach')"))
            self.assertEqual("2", h.expr("exists(':SherpaReview')"))

    def test_selection_review_populates_current_explanation(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("1,2SherpaReview why does this block matter?")
            h.wait_until(lambda: "src/main.tsx" in "\n".join(h.buffer_lines("sherpa://review")) and "## Explanation" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("## Explanation", review_text)
            self.assertIn("src/main.tsx", review_text)

    def test_file_review_populates_current_explanation(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview explain src/main.tsx")
            self._advance_to_first_stop(h)
            h.wait_until(lambda: "## Explanation" in "\n".join(h.buffer_lines("sherpa://review")) and "Waiting" not in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("## Explanation", review_text)
            self.assertNotIn("Waiting for the explanation", review_text)
            self.assertIn("src/main.tsx", review_text)

    def test_review_excerpt_uses_tsx_fence(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview explain src/main.tsx")
            self._advance_to_first_stop(h)
            h.wait_until(lambda: "## Excerpt" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("```tsx", review_text)

    def test_review_excerpt_uses_python_fence(self) -> None:
        python_project = self.repo_root / "tests" / "fixtures" / "python_app"
        with TmuxNvimHarness(self.repo_root, python_project) as h:
            h.ex("SherpaReview explain app.py")
            self._advance_to_first_stop(h)
            h.wait_until(lambda: "## Excerpt" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("```python", review_text)

    def test_review_excerpt_uses_text_fence_for_markdown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sherpa-md-") as tmp:
            project = Path(tmp)
            (project / "README.md").write_text(
                "# Sherpa\n\n- first item\n- second item\n\n## Details\nText here.\n",
                encoding="utf-8",
            )
            with TmuxNvimHarness(self.repo_root, project) as h:
                h.ex("edit README.md")
                h.ex("1,4SherpaReview explain this doc")
                h.wait_until(lambda: "## Excerpt" in "\n".join(h.buffer_lines("sherpa://review")))

                review_text = "\n".join(h.buffer_lines("sherpa://review"))
                self.assertIn("```text", review_text)
                self.assertNotIn("```markdown", review_text)

    def test_multiline_comment_editor_records_comment(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview explain src/main.tsx")
            self._advance_to_first_stop(h)

            h.ex("1,2SherpaComment")
            h.wait_until(lambda: h.expr("bufexists('sherpa://comment')") == "1")
            h.send("This needs more context", "Enter", "And a second line", "C-s", pause=1.0)
            h.wait_until(lambda: h.expr("luaeval(\"#require('sherpa.state').get_session().review.comments\")") == "1")

            comment_text = h.expr("luaeval(\"require('sherpa.state').get_session().review.comments[1].text\")")
            self.assertIn("This needs more context", comment_text)
            self.assertIn("And a second line", comment_text)

    def test_review_comment_is_recorded_and_used_at_end_of_review(self) -> None:
        python_project = self.repo_root / "tests" / "fixtures" / "python_app"
        with TmuxNvimHarness(self.repo_root, python_project) as h:
            h.ex("SherpaReview explain app.py")
            self._advance_to_first_stop(h)

            h.wait_until(lambda: "## Explanation" in "\n".join(h.buffer_lines("sherpa://review")))
            self.assertTrue(h.lua_bool("require('sherpa.review').has_active_review()"))

            h.ex("1,2SherpaComment why does this helper matter?")
            h.wait_until(lambda: h.expr("bufexists('sherpa://comment')") == "1")

            editor_text = "\n".join(h.buffer_lines("sherpa://comment"))
            self.assertIn("why does this helper matter?", editor_text)

            h.send("Enter", "Please document the intent too.", "C-s", pause=1.0)
            h.wait_until(lambda: h.expr("luaeval(\"#require('sherpa.state').get_session().review.comments\")") == "1")

            comment_text = h.expr("luaeval(\"require('sherpa.state').get_session().review.comments[1].text\")")
            self.assertIn("why does this helper matter?", comment_text)
            self.assertIn("Please document the intent too.", comment_text)

            h.ex("SherpaNext")
            h.wait_until(
                lambda: (not h.lua_bool("require('sherpa.review').has_active_review()"))
                and "I found unresolved review comments" in "\n".join(h.buffer_lines("sherpa://review"))
            )

            log_text = "\n".join(h.log_lines())
            self.assertIn("Summarize unresolved review comments", log_text)
            self.assertIn("I found unresolved review comments", log_text)

    def test_review_items_include_chunk_synopsis(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview explain src/main.tsx")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            summary = h.lua("require('sherpa.state').get_session().review.items[1].summary")
            self.assertNotEqual("", summary)

    def test_top_level_review_starts_planned_project_review(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview Explain what this repo is about")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            # plan arrives from the fake pi's sherpa_plan tool emission
            h.wait_until(lambda: not h.lua_bool("require('sherpa.review').is_planning()"), timeout=8.0)
            h.wait_until(lambda: int(h.lua("#require('sherpa.state').get_session().review.items")) >= 2, timeout=8.0)

            item_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
            self.assertGreaterEqual(item_count, 2)

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            current_index = int(h.lua("require('sherpa.state').get_session().review.current_index"))
            open_buffers = h.json_expr('map(getwininfo(), {_, v -> bufname(v.bufnr)})')
            self.assertIn("- source: `review`", review_text)
            self.assertIn("## Message 0", review_text)
            self.assertIn("[0] Message 0", review_text)
            self.assertNotIn("sherpa://log", review_text)
            self.assertNotIn("sherpa://log", open_buffers)
            self.assertEqual(0, current_index)

    def test_planned_review_next_advances_through_fixed_plan(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview Explain what this repo is about")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(lambda: not h.lua_bool("require('sherpa.review').is_planning()"), timeout=8.0)
            h.wait_until(lambda: int(h.lua("#require('sherpa.state').get_session().review.items")) >= 2, timeout=8.0)

            first_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
            first_index = int(h.lua("require('sherpa.state').get_session().review.current_index"))
            self.assertGreaterEqual(first_count, 2)
            self.assertEqual(0, first_index)

            h.ex("SherpaNext")
            h.wait_until(lambda: int(h.lua("require('sherpa.state').get_session().review.current_index")) == 1, timeout=5.0)

            h.ex("SherpaPrev")
            h.wait_until(lambda: int(h.lua("require('sherpa.state').get_session().review.current_index")) == 0, timeout=5.0)

            # plan length is fixed — advancing doesn't grow the list
            second_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
            self.assertEqual(first_count, second_count)

    def test_file_review_keeps_focus_on_named_file_when_log_opens_on_start(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.lua("(function() require('sherpa').setup({ open_log_on_start = true }); return true end)()")
            h.ex("SherpaReview explain src/main.tsx")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            item_path = h.lua("require('sherpa.state').get_session().review.items[1].path")
            self.assertTrue(item_path.endswith("src/main.tsx"), item_path)


if __name__ == "__main__":
    unittest.main()
