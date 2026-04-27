"""Tests for RPC command dispatch — /fork, /new, /compact, etc.

These exercise the Lua dispatch_prompt logic and the fake pi backend's
handling of non-prompt RPC message types.  Each test boots a real Neovim
session (via tmux + fake pi) so the full send_command → response →
callback path runs end-to-end.
"""
import json
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


def _winbar_for_buffer(h: TmuxNvimHarness, name: str) -> str:
    return h.lua(
        "(function() "
        f"  local buf = vim.fn.bufnr('{name}'); "
        "  if buf <= 0 then return '' end; "
        "  for _, win in ipairs(vim.fn.win_findbuf(buf)) do "
        "    if vim.api.nvim_win_is_valid(win) then "
        "      local value = vim.wo[win].winbar or ''; "
        "      local ok, evaluated = pcall(vim.api.nvim_eval_statusline, value, { winid = win, maxwidth = 10000 }); "
        "      if ok and evaluated and evaluated.str then return evaluated.str end; "
        "      return value "
        "    end "
        "  end "
        "  return '' "
        "end)()"
    )


class RpcCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    # ---- /fork -----------------------------------------------------------

    def test_fork_with_no_history_notifies_user(self) -> None:
        """When no messages have been sent, /fork should warn (no picker)."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Type /fork in compose and submit.
                h.send("/fork", "C-s", pause=0.5)
                # The fork flow should have warned — no crash, no picker.
                # Because there are no previous messages, the flow calls
                # ui.notify and returns. We can't easily assert on notify,
                # but we can verify no crash happened and Neovim is alive.
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    def test_fork_after_prompt_shows_picker(self) -> None:
        """After sending a prompt, /fork should trigger the picker flow."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Send a prompt first so the fake backend has a fork-able message.
                h.send("first message for fork test", "C-s", pause=0.5)
                h.wait_until(
                    lambda: "first message for fork test" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                # Wait for the turn to finish.
                h.wait_until(
                    lambda: h.lua_bool(
                        "require('strider.state').peek_pending_request() == nil"
                    ),
                    timeout=5.0,
                )

                # Now /fork — the picker should appear (vim.ui.select).
                # We stub vim.ui.select to auto-pick the first item.
                h.lua(
                    "(function() "
                    "  _G._fork_test_picked = false; "
                    "  _G._original_ui_select = vim.ui.select; "
                    "  vim.ui.select = function(items, opts, cb) "
                    "    _G._fork_test_picked = #items > 0; "
                    "    cb(items[1]); "
                    "  end; "
                    "  return true "
                    "end)()"
                )
                h.send("/fork", "C-s", pause=0.5)
                h.wait_until(
                    lambda: h.lua_bool("_G._fork_test_picked"),
                    timeout=5.0,
                )
                # Restore.
                h.lua(
                    "(function() vim.ui.select = _G._original_ui_select; return true end)()"
                )

    def test_fork_does_not_crash_on_rpc_error(self) -> None:
        """Verify fork_flow handles a failed get_fork_messages gracefully."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Force the backend to stop so the next command fails.
                h.lua(
                    "(function() "
                    "  local s = require('strider.state').get_session(); "
                    "  if s and s.job_id then vim.fn.jobstop(s.job_id) end; "
                    "  return true "
                    "end)()"
                )
                import time; time.sleep(0.5)
                # /fork should handle the missing backend gracefully.
                h.send("/fork", "C-s", pause=0.5)
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    # ---- /new ------------------------------------------------------------

    def test_new_session_command(self) -> None:
        """Typing /new in compose should send new_session to pi."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("/new", "C-s", pause=0.5)
                # Should not crash. The fake backend emits a session_start event.
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    # ---- /compact --------------------------------------------------------

    def test_compact_command_without_args(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("/compact", "C-s", pause=0.5)
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    def test_compact_command_with_instructions(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("/compact focus on the API layer", "C-s", pause=0.5)
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    def test_compact_command_shows_activity_until_response(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.lua(
                    "(function() "
                    "  require('strider.state').set_widget({ 'Model: fake', 'Context: 1k / 2k (50.0%)' }, 'main'); "
                    "  require('strider.ui').refresh_log_winbar('main'); "
                    "  return true "
                    "end)()"
                )
                h.send("/compact __strider_delay__", "C-s", pause=0.05)
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() ~= nil"),
                    timeout=2.0,
                )
                active = _winbar_for_buffer(h, "strider://compose")
                self.assertIn("Working (", active)
                self.assertIn(":StriderStop to interrupt", active)
                log_active = _winbar_for_buffer(h, "strider://log")
                self.assertIn("Working (", log_active)
                self.assertIn("Compacting Strider context", log_active)
                self.assertIn("Context: 1k / 2k (50.0%)", log_active)
                self.assertIn(":StriderStop to interrupt", log_active)
                self.assertIn("/compact __strider_delay__", "\n".join(h.log_lines()))
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() == nil"),
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Working" not in _winbar_for_buffer(h, "strider://compose"),
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Working" not in _winbar_for_buffer(h, "strider://log"),
                    timeout=3.0,
                )

    # ---- session extension command routing ------------------------------

    def test_resume_routes_through_prompt_extension_command(self) -> None:
        """/resume should be sent as a prompt so the extension can resolve ids."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("/resume abc123", "C-s", pause=0.5)
                h.wait_until(
                    lambda: "/resume abc123" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    def test_sessions_routes_through_prompt_extension_command(self) -> None:
        """/sessions should stay on the extension-command prompt path."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("/sessions", "C-s", pause=0.5)
                h.wait_until(
                    lambda: "/sessions" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    def test_session_vim_commands_send_main_lane_slash_commands(self) -> None:
        """:StriderSessions and :StriderResume should dispatch to main chat."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderSessions")
                h.wait_until(
                    lambda: "/sessions" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                h.ex("StriderResume abc123")
                h.wait_until(
                    lambda: "/resume abc123" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    # ---- response callback mechanism ------------------------------------

    def test_response_callback_fires_on_success(self) -> None:
        """send_command with a callback should invoke it on success."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Use send_command with a callback directly from Lua.
                h.lua(
                    "(function() "
                    "  _G._cb_test_result = 'waiting'; "
                    "  require('strider.rpc').send_command('get_fork_messages', {}, nil, "
                    "    function(event) "
                    "      if event.success and event.data then "
                    "        _G._cb_test_result = 'ok:' .. tostring(#(event.data.messages or {})); "
                    "      else "
                    "        _G._cb_test_result = 'fail'; "
                    "      end "
                    "    end); "
                    "  return true "
                    "end)()"
                )
                h.wait_until(
                    lambda: h.lua("tostring(_G._cb_test_result)") != "waiting",
                    timeout=5.0,
                )
                result = h.lua("tostring(_G._cb_test_result)")
                self.assertTrue(result.startswith("ok:"), f"expected ok:N, got {result}")

    def test_response_callback_fires_on_error(self) -> None:
        """send_command callback should fire with success=false on error."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Send fork without entryId — fake backend returns error.
                h.lua(
                    "(function() "
                    "  _G._cb_err_result = 'waiting'; "
                    "  require('strider.rpc').send_command('fork', {}, nil, "
                    "    function(event) "
                    "      _G._cb_err_result = event.success and 'ok' or 'error'; "
                    "    end); "
                    "  return true "
                    "end)()"
                )
                h.wait_until(
                    lambda: h.lua("tostring(_G._cb_err_result)") != "waiting",
                    timeout=5.0,
                )
                self.assertEqual("error", h.lua("tostring(_G._cb_err_result)"))

    # ---- /model alias ----------------------------------------------------

    def test_model_alias_routes_to_models(self) -> None:
        """/model (singular) should behave the same as /models."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # /model should be sent to pi as /models (the canonical name).
                # The fake backend doesn't have extensions, so pi responds
                # with a generic message. We just verify it doesn't crash
                # and the log records the user's input.
                h.send("/model", "C-s", pause=0.5)
                h.wait_until(
                    lambda: "/models" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )
                alive = h.expr("1+1")
                self.assertEqual("2", alive)

    # ---- error message formatting ----------------------------------------

    def test_rpc_error_includes_command_name(self) -> None:
        """Failed RPC responses should show /<command> in the error."""
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Send a fork command without entryId via send_command
                # (not through fork_flow). The fake backend returns an
                # error with command="fork". The error handler should
                # format it as "/fork failed: ...".
                h.lua(
                    "(function() "
                    "  require('strider.rpc').send_command('fork', {}); "
                    "  return true "
                    "end)()"
                )
                import time; time.sleep(1.0)
                log_text = "\n".join(h.log_lines())
                self.assertIn("/fork failed", log_text)


if __name__ == "__main__":
    unittest.main()
