import os
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


REAL_PI = os.environ.get("STRIDER_TEST_REAL_PI") == "1"


@unittest.skipUnless(REAL_PI, "set STRIDER_TEST_REAL_PI=1 to run real-pi smoke tests")
class RealPiSmokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.fixture_root = self.repo_root / "tests" / "fixtures" / "python_app"

    def test_real_pi_review_file_on_fixture_project(self) -> None:
        with FixtureProject(self.fixture_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root, real_pi=True) as h:
                initial_log_count = len(h.log_lines())
                h.ex("StriderReview explain app.py")
                h.submit_popup()

                h.wait_until(
                    lambda: h.lua_bool("require('strider.review').has_active_review()")
                    and len(h.log_lines()) > initial_log_count
                    and "[assistant]" in "\n".join(h.log_lines()),
                    timeout=55,
                )
                review_log = "\n".join(h.log_lines())
                self.assertTrue(h.lua_bool("require('strider.review').has_active_review()"))
                self.assertIn("[assistant]", review_log)

                h.wait_until(
                    lambda: "## Explanation" in "\n".join(h.buffer_lines("strider://review"))
                    and "Waiting for the explanation" not in "\n".join(h.buffer_lines("strider://review")),
                    timeout=20,
                )
                review_text = "\n".join(h.buffer_lines("strider://review"))
                self.assertNotIn("Waiting for the explanation", review_text)

    def test_real_pi_patch_selection_on_fixture_project(self) -> None:
        with FixtureProject(self.fixture_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root, real_pi=True) as h:
                h.ex("edit app.py")
                h.ex("5StriderPatch change the greeting literal from hi to hello and only touch this line")
                h.submit_popup()

                target = project_root / "app.py"
                h.wait_until(
                    lambda: "hello" in target.read_text(encoding="utf-8").lower(),
                    timeout=60,
                )
                patched = target.read_text(encoding="utf-8").lower()
                self.assertIn("hello", patched)


if __name__ == "__main__":
    unittest.main()
