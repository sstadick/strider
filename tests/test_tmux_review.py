import subprocess
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _init_branch_repo(root: Path, base: str = "main") -> None:
    _git(root, "init", "-q", "-b", base)
    _git(root, "config", "user.email", "sherpa-test@example.com")
    _git(root, "config", "user.name", "Sherpa Test")
    _git(root, "add", "-A")
    _git(root, "commit", "-q", "-m", "base commit")
    _git(root, "checkout", "-q", "-b", "feature/review")
    main_tsx = root / "src" / "main.tsx"
    text = main_tsx.read_text()
    main_tsx.write_text(text + "\n// sherpa branch review marker\n")
    _git(root, "add", "-A")
    _git(root, "commit", "-q", "-m", "feature change")


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

    def test_review_excerpt_uses_tsx_fence(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: "## Excerpt" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("```tsx", review_text)

    def test_review_excerpt_uses_python_fence(self) -> None:
        python_project = self.repo_root / "tests" / "fixtures" / "python_app"
        with TmuxNvimHarness(self.repo_root, python_project) as h:
            h.ex("edit app.py")
            h.ex("SherpaReview file")
            h.wait_until(lambda: "## Excerpt" in "\n".join(h.buffer_lines("sherpa://review")))

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("```python", review_text)

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

    def test_branch_review_builds_items_from_base_diff(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            _init_branch_repo(project_root, base="main")
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaReview branch main")
                h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

                review_text = "\n".join(h.buffer_lines("sherpa://review"))
                self.assertIn("source: `branch (main)`", review_text)
                self.assertIn("src/main.tsx", review_text)

                item_count = h.expr(
                    "luaeval(\"#require('sherpa.state').get_session().review.items\")"
                )
                self.assertEqual("1", item_count)

                first_item_path = h.expr(
                    "luaeval(\"require('sherpa.state').get_session().review.items[1].path\")"
                )
                self.assertTrue(first_item_path.endswith("src/main.tsx"), first_item_path)

    def test_branch_review_warns_on_unknown_base(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            _init_branch_repo(project_root, base="main")
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaReview branch does-not-exist")
                # No active review should start when the base ref is missing.
                self.assertFalse(
                    h.lua_bool("require('sherpa.review').has_active_review()")
                )

    def test_file_review_chunks_large_files_into_multiple_items(self) -> None:
        python_fixture = self.repo_root / "tests" / "fixtures" / "python_app"
        with FixtureProject(python_fixture) as project_root:
            long_file = project_root / "long_review.py"
            long_file.write_text(
                "\n".join(
                    f"def f{i}():\n    return {i}\n"
                    for i in range(1, 61)
                ),
                encoding="utf-8",
            )
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit long_review.py")
                h.ex("SherpaReview file")
                h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

                item_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
                self.assertGreater(item_count, 1)

                first_review = "\n".join(h.buffer_lines("sherpa://review"))
                self.assertIn("- item: `1/", first_review)
                self.assertIn("`long_review.py:1-40`", first_review)

                h.ex("SherpaNext")
                h.wait_until(lambda: "- item: `2/" in "\n".join(h.buffer_lines("sherpa://review")))
                second_review = "\n".join(h.buffer_lines("sherpa://review"))
                self.assertIn("`long_review.py:41-80`", second_review)

    def test_review_items_include_chunk_synopsis(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            summary = h.lua("require('sherpa.state').get_session().review.items[1].summary")
            self.assertNotEqual("Current file", summary)
            self.assertNotEqual("", summary)

    def test_top_level_review_with_focus_text_expands_to_project_review(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("SherpaReview Explain what this repo is about")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            item_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
            self.assertGreater(item_count, 1)

            review_text = "\n".join(h.buffer_lines("sherpa://review"))
            self.assertIn("- source: `project`", review_text)
            self.assertNotIn("sherpa://log", review_text)

    def test_project_review_defaults_to_relevant_subset_unless_user_asks_for_all_files(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            for index in range(12):
                extra = project_root / f"notes_{index}.txt"
                extra.write_text(f"scratch note {index}\n", encoding="utf-8")

            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaReview Explain what this repo is about")
                h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
                default_count = int(h.lua("#require('sherpa.state').get_session().review.items"))

            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaReview Explain every file in this repo")
                h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
                full_count = int(h.lua("#require('sherpa.state').get_session().review.items"))

            self.assertLess(default_count, full_count)

    def test_file_review_keeps_focus_on_current_file_when_log_opens_on_start(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.lua("(function() require('sherpa').setup({ open_log_on_start = true }); return true end)()")
            h.ex("edit src/main.tsx")
            h.ex("SherpaReview file")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))

            item_path = h.lua("require('sherpa.state').get_session().review.items[1].path")
            self.assertTrue(item_path.endswith("src/main.tsx"), item_path)


if __name__ == "__main__":
    unittest.main()
