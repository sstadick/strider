"""Tests for the review-plan helpers and plan-based review flow.

plan_from_range / plan_from_diff are Lua-side helpers invoked directly.
Selection and free-scope reviews go through the planning pipeline (state:
planned=true, scope, coverage_ok, TOC in sidebar). Free-scope plans arrive
via the strider_plan tool call; the fake pi simulates that here.
"""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from tests.support.tmux_nvim import TmuxNvimHarness


def _run(cmd, cwd):
    subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def _seed_repo(root: Path) -> None:
    _run(["git", "init", "-q", "-b", "main"], cwd=root)
    _run(["git", "config", "user.email", "test@example.com"], cwd=root)
    _run(["git", "config", "user.name", "Test"], cwd=root)


class PlanHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]

    def _advance_to_first_stop(self, h: TmuxNvimHarness) -> None:
        h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
        h.wait_until(lambda: not h.lua_bool("require('strider.review').is_planning()"), timeout=8.0)
        h.ex("StriderNext")
        h.wait_until(
            lambda: int(h.lua("require('strider.state').get_session('review').review.current_index")) == 1,
            timeout=5.0,
        )

    def _submit_review(self, h: TmuxNvimHarness, command: str) -> None:
        h.ex(command)
        h.submit_popup()

    def _lua_json(self, h: TmuxNvimHarness, expression: str):
        raw = h.expr(f"json_encode(luaeval({json.dumps(expression)}))")
        return json.loads(raw)

    # --- plan_from_range ---------------------------------------------------

    def test_plan_from_range_short_range_produces_single_stop(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            target = project / "small.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 11)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    f"require('strider.review').plan_from_range({json.dumps(str(target))}, 1, 10)",
                )

            self.assertEqual("selection", plan["scope"])
            self.assertTrue(plan["coverage_ok"])
            self.assertEqual(1, len(plan["stops"]))
            stop = plan["stops"][0]
            self.assertEqual(1, stop["startLine"])
            self.assertEqual(10, stop["endLine"])
            self.assertIn("why", stop)
            self.assertTrue(stop["why"])

    def test_plan_from_range_long_range_chunks_and_covers_every_line(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            target = project / "big.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 101)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    f"require('strider.review').plan_from_range({json.dumps(str(target))}, 1, 100)",
                )

            self.assertEqual("selection", plan["scope"])
            self.assertTrue(plan["coverage_ok"])
            # 100 lines / 40 MAX_REVIEW_LINES -> 3 stops (40,40,20)
            self.assertGreater(len(plan["stops"]), 1)
            # stops are contiguous and cover [1,100] with no gaps or overlap
            cursor = 1
            for stop in plan["stops"]:
                self.assertEqual(cursor, stop["startLine"])
                self.assertLessEqual(stop["endLine"] - stop["startLine"] + 1, 40)
                cursor = stop["endLine"] + 1
            self.assertEqual(101, cursor)

    def test_plan_from_range_rejects_inverted_range(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            target = project / "empty.txt"
            target.write_text("a\nb\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                lua_src = (
                    'require("strider.review").plan_from_range('
                    + json.dumps(str(target))
                    + ', 5, 2) == nil'
                )
                raw = h.expr("luaeval(" + json.dumps(lua_src) + ")")
            self.assertIn(raw, {"v:true", "true"})

    # --- plan_from_diff ----------------------------------------------------

    def test_plan_from_diff_covers_every_changed_line(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            _seed_repo(project)
            target = project / "file.txt"
            original = "\n".join(f"line {i}" for i in range(1, 11)) + "\n"
            target.write_text(original)
            _run(["git", "add", "."], cwd=project)
            _run(["git", "commit", "-q", "-m", "init"], cwd=project)
            base_sha = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=project, text=True
            ).strip()

            # Modify: change lines 3-4, append lines 11-12.
            lines = original.splitlines()
            lines[2] = "CHANGED 3"
            lines[3] = "CHANGED 4"
            lines.extend(["appended A", "appended B"])
            target.write_text("\n".join(lines) + "\n")
            _run(["git", "commit", "-aq", "-m", "edit"], cwd=project)

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    (
                        "require('strider.review').plan_from_diff("
                        f"{json.dumps(str(project))}, {json.dumps(base_sha)})"
                    ),
                )

            self.assertEqual("diff", plan["scope"])
            self.assertEqual(base_sha, plan["base"])
            self.assertTrue(plan["coverage_ok"])
            self.assertGreater(len(plan["stops"]), 0)

            # Every changed new-file line (3,4,11,12) must be inside some stop.
            changed_lines = {3, 4, 11, 12}
            covered = set()
            for stop in plan["stops"]:
                self.assertTrue(stop["path"].endswith("file.txt"))
                for line_no in range(stop["startLine"], stop["endLine"] + 1):
                    covered.add(line_no)
            self.assertTrue(changed_lines.issubset(covered),
                            f"changed={changed_lines} covered={covered}")

    def test_plan_from_diff_returns_empty_plan_when_no_changes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            _seed_repo(project)
            (project / "only.txt").write_text("unchanged\n")
            _run(["git", "add", "."], cwd=project)
            _run(["git", "commit", "-q", "-m", "init"], cwd=project)
            base_sha = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=project, text=True
            ).strip()

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    (
                        "require('strider.review').plan_from_diff("
                        f"{json.dumps(str(project))}, {json.dumps(base_sha)})"
                    ),
                )

            self.assertEqual("diff", plan["scope"])
            self.assertTrue(plan["coverage_ok"])
            self.assertEqual([], plan["stops"])

    # --- coverage helper ---------------------------------------------------

    # --- firstLineText rebases misaligned plans ---------------------------

    def test_plan_with_wrong_line_numbers_is_rebased_via_first_line_text(self) -> None:
        # Simulates the common LLM failure: model returns a plan whose
        # line numbers are off, but `firstLineText` pinpoints the real
        # anchor. Strider should shift startLine/endLine and annotations
        # by the detected offset.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            # Need the backend up so we have a session. Kick off any
            # review first — we'll overwrite the review state below.
            self._submit_review(h, "StriderReview prime the session")
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('strider.review').is_planning()"),
                timeout=6.0,
            )

            # Seed a fixture file in the project with a distinctive anchor
            # at line 15 (1-based). Done after the session exists.
            target_path = self.repo_root / "tests" / "fixtures" / "app" / "__rebase_fixture.txt"
            try:
                header = "\n".join(["# header"] * 14)
                body = "MARKER_LINE\n" + "\n".join(
                    "line {}".format(i) for i in range(16, 30)
                )
                target_path.write_text(header + "\n" + body + "\n")

                # Reset into planning state, then ingest a plan with wrong
                # line numbers but a correct firstLineText anchor.
                h.lua(
                    "(function() require('strider.review').start_planning('test'); return true end)()"
                )
                lua_call = (
                    "(function() "
                    "  local args = { scope = 'free', stops = { { "
                    "    path = " + json.dumps(str(target_path)) + ", "
                    "    startLine = 7, endLine = 12, "
                    "    firstLineText = 'MARKER_LINE', "
                    "    title = 'Misaligned stop', "
                    "    why = 'Testing rebase.', "
                    "    summary = 'Rebase test.', "
                    "    explanation = 'The model got the numbers wrong but the anchor right.', "
                    "    annotations = { { kind = 'line', line = 9, text = 'Should land at 17' } } "
                    "  } } }; "
                    "  require('strider.review').ingest_plan(args); "
                    "  return true "
                    "end)()"
                )
                h.lua(lua_call)

                start_line = int(h.lua("require('strider.state').get_session('review').review.items[1].startLine"))
                end_line = int(h.lua("require('strider.state').get_session('review').review.items[1].endLine"))
                ann_line = int(h.lua("require('strider.state').get_session('review').review.items[1].annotations[1].line"))
            finally:
                if target_path.exists():
                    target_path.unlink()

        # Model said startLine=7, real anchor is at line 15 → offset = +8.
        self.assertEqual(15, start_line)
        self.assertEqual(20, end_line)  # 12 + 8
        self.assertEqual(17, ann_line)  # 9 + 8



if __name__ == "__main__":
    unittest.main()
