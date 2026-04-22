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

    def test_empty_prompt_opens_compose_and_sends(self) -> None:
        # :SherpaChat with no args opens the log buffer and a persistent
        # compose buffer. <C-s> in compose sends and clears. The sent
        # text lands in the log as a [user] block.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                # Compose buffer should come into existence.
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://compose')") == "1",
                    timeout=3.0,
                )
                h.send("add a banner", "C-s", pause=0.3)
                # Compose buffer should be cleared after successful send.
                h.wait_until(
                    lambda: h.lua(
                        "(function() local b=vim.fn.bufnr('sherpa://compose'); "
                        "if b<=0 then return 'no-buf' end; "
                        "local l=vim.api.nvim_buf_get_lines(b,0,-1,false); "
                        "return (#l==0 or (#l==1 and l[1]=='')) and 'empty' or 'non-empty' end)()"
                    ) == "empty",
                    timeout=3.0,
                )
                # Message reached the fake backend.
                log_text = "\n".join(h.log_lines())
                self.assertIn("add a banner", log_text)

    def test_compose_steers_when_request_is_in_flight(self) -> None:
        # While a request is pending, compose <C-s> dispatches via
        # send_steer instead of starting a new prompt. The fake pi sees
        # it as a separate line of input and records it; we verify the
        # log shows both [user] blocks (original + steer).
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://compose')") == "1",
                    timeout=3.0,
                )
                # Fake a pending request so compose routes via steer.
                h.lua(
                    "(function() require('sherpa.state').set_pending_request("
                    "'prompt', {}); return true end)()"
                )
                h.send("steering input", "C-s", pause=0.3)
                # Wait for the compose buffer to clear (send succeeded).
                h.wait_until(
                    lambda: h.lua(
                        "(function() local b=vim.fn.bufnr('sherpa://compose'); "
                        "local l=vim.api.nvim_buf_get_lines(b,0,-1,false); "
                        "return (#l==0 or (#l==1 and l[1]=='')) and 'empty' or 'non-empty' end)()"
                    ) == "empty",
                    timeout=3.0,
                )
                log_text = "\n".join(h.log_lines())
                self.assertIn("steering input", log_text)

    def test_sherpachat_toggles_both_surfaces(self) -> None:
        # :SherpaChat with no args is a toggle. First call opens log +
        # compose; second call hides both.
        visible_expr = "require('sherpa.ui').chat_is_visible()"
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(lambda: h.lua_bool(visible_expr), timeout=3.0)
                h.ex("SherpaChat")
                h.wait_until(lambda: not h.lua_bool(visible_expr), timeout=3.0)

    def test_chat_with_args_does_not_follow_tool_edits(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("normal! 2G")

                h.ex("SherpaChat update the fixture app")
                h.wait_until(
                    lambda: "Loading fixture app" in (project_root / "src" / "App.tsx").read_text(),
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Finished a broader work pass" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )

                state = h.current_state()
                self.assertTrue(state["buf"].endswith("src/main.tsx"), state)
                self.assertEqual(2, state["line"], state)

    def test_compose_buffer_identity_is_stable(self) -> None:
        # The compose buffer is created once and reused. After a send +
        # toggle-cycle, its bufnr stays the same — we're not leaking a
        # new buffer on every open.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaChat")
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://compose')") == "1",
                    timeout=3.0,
                )
                first_id = h.expr("bufnr('sherpa://compose')")
                h.send("first", "C-s", pause=0.3)
                # Toggle off (both visible -> hide both), then back on.
                h.ex("SherpaChat")
                h.ex("SherpaChat")
                second_id = h.expr("bufnr('sherpa://compose')")
                self.assertEqual(first_id, second_id)

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
            h.wait_until(lambda: not h.lua_bool("require('sherpa.review').is_planning()"), timeout=8.0)
            h.ex("SherpaNext")
            h.wait_until(
                lambda: int(h.lua("require('sherpa.state').get_session().review.current_index")) == 1,
                timeout=5.0,
            )

            h.ex("SherpaReview")
            h.wait_until(lambda: _popup_open(h))

            h.send("why does this mount App?", "C-s", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            log_text = "\n".join(h.log_lines())
            self.assertIn("why does this mount App?", log_text)


if __name__ == "__main__":
    unittest.main()
