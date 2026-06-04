"""Tests for review planning UI flows and rendering state."""
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


class ReviewPlanningFlowTests(unittest.TestCase):
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

    # --- plan-proposal clarify flow --------------------------------------
    # The picker contract: caller receives "accept", "modify", or nil.
    # Body/id routing is rpc.lua's job; the picker is intentionally dumb.

    def test_main_plan_proposal_uses_compose_instead_of_picker(self) -> None:
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.lua(
                "(function() "
                "  _G.strider_plan_select_called = false; "
                "  _G.strider_plan_response_called = false; "
                "  vim.ui.select = function(_, _, cb) "
                "    _G.strider_plan_select_called = true; "
                "    if cb then cb('Accept') end; "
                "  end; "
                "  require('strider.state').ensure_session('main', vim.fn.getcwd()); "
                "  require('strider.rpc.extension_ui').handle({ "
                "    method = 'editor', "
                "    id = 'plan-1', "
                "    title = '[strider-plan-proposal] Review this plan', "
                "    prefill = '1. Inspect\\n2. Patch' "
                "  }, 'main', function() _G.strider_plan_response_called = true end); "
                "  vim.wait(200); "
                "  return true "
                "end)()"
            )

            self.assertFalse(h.lua_bool("_G.strider_plan_select_called"))
            self.assertFalse(h.lua_bool("_G.strider_plan_response_called"))
            pending = self._lua_json(h, "require('strider.state').get_session('main').pending_clarify")
            self.assertEqual("plan-1", pending["id"])
            self.assertEqual("plan_proposal", pending["kind"])
            self.assertEqual("1. Inspect\n2. Patch", pending["prefill"])
            self.assertEqual(["1. Inspect", "2. Patch"], h.buffer_lines("strider://compose"))

    def test_plan_proposal_accept_delivers_accept_choice(self) -> None:
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.lua(
                "(function() "
                "  _G.strider_test_picker_choice = 'UNSET'; "
                "  vim.ui.select = function(items, opts, cb) cb('Accept') end; "
                "  return true "
                "end)()"
            )
            h.lua(
                "(function() "
                "  require('strider.ui').clarify_plan_proposal_picker("
                "    function(c) _G.strider_test_picker_choice = tostring(c) end); "
                "  return true "
                "end)()"
            )
            h.wait_until(
                lambda: h.lua("tostring(_G.strider_test_picker_choice)") != "UNSET",
                timeout=3.0,
            )
            self.assertEqual("accept", h.lua("tostring(_G.strider_test_picker_choice)"))

    def test_plan_proposal_modify_delivers_modify_choice(self) -> None:
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.lua(
                "(function() "
                "  _G.strider_test_picker_choice = 'UNSET'; "
                "  vim.ui.select = function(items, opts, cb) cb('Modify') end; "
                "  return true "
                "end)()"
            )
            h.lua(
                "(function() "
                "  require('strider.ui').clarify_plan_proposal_picker("
                "    function(c) _G.strider_test_picker_choice = tostring(c) end); "
                "  return true "
                "end)()"
            )
            h.wait_until(
                lambda: h.lua("tostring(_G.strider_test_picker_choice)") != "UNSET",
                timeout=3.0,
            )
            self.assertEqual("modify", h.lua("tostring(_G.strider_test_picker_choice)"))

    def test_plan_proposal_reject_delivers_nil(self) -> None:
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            h.lua(
                "(function() "
                "  _G.strider_test_picker_nil = false; "
                "  vim.ui.select = function(items, opts, cb) cb('Reject') end; "
                "  return true "
                "end)()"
            )
            h.lua(
                "(function() "
                "  require('strider.ui').clarify_plan_proposal_picker("
                "    function(c) if c == nil then _G.strider_test_picker_nil = true end end); "
                "  return true "
                "end)()"
            )
            h.wait_until(
                lambda: h.lua_bool("_G.strider_test_picker_nil"),
                timeout=3.0,
            )

    # --- selection reviews go through start_planned ----------------------

    def test_selection_review_uses_planned_state_shape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            target = project / "wide.txt"
            target.write_text("\n".join(f"line {i}" for i in range(1, 61)) + "\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                h.ex("edit wide.txt")
                self._submit_review(h, "1,60StriderReview walk through everything")
                h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
                h.wait_until(lambda: int(h.lua("#require('strider.state').get_session('review').review.items")) >= 2)

                planned = h.lua_bool("require('strider.state').get_session('review').review.planned")
                scope = h.lua("require('strider.state').get_session('review').review.scope")
                item_count = int(h.lua("#require('strider.state').get_session('review').review.items"))
                first_why = h.lua("require('strider.state').get_session('review').review.items[1].why")
                review_text = "\n".join(h.buffer_lines("strider://review"))

            self.assertTrue(planned)
            self.assertEqual("selection", scope)
            # 60 lines with MAX_REVIEW_LINES=40 → 2 stops
            self.assertEqual(2, item_count)
            self.assertTrue(first_why, "planned stops should carry a `why` string")
            # TOC is rendered in the sidebar for multi-stop plans
            self.assertIn("## Review plan", review_text)

    # --- free-scope review via /plan + strider_plan tool --------------------

    def test_ranged_question_renders_inline_answer_annotation(self) -> None:
        # After a plan lands, asking a ranged :StriderReview question
        # should stash pending_question and route the streamed answer
        # through capture_ranged_question_answer, producing an inline
        # annotation extmark in the stop's buffer.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            self._submit_review(h, "StriderReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('strider.review').is_planning()"),
                timeout=8.0,
            )
            self._advance_to_first_stop(h)
            # Open the active stop's buffer so we can mark a sub-range.
            current_path_expr = "require('strider.state').get_session('review').review.items[1].path"
            path = h.lua(current_path_expr)
            h.ex(f"edit {path}")
            # Stash pending_question directly to simulate a ranged ask,
            # then drive the answer through capture_ranged_question_answer.
            # Avoids racing the fake pi's reply routing.
            h.lua(
                "(function() "
                "  local r = require('strider.review').current_item(); "
                "  require('strider.review').begin_ranged_question("
                "    { path = r.path, startLine = r.startLine, endLine = r.startLine }, "
                "    'why this line?'); return true "
                "end)()"
            )
            h.lua(
                "(function() "
                "  require('strider.review').capture_ranged_question_answer("
                "    'Inline answer about that one line.', { partial = false }); "
                "  return true "
                "end)()"
            )

            # At least one annotation extmark should exist in the buffer.
            count_expr = (
                "(function() "
                "  local ns = vim.api.nvim_get_namespaces()['strider-annotations']; "
                "  if not ns then return 0 end; "
                "  local buf = vim.fn.bufnr('%'); "
                "  if buf <= 0 then return 0 end; "
                "  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) "
                "end)()"
            )
            h.wait_until(lambda: int(h.lua(count_expr)) >= 1, timeout=3.0)
            # pending_question should be cleared on a final (non-partial) answer.
            cleared = h.lua_bool(
                "require('strider.state').get_session('review').review.pending_question == nil"
            )
            self.assertTrue(cleared, "pending_question should clear on final answer")

    def test_plan_time_annotations_render_and_clear_between_stops(self) -> None:
        # When a stop is focused, its explanation should render as a
        # virtual-lines extmark in the stop's buffer. Advancing to the
        # next stop clears the previous buffer's annotations.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            self._submit_review(h, "StriderReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('strider.review').is_planning()"),
                timeout=8.0,
            )
            h.wait_until(
                lambda: int(h.lua("#require('strider.state').get_session('review').review.items")) >= 2,
                timeout=8.0,
            )
            self._advance_to_first_stop(h)

            # Stop 1 is in src/main.tsx after leaving message 0.
            # Count annotation extmarks in that buffer.
            count_expr = (
                "(function() "
                "  local ns = vim.api.nvim_get_namespaces()['strider-annotations']; "
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
            h.ex("StriderNext")
            h.wait_until(lambda: int(h.lua(count_expr)) == 0, timeout=3.0)

    def test_plan_time_explanations_land_without_follow_up_review_turn(self) -> None:
        # With pre-computed explanations, the first stop's explanation
        # should be populated as soon as the plan lands — no separate
        # /review dispatch required.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            self._submit_review(h, "StriderReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('strider.review').is_planning()"),
                timeout=8.0,
            )

            # Plan is done; pending should be None (no follow-up /review sent).
            h.wait_until(
                lambda: h.lua_bool(
                    "require('strider.state').peek_pending_request() == nil"
                ),
                timeout=4.0,
            )
            explanation = h.lua(
                "require('strider.state').get_session('review').review.items[1].explanation"
            )

        self.assertTrue(explanation, "stop 1 should carry a pre-computed explanation")
        # The fake pi's plan response for the app fixture puts a sentence
        # containing "bootstrap" in stop 1's explanation.
        self.assertIn("bootstrap", explanation.lower())

    def test_first_line_stops_render_visible_inline_help(self) -> None:
        # A stop anchored at line 1 cannot render its explanation above the
        # first line and still be visible in-window. Strider should place the
        # block where the user can actually see it for the first stop in each
        # file.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            self._submit_review(h, "StriderReview explain the app")
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(
                lambda: not h.lua_bool("require('strider.review').is_planning()"),
                timeout=8.0,
            )
            self._advance_to_first_stop(h)

            h.wait_until(lambda: "┌─ strider" in h.capture_pane(), timeout=3.0)

            h.ex("StriderNext")
            h.wait_until(
                lambda: int(h.lua("require('strider.state').get_session('review').review.current_index")) == 2,
                timeout=5.0,
            )
            h.wait_until(lambda: "src/App.tsx" in h.current_state()["buf"], timeout=3.0)
            h.wait_until(lambda: "┌─ strider" in h.capture_pane(), timeout=3.0)

    def test_free_scope_review_ingests_plan_tool_output(self) -> None:
        # fixture app has src/main.tsx + src/App.tsx; fake_pi.plan_response
        # emits a 2-stop strider_plan tool call for this project.
        project = self.repo_root / "tests" / "fixtures" / "app"
        with TmuxNvimHarness(self.repo_root, project) as h:
            self._submit_review(h, "StriderReview explain the app")

            # Wait for the plan to land and planning to finish.
            h.wait_until(lambda: h.lua_bool("require('strider.review').has_active_review()"))
            h.wait_until(lambda: not h.lua_bool("require('strider.review').is_planning()"), timeout=8.0)
            h.wait_until(lambda: int(h.lua("#require('strider.state').get_session('review').review.items")) >= 2, timeout=8.0)

            scope = h.lua("require('strider.state').get_session('review').review.scope")
            planned = h.lua_bool("require('strider.state').get_session('review').review.planned")
            item_count = int(h.lua("#require('strider.state').get_session('review').review.items"))
            first_why = h.lua("require('strider.state').get_session('review').review.items[1].why")
            current_index = int(h.lua("require('strider.state').get_session('review').review.current_index"))

        self.assertTrue(planned)
        self.assertEqual("free", scope)
        self.assertEqual(2, item_count)
        self.assertTrue(first_why)
        self.assertEqual(0, current_index)

    def test_ranges_cover_detects_gap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="strider-plan-") as tmp:
            project = Path(tmp)
            (project / "placeholder.txt").write_text("x\n")

            with TmuxNvimHarness(self.repo_root, project) as h:
                # target [1,20] covered by [1,5] and [10,20] → gap at 6-9
                ok_raw = h.expr(
                    "luaeval(\""
                    "(function() local r = require('strider.review'); "
                    "local ok, gaps = r._ranges_cover("
                    "  {{path='/x', startLine=1, endLine=20}},"
                    "  {{path='/x', startLine=1, endLine=5}, {path='/x', startLine=10, endLine=20}}"
                    "); return tostring(ok) .. ':' .. tostring(gaps[1].startLine) .. '-' .. tostring(gaps[1].endLine) end)()\""
                    ")"
                )
            self.assertEqual("false:6-9", ok_raw)


if __name__ == "__main__":
    unittest.main()
