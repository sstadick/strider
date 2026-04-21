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

    # --- firstLineText rebases misaligned plans ---------------------------

    def test_plan_with_wrong_line_numbers_is_rebased_via_first_line_text(self) -> None:
        # Simulates the common LLM failure: model returns a plan whose
        # line numbers are off, but `firstLineText` pinpoints the real
        # anchor. Sherpa should shift startLine/endLine and annotations
        # by the detected offset.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            # Need the backend up so we have a session. Kick off any
            # review first — we'll overwrite the review state below.
            h.ex("SherpaReview prime the session")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('sherpa.review').is_planning()"),
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
                    "(function() require('sherpa.review').start_planning('test'); return true end)()"
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
                    "  require('sherpa.review').ingest_plan(args); "
                    "  return true "
                    "end)()"
                )
                h.lua(lua_call)

                start_line = int(h.lua("require('sherpa.state').get_session().review.items[1].startLine"))
                end_line = int(h.lua("require('sherpa.state').get_session().review.items[1].endLine"))
                ann_line = int(h.lua("require('sherpa.state').get_session().review.items[1].annotations[1].line"))
            finally:
                if target_path.exists():
                    target_path.unlink()

        # Model said startLine=7, real anchor is at line 15 → offset = +8.
        self.assertEqual(15, start_line)
        self.assertEqual(20, end_line)  # 12 + 8
        self.assertEqual(17, ann_line)  # 9 + 8

    # --- clarify editor dialog --------------------------------------------

    def test_clarify_editor_opens_with_prefill_and_submits_value(self) -> None:
        # ui.open_clarify_editor is what the plan_proposal / question
        # clarify kinds drive on the Lua side. Verify it opens with the
        # prefilled text and delivers the submitted value via callback.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            # Stash the delivered value on a global for cross-call inspection.
            h.lua("(function() _G.sherpa_test_clarify_result = nil; return true end)()")
            h.lua(
                "(function() "
                "  require('sherpa.ui').open_clarify_editor('Test', 'initial', function(v) "
                "    _G.sherpa_test_clarify_result = v "
                "  end); return true "
                "end)()"
            )
            # Popup should be open with the prefill visible.
            h.wait_until(
                lambda: h.expr("bufexists('sherpa://clarify')") == "1",
                timeout=3.0,
            )
            popup_lines = h.buffer_lines("sherpa://clarify")
            self.assertIn("initial", "\n".join(popup_lines))

            # Type extra text + submit.
            h.send("edited", "C-s", pause=0.4)
            h.wait_until(
                lambda: h.lua("tostring(_G.sherpa_test_clarify_result)") != "nil",
                timeout=3.0,
            )
            delivered = h.lua("tostring(_G.sherpa_test_clarify_result)")
            self.assertIn("initial", delivered)
            self.assertIn("edited", delivered)

    def test_clarify_editor_cancel_delivers_nil(self) -> None:
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.lua("(function() _G.sherpa_test_clarify_cancelled = false; return true end)()")
            h.lua(
                "(function() "
                "  require('sherpa.ui').open_clarify_editor('Test', '', function(v) "
                "    if v == nil then _G.sherpa_test_clarify_cancelled = true end "
                "  end); return true "
                "end)()"
            )
            h.wait_until(
                lambda: h.expr("bufexists('sherpa://clarify')") == "1",
                timeout=3.0,
            )
            # Cancel via <Esc><Esc>. We're in insert mode after open.
            h.send("Escape", "Escape", pause=0.3)
            h.wait_until(
                lambda: h.lua_bool("_G.sherpa_test_clarify_cancelled"),
                timeout=3.0,
            )

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

    def test_ranged_question_renders_inline_answer_annotation(self) -> None:
        # After a plan lands, asking a ranged :SherpaReview question
        # should stash pending_question and route the streamed answer
        # through capture_ranged_question_answer, producing an inline
        # annotation extmark in the stop's buffer.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.ex("SherpaReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('sherpa.review').is_planning()"),
                timeout=8.0,
            )
            # Open the active stop's buffer so we can mark a sub-range.
            current_path_expr = "require('sherpa.state').get_session().review.items[1].path"
            path = h.lua(current_path_expr)
            h.ex(f"edit {path}")
            # Stash pending_question directly to simulate a ranged ask,
            # then drive the answer through capture_ranged_question_answer.
            # Avoids racing the fake pi's reply routing.
            h.lua(
                "(function() "
                "  local r = require('sherpa.review').current_item(); "
                "  require('sherpa.review').begin_ranged_question("
                "    { path = r.path, startLine = r.startLine, endLine = r.startLine }, "
                "    'why this line?'); return true "
                "end)()"
            )
            h.lua(
                "(function() "
                "  require('sherpa.review').capture_ranged_question_answer("
                "    'Inline answer about that one line.', { partial = false }); "
                "  return true "
                "end)()"
            )

            # At least one annotation extmark should exist in the buffer.
            count_expr = (
                "(function() "
                "  local ns = vim.api.nvim_get_namespaces()['sherpa-annotations']; "
                "  if not ns then return 0 end; "
                "  local buf = vim.fn.bufnr('%'); "
                "  if buf <= 0 then return 0 end; "
                "  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) "
                "end)()"
            )
            h.wait_until(lambda: int(h.lua(count_expr)) >= 1, timeout=3.0)
            # pending_question should be cleared on a final (non-partial) answer.
            cleared = h.lua_bool(
                "require('sherpa.state').get_session().review.pending_question == nil"
            )
            self.assertTrue(cleared, "pending_question should clear on final answer")

    def test_plan_time_annotations_render_and_clear_between_stops(self) -> None:
        # When a stop is focused, its explanation should render as a
        # virtual-lines extmark in the stop's buffer. Advancing to the
        # next stop clears the previous buffer's annotations.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.ex("SherpaReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('sherpa.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('sherpa.review').is_planning()"),
                timeout=8.0,
            )
            h.wait_until(
                lambda: int(h.lua("#require('sherpa.state').get_session().review.items")) >= 2,
                timeout=8.0,
            )

            # Stop 1 is in src/main.tsx — focused automatically after plan.
            # Count annotation extmarks in that buffer.
            count_expr = (
                "(function() "
                "  local ns = vim.api.nvim_get_namespaces()['sherpa-annotations']; "
                "  if not ns then return 0 end; "
                "  local buf = vim.fn.bufnr('src/main.tsx'); "
                "  if buf <= 0 then return 0 end; "
                "  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) "
                "end)()"
            )
            h.wait_until(lambda: int(h.lua(count_expr)) >= 1, timeout=4.0)
            stop1_count = int(h.lua(count_expr))
            self.assertGreaterEqual(
                stop1_count,
                1,
                "stop 1 should have at least one annotation extmark (the explanation block)",
            )

            # Advance to stop 2 — annotations on main.tsx should clear
            # (stop 2 is in App.tsx, a different buffer).
            h.ex("SherpaNext")
            h.wait_until(lambda: int(h.lua(count_expr)) == 0, timeout=3.0)

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
