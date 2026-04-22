"""Tests for :SherpaQ — the tangent command that branches off the pi
session tree, runs in the main chat surfaces, and on end navigates
back so the branch drops off the active path.

Covers the decision table from `init.lua` M.q:
- Tangent inactive, no args     -> start tangent, open compose
- Tangent inactive, with prompt -> start tangent, send immediately
- Tangent active,   no args     -> end tangent
- Implicit-end: any other :Sherpa* command ends an active tangent first

The fake pi backend echoes a stable "fake-leaf-N" id for `/q-anchor`
via a `setStatus` extension_ui_request, which rpc.lua routes to the
pending callback. `/q-end` is acknowledged implicitly.
"""
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxTangentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def _q_active(self, h) -> bool:
        return h.lua_bool("require('sherpa.state').q_is_active()")

    def _q_anchor(self, h) -> str:
        return h.lua(
            "(function() local s = require('sherpa.state').get_session(); "
            "return s and s.q_anchor_id or '' end)()"
        )

    def test_q_with_prompt_anchors_and_sends(self) -> None:
        # :SherpaQ with a prompt should: grab an anchor from fake pi,
        # flip q_active, and dispatch the question through /prompt so
        # the fake backend's prompt_response fires and a [user] block
        # lands in the log.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                # Need a real chat first so there's "a conversation to
                # branch from" — except the fake always echoes an anchor
                # regardless of history, so this works from a cold start.
                h.ex("SherpaQ what does this flag do")
                h.wait_until(lambda: self._q_active(h), timeout=3.0)
                # Anchor should be populated from the setStatus echo.
                h.wait_until(lambda: self._q_anchor(h).startswith("fake-leaf-"), timeout=3.0)

                # The question should have reached the fake backend via
                # /prompt (prompt_response writes "Finished a broader
                # work pass..." for the src/App.tsx fixture).
                h.wait_until(
                    lambda: "what does this flag do" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )

    def test_q_no_args_inactive_opens_compose(self) -> None:
        # :SherpaQ with nothing at all and no active tangent should
        # start a tangent and open the compose surfaces so the user can
        # type. We verify the compose buffer exists and q_active flipped.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ")
                h.wait_until(lambda: self._q_active(h), timeout=3.0)
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://compose')") == "1",
                    timeout=3.0,
                )

    def test_q_reinvoked_with_no_args_ends_tangent(self) -> None:
        # Start a tangent, then re-invoke :SherpaQ with no args. The
        # decision table says: tangent active + no args -> end. We
        # verify q_active flips back to false and the anchor clears.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ first question")
                h.wait_until(lambda: self._q_active(h), timeout=3.0)

                h.ex("SherpaQ")
                h.wait_until(lambda: not self._q_active(h), timeout=3.0)
                self.assertEqual("", self._q_anchor(h))

    def test_other_sherpa_command_implicitly_ends_tangent(self) -> None:
        # The send() guard ends an active tangent when any non-Q
        # operation runs. :SherpaSearch is a convenient probe — it
        # routes through send() without is_q=true.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ what does this flag do")
                h.wait_until(lambda: self._q_active(h), timeout=3.0)

                h.ex("SherpaSearch where is the main entrypoint?")
                h.wait_until(lambda: not self._q_active(h), timeout=5.0)

    def test_q_badge_appears_in_compose_winbar(self) -> None:
        # While a tangent is active, compose_status_line prepends a
        # "[Tangent] " prefix. We check the winbar string contains it.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("SherpaQ")
                h.wait_until(lambda: self._q_active(h), timeout=3.0)
                h.wait_until(
                    lambda: h.expr("bufexists('sherpa://compose')") == "1",
                    timeout=3.0,
                )

                winbar = h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('sherpa://compose'); "
                    "  if buf <= 0 then return '' end; "
                    "  for _, win in ipairs(vim.fn.win_findbuf(buf)) do "
                    "    if vim.api.nvim_win_is_valid(win) then return vim.wo[win].winbar or '' end "
                    "  end; "
                    "  return '' "
                    "end)()"
                )
                self.assertIn("Tangent", winbar, f"winbar was: {winbar!r}")


if __name__ == "__main__":
    unittest.main()
