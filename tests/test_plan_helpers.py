"""Tests for the review-plan helpers and plan-based review flow.

plan_from_range / plan_from_diff are Lua-side helpers invoked directly.
Selection and free-scope reviews go through the planning pipeline (state:
planned=true, scope, coverage_ok, TOC in sidebar). Free-scope plans arrive
via the sherpa_plan tool call; the fake pi simulates that here.
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

    def _lua_json(self, h: TmuxNvimHarness, expression: str):
        raw = h.expr(f"json_encode(luaeval({json.dumps(expression)}))")
        return json.loads(raw)

    # --- plan_from_range ---------------------------------------------------

    def test_plan_from_range_short_range_produces_single_stop(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
            project = Path(tmp)
            target = project / "small.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 11)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    f"require('sherpa.review').plan_from_range({json.dumps(str(target))}, 1, 10)",
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
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
            project = Path(tmp)
            target = project / "big.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 101)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                plan = self._lua_json(
                    h,
                    f"require('sherpa.review').plan_from_range({json.dumps(str(target))}, 1, 100)",
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
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
            project = Path(tmp)
            target = project / "empty.txt"
            target.write_text("a\nb\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                lua_src = (
                    'require("sherpa.review").plan_from_range('
                    + json.dumps(str(target))
                    + ', 5, 2) == nil'
                )
                raw = h.expr("luaeval(" + json.dumps(lua_src) + ")")
            self.assertIn(raw, {"v:true", "true"})

    # --- plan_from_diff ----------------------------------------------------

    def test_plan_from_diff_covers_every_changed_line(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
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
                        "require('sherpa.review').plan_from_diff("
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
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
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
                        "require('sherpa.review').plan_from_diff("
                        f"{json.dumps(str(project))}, {json.dumps(base_sha)})"
                    ),
                )

            self.assertEqual("diff", plan["scope"])
            self.assertTrue(plan["coverage_ok"])
            self.assertEqual([], plan["stops"])

    # --- coverage helper ---------------------------------------------------

    # --- selection reviews go through start_planned ----------------------

    def test_selection_review_uses_planned_state_shape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
            project = Path(tmp)
            target = project / "wide.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 61)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                h.ex("edit wide.txt")
                h.ex("1,60SherpaReview walk through everything")
                h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
                h.wait_until(lambda: int(h.lua("#require('sherpa.state').get_session().review.items")) >= 2)

                planned = h.lua_bool("require('sherpa.state').get_session().review.planned")
                scope = h.lua("require('sherpa.state').get_session().review.scope")
                item_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
                first_why = h.lua("require('sherpa.state').get_session().review.items[1].why")
                review_text = "\n".join(h.buffer_lines("sherpa://review"))

            self.assertTrue(planned)
            self.assertEqual("selection", scope)
            # 60 lines with MAX_REVIEW_LINES=40 → 2 stops
            self.assertEqual(2, item_count)
            self.assertTrue(first_why, "planned stops should carry a `why` string")
            # TOC is rendered in the sidebar for multi-stop plans
            self.assertIn("## Review plan", review_text)

    # --- free-scope review via /plan + sherpa_plan tool --------------------

    def test_plan_time_explanations_land_without_follow_up_review_turn(self) -> None:
        # With pre-computed explanations, the first stop's explanation
        # should be populated as soon as the plan lands — no separate
        # /review dispatch required.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.ex("SherpaReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('sherpa.review').is_planning()"),
                timeout=8.0,
            )

            # Plan is done; pending should be None (no follow-up /review sent).
            h.wait_until(
                lambda: h.lua_bool(
                    "require('sherpa.state').peek_pending_request() == nil"
                ),
                timeout=4.0,
            )
            explanation = h.lua(
                "require('sherpa.state').get_session().review.items[1].explanation"
            )

        self.assertTrue(explanation, "stop 1 should carry a pre-computed explanation")
        # The fake pi's plan response for the app fixture puts a sentence
        # containing "bootstrap" in stop 1's explanation.
        self.assertIn("bootstrap", explanation.lower())

    def test_free_scope_review_ingests_plan_tool_output(self) -> None:
        # fixture app has src/main.tsx + src/App.tsx; fake_pi.plan_response
        # emits a 2-stop sherpa_plan tool call for this project.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.ex("SherpaReview explain the app")

            # Wait for the plan to land and planning to finish.
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(lambda: not h.lua_bool("require('sherpa.review').is_planning()"), timeout=8.0)
            h.wait_until(lambda: int(h.lua("#require('sherpa.state').get_session().review.items")) >= 2, timeout=8.0)

            scope = h.lua("require('sherpa.state').get_session().review.scope")
            planned = h.lua_bool("require('sherpa.state').get_session().review.planned")
            item_count = int(h.lua("#require('sherpa.state').get_session().review.items"))
            first_why = h.lua("require('sherpa.state').get_session().review.items[1].why")
            current_index = int(h.lua("require('sherpa.state').get_session().review.current_index"))

        self.assertTrue(planned)
        self.assertEqual("free", scope)
        self.assertEqual(2, item_count)
        self.assertTrue(first_why)
        self.assertEqual(1, current_index)

    def test_ranges_cover_detects_gap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sherpa-plan-") as tmp:
            project = Path(tmp)
            (project / "placeholder.txt").write_text("x\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                # target [1,20] covered by [1,5] and [10,20] → gap at 6-9
                ok_raw = h.expr(
                    "luaeval(\""
                    "(function() local r = require('sherpa.review'); "
                    "local ok, gaps = r._ranges_cover("
                    "  {{path='/x', startLine=1, endLine=20}},"
                    "  {{path='/x', startLine=1, endLine=5}, {path='/x', startLine=10, endLine=20}}"
                    "); return tostring(ok) .. ':' .. tostring(gaps[1].startLine) .. '-' .. tostring(gaps[1].endLine) end)()\""
                    ")"
                )
            self.assertEqual("false:6-9", ok_raw)


if __name__ == "__main__":
    unittest.main()
