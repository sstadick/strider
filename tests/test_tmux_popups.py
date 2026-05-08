"""Tests for prompt editors and the main chat compose/log surfaces.

Exercises search/review/prompt/patch popups plus split chat behavior end-to-end
through a real Neovim session with the fake pi backend.
"""
import base64
import json
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


TEST_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/6xkAAAAASUVORK5CYII="
)


def _popup_open(h, name: str = "strider://prompt") -> bool:
    return h.expr(f"bufexists('{name}')") == "1"


def _winbar_for_buffer(h, name: str) -> str:
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
        "  end; "
        "  return '' "
        "end)()"
    )


def _compose_hint(h) -> str:
    return h.lua(
        "(function() "
        "  local buf = vim.fn.bufnr('strider://compose'); "
        "  if buf <= 0 then return '' end; "
        "  local ns = vim.api.nvim_create_namespace('strider-compose-hint'); "
        "  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }); "
        "  for _, mark in ipairs(marks) do "
        "    local chunks = mark[4] and mark[4].virt_text or {}; "
        "    local parts = {}; "
        "    for _, chunk in ipairs(chunks) do table.insert(parts, chunk[1] or '') end; "
        "    if #parts > 0 then return table.concat(parts, '') end "
        "  end; "
        "  return '' "
        "end)()"
    )


class TmuxPopupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_empty_search_opens_popup_and_dispatches_on_submit(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderSearch")
            h.wait_until(lambda: _popup_open(h))

            h.send("where is the main entrypoint?", "C-s", pause=0.3)

            h.wait_until(lambda: not _popup_open(h))
            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 1)

    def test_empty_search_cancels_on_escape(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderSearch")
            h.wait_until(lambda: _popup_open(h))

            h.send("Escape", "Escape", pause=0.3)
            h.wait_until(lambda: not _popup_open(h))

            # No search ran, so the quickfix list stays empty.
            state = h.current_state()
            self.assertEqual(0, len(state["qf"]["items"]))

    def test_empty_prompt_opens_compose_and_sends(self) -> None:
        # :StriderChat with no args opens the log buffer and a persistent
        # compose buffer. <C-s> in compose sends and clears. The sent
        # text lands in the log as a [user] block.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                # Compose buffer should come into existence.
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                h.send("add a banner", "C-s", pause=0.3)
                # Compose buffer should be cleared after successful send.
                h.wait_until(
                    lambda: h.lua(
                        "(function() local b=vim.fn.bufnr('strider://compose'); "
                        "if b<=0 then return 'no-buf' end; "
                        "local l=vim.api.nvim_buf_get_lines(b,0,-1,false); "
                        "return (#l==0 or (#l==1 and l[1]=='')) and 'empty' or 'non-empty' end)()"
                    ) == "empty",
                    timeout=3.0,
                )
                # Message reached the fake backend.
                log_text = "\n".join(h.log_lines())
                self.assertIn("add a banner", log_text)

    def test_striderchat_uses_normal_split_windows(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                source_buf = int(h.lua("vim.api.nvim_get_current_buf()"))
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)

                result = h.lua(
                    "(function() "
                    f"  local source_buf = {source_buf}; "
                    "  local function kind(name) "
                    "    local buf = vim.fn.bufnr(name); "
                    "    local win = vim.fn.win_findbuf(buf)[1]; "
                    "    local rel = vim.api.nvim_win_get_config(win).relative; "
                    "    return rel == '' and 'regular' or rel; "
                    "  end; "
                    "  local source_win = vim.fn.win_findbuf(source_buf)[1]; "
                    "  local shrunk = vim.api.nvim_win_get_width(source_win) < vim.o.columns; "
                    "  return table.concat({ kind('strider://log'), kind('strider://compose'), tostring(shrunk) }, '|'); "
                    "end)()"
                )
                self.assertEqual("regular|regular|true", result)

    def test_chat_read_only_adds_badge_and_prompt_guard(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)

                h.ex("StriderChatReadOnly on")
                h.wait_until(lambda: "RO" in _winbar_for_buffer(h, "strider://compose"), timeout=3.0)
                self.assertTrue(h.lua_bool("require('strider').chat_read_only_enabled()"))

                h.send("explain without edits", "C-s", pause=0.3)
                h.wait_until(
                    lambda: "Read-only prompt received" in "\n".join(h.log_lines()),
                    timeout=5.0,
                )
                log_text = "\n".join(h.log_lines())
                self.assertIn("explain without edits", log_text)
                self.assertNotIn("Read-only chat mode is enabled.", log_text)

    def test_chat_read_only_keymaps_toggle_mode(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.lua("(function() vim.cmd('stopinsert'); return true end)()")

                h.send("g", "R", pause=0.3)
                h.wait_until(lambda: h.lua_bool("require('strider').chat_read_only_enabled()"), timeout=3.0)
                self.assertIn("RO", _winbar_for_buffer(h, "strider://compose"))

                h.send("g", "R", pause=0.3)
                h.wait_until(lambda: not h.lua_bool("require('strider').chat_read_only_enabled()"), timeout=3.0)
                self.assertNotIn("RO", _winbar_for_buffer(h, "strider://compose"))

                h.lua("(function() vim.cmd('startinsert'); return true end)()")
                h.send("C-g", "r", pause=0.3)
                h.wait_until(lambda: h.lua_bool("require('strider').chat_read_only_enabled()"), timeout=3.0)
                self.assertIn("RO", _winbar_for_buffer(h, "strider://compose"))

    def test_compose_ctrl_v_inserts_image_marker(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            clipboard_png = project_root / "clipboard-test.png"
            clipboard_png.write_bytes(TEST_PNG)

            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() require('strider.state').setup({ clipboard_image_test_file = "
                    + json.dumps(str(clipboard_png))
                    + " }); return true end)()"
                )
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )

                h.send("C-v", pause=0.3)
                h.wait_until(
                    lambda: any(
                        line.startswith("@image ")
                        for line in h.buffer_lines("strider://compose")
                    ),
                    timeout=3.0,
                )

                lines = h.buffer_lines("strider://compose")
                marker_index, marker = next(
                    (idx, line) for idx, line in enumerate(lines) if line.startswith("@image ")
                )
                pasted_path = Path(marker.removeprefix("@image "))
                self.assertTrue(pasted_path.exists(), pasted_path)
                self.assertNotEqual(clipboard_png, pasted_path)
                self.assertEqual("", lines[marker_index + 1])

    def test_compose_ctrl_v_inserts_image_marker_at_cursor(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            clipboard_png = project_root / "clipboard-test.png"
            clipboard_png.write_bytes(TEST_PNG)

            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() require('strider.state').setup({ clipboard_image_test_file = "
                    + json.dumps(str(clipboard_png))
                    + " }); return true end)()"
                )
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )
                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://compose'); "
                    "  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'before', 'after'}); "
                    "  vim.api.nvim_win_set_cursor(0, {2, 0}); "
                    "  return true "
                    "end)()"
                )

                h.send("C-v", pause=0.3)
                h.wait_until(
                    lambda: any(
                        line.startswith("@image ")
                        for line in h.buffer_lines("strider://compose")
                    ),
                    timeout=3.0,
                )

                lines = h.buffer_lines("strider://compose")
                marker_index = next(
                    idx for idx, line in enumerate(lines) if line.startswith("@image ")
                )
                self.assertEqual(1, marker_index)
                self.assertEqual("before", lines[marker_index - 1])
                self.assertEqual("after", lines[marker_index + 1])
                self.assertEqual(marker_index + 1, h.current_state()["line"])

    def test_compose_ctrl_v_inserts_image_marker_at_cursor_column(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            clipboard_png = project_root / "clipboard-test.png"
            clipboard_png.write_bytes(TEST_PNG)

            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.lua(
                    "(function() require('strider.state').setup({ clipboard_image_test_file = "
                    + json.dumps(str(clipboard_png))
                    + " }); return true end)()"
                )
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )
                h.lua(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://compose'); "
                    "  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'before after'}); "
                    "  vim.api.nvim_win_set_cursor(0, {1, 7}); "
                    "  return true "
                    "end)()"
                )

                h.send("C-v", pause=0.3)
                h.wait_until(
                    lambda: h.buffer_lines("strider://compose")[0].startswith("before @image "),
                    timeout=3.0,
                )

                lines = h.buffer_lines("strider://compose")
                self.assertTrue(lines[0].startswith("before @image "))
                self.assertEqual("after", lines[1])
                self.assertEqual(1, h.current_state()["line"])

    def test_prompt_turn_logs_reasoning_before_assistant_text(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat add a banner")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )
                self.assertIn("add a banner", "\n".join(h.buffer_lines("strider://compose")))
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "• Thought" in "\n".join(h.log_lines())
                    and "Finished a broader work pass" in "\n".join(h.log_lines()),
                    timeout=4.0,
                )

                log_text = "\n".join(h.log_lines())
                self.assertIn("Checking the relevant files first", log_text)
                self.assertLess(log_text.index("• Thought"), log_text.index("Finished a broader work pass"))

    def test_compose_steers_when_request_is_in_flight(self) -> None:
        # While a request is pending, compose <C-s> dispatches via
        # send_steer instead of starting a new prompt. The fake pi sees
        # it as a separate line of input and records it; we verify the
        # log shows a distinct steer marker.
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(
                    lambda: h.expr("bufexists('strider://compose')") == "1",
                    timeout=3.0,
                )
                # Fake a pending request so compose routes via steer.
                h.lua(
                    "(function() require('strider.state').set_pending_request("
                    "'prompt', {}); return true end)()"
                )
                h.send("steering input", "C-s", pause=0.3)
                # Wait for the compose buffer to clear (send succeeded).
                h.wait_until(
                    lambda: h.lua(
                        "(function() local b=vim.fn.bufnr('strider://compose'); "
                        "local l=vim.api.nvim_buf_get_lines(b,0,-1,false); "
                        "return (#l==0 or (#l==1 and l[1]=='')) and 'empty' or 'non-empty' end)()"
                    ) == "empty",
                    timeout=3.0,
                )
                log_text = "\n".join(h.log_lines())
                self.assertIn("» steering input", log_text)
                self.assertTrue(h.lua_bool(
                    "(function() "
                    "  local buf = vim.fn.bufnr('strider://log'); "
                    "  local ns = vim.api.nvim_create_namespace('strider-log'); "
                    "  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do "
                    "    if mark[4] and mark[4].hl_group == 'StriderLogSteer' then return true end "
                    "  end; "
                    "  return false "
                    "end)()"
                ))

    def test_striderchat_toggles_both_surfaces(self) -> None:
        # :StriderChat with no args toggles log + compose. Hiding chat should
        # leave no compact card; the next bare :StriderChat opens the splits.
        visible_expr = "require('strider.ui').chat_is_visible()"
        card_visible = "vim.fn.bufwinnr('strider://StriderChatCard') > 0"
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.lua_bool(visible_expr), timeout=3.0)
                h.ex("StriderChat")
                h.wait_until(lambda: not h.lua_bool(visible_expr), timeout=3.0)
                self.assertFalse(h.lua_bool(card_visible))
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                self.assertFalse(h.lua_bool(card_visible))

    def test_striderchat_hide_restores_previously_focused_window(self) -> None:
        visible_expr = "require('strider.ui').chat_is_visible()"
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("botright vsplit src/App.tsx")
                h.ex("wincmd h")
                self.assertTrue(h.current_state()["buf"].endswith("src/main.tsx"))

                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.ex("StriderChat")
                h.wait_until(lambda: not h.lua_bool(visible_expr), timeout=3.0)

                self.assertTrue(h.current_state()["buf"].endswith("src/main.tsx"))

    def test_striderchat_hide_from_chat_only_windows_lands_on_empty_buffer(self) -> None:
        visible_expr = "require('strider.ui').chat_is_visible()"
        window_names = "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.lua(
                    "(function() "
                    "  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do "
                    "    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)); "
                    "    if not name:match('strider://log$') and not name:match('strider://compose$') then "
                    "      pcall(vim.api.nvim_win_close, win, true); "
                    "    end "
                    "  end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.lua_bool(visible_expr), timeout=3.0)

                h.ex("StriderChat")
                h.wait_until(lambda: not h.lua_bool(visible_expr), timeout=3.0)

                self.assertEqual("", h.current_state()["buf"])
                self.assertEqual("", h.expr("&buftype"))
                self.assertEqual([""], h.json_expr(window_names))

    def test_striderchat_hide_from_chat_only_log_closes_pinned_prompt(self) -> None:
        visible_expr = "require('strider.ui').chat_is_visible()"
        pin_visible = (
            "(function() "
            "  for _, win in ipairs(vim.api.nvim_list_wins()) do "
            "    if vim.api.nvim_win_is_valid(win) then "
            "      local buf = vim.api.nvim_win_get_buf(win); "
            "      if vim.b[buf].strider_log_pin then return true end "
            "    end "
            "  end; "
            "  return false "
            "end)()"
        )
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.lua(
                    "(function() "
                    "  local ui = require('strider.ui'); "
                    "  ui.append_block('user', 'why is the prompt still pinned?', 'main'); "
                    "  for i = 1, 80 do ui.append({'assistant ' .. i}, 'main') end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.lua_bool(pin_visible), timeout=3.0)
                h.lua(
                    "(function() "
                    "  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do "
                    "    if vim.api.nvim_win_get_config(win).relative == '' then "
                    "      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)); "
                    "      if not name:match('strider://log$') then "
                    "        pcall(vim.api.nvim_win_close, win, true); "
                    "      end "
                    "    end "
                    "  end; "
                    "  return true "
                    "end)()"
                )
                h.wait_until(lambda: h.lua_bool(visible_expr), timeout=3.0)
                self.assertTrue(h.lua_bool(pin_visible))

                h.ex("StriderChat")
                h.wait_until(lambda: not h.lua_bool(visible_expr), timeout=3.0)

                self.assertEqual("", h.current_state()["buf"])
                self.assertFalse(h.lua_bool(pin_visible))

    def test_collapsed_chat_does_not_reopen_log_on_first_stream(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat delayed __strider_stream_delay__")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.send("C-s", pause=0.05)
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() ~= nil"),
                    timeout=2.0,
                )
                h.ex("StriderChat")
                h.wait_until(
                    lambda: not h.lua_bool("require('strider.ui').chat_is_visible()"),
                    timeout=3.0,
                )
                self.assertEqual("-1", h.expr("bufwinnr('strider://StriderChatCard')"))
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() == nil"),
                    timeout=5.0,
                )
                self.assertNotIn("strider://log", h.json_expr(
                    "map(getwininfo(), {_, v -> bufname(v.bufnr)})"
                ))
                self.assertEqual("-1", h.expr("bufwinnr('strider://StriderChatCard')"))

    def test_hidden_chat_does_not_show_card_when_turn_finishes(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderChat")
                h.wait_until(lambda: h.current_state()["buf"] == "strider://compose", timeout=3.0)
                h.send("/compact __strider_delay__", "C-s", pause=0.05)
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() ~= nil"),
                    timeout=2.0,
                )
                h.ex("StriderChat")
                h.wait_until(
                    lambda: not h.lua_bool("require('strider.ui').chat_is_visible()"),
                    timeout=3.0,
                )
                self.assertEqual("-1", h.expr("bufwinnr('strider://StriderChatCard')"))
                h.wait_until(
                    lambda: h.lua_bool("require('strider.state').peek_pending_request() == nil"),
                    timeout=3.0,
                )
                self.assertEqual("-1", h.expr("bufwinnr('strider://StriderChatCard')"))

    def test_chat_with_range_prefills_pointer(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("1,2StriderChat")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )
                compose_text = "\n".join(h.buffer_lines("strider://compose"))
                self.assertIn("src/main.tsx:1-2", compose_text)

    def test_chat_with_args_does_not_follow_tool_edits(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("edit src/main.tsx")
                h.ex("normal! 2G")

                h.ex("StriderChat update the fixture app")
                h.wait_until(
                    lambda: h.current_state()["buf"] == "strider://compose",
                    timeout=3.0,
                )
                h.send("C-s", pause=0.3)
                h.wait_until(
                    lambda: "Loading fixture app" in (project_root / "src" / "App.tsx").read_text(),
                    timeout=3.0,
                )
                h.wait_until(
                    lambda: "Finished a broader work pass" in "\n".join(h.log_lines()),
                    timeout=3.0,
                )

                state = h.current_state()
                self.assertEqual("strider://compose", state["buf"], state)



if __name__ == "__main__":
    unittest.main()
