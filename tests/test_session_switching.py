import json
import os
import time
import unittest
from pathlib import Path

from tests.support.project_copy import FixtureProject
from tests.support.tmux_nvim import TmuxNvimHarness


class SessionSwitchingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def write_session(
        self,
        project_root: Path,
        filename: str,
        session_id: str,
        name: str,
        first_message: str,
        mtime: float,
    ) -> Path:
        pi_dir = project_root / ".pi"
        session_dir = pi_dir / "sessions"
        session_dir.mkdir(parents=True, exist_ok=True)
        (pi_dir / "settings.json").write_text(
            json.dumps({"sessionDir": ".pi/sessions"}),
            encoding="utf-8",
        )
        path = session_dir / filename
        entries = [
            {"id": session_id, "name": name},
            {"type": "message", "message": {"role": "user", "content": first_message}},
            {
                "type": "message",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Saved reply"}],
                },
            },
        ]
        path.write_text("\n".join(json.dumps(entry) for entry in entries) + "\n", encoding="utf-8")
        os.utime(path, (mtime, mtime))
        return path

    def widget_text(self, h: TmuxNvimHarness) -> str:
        return h.lua("table.concat(require('strider.state').get_session().widget or {}, '\\n')")

    def wait_for_session_widget(self, h: TmuxNvimHarness, expected: str) -> None:
        h.wait_until(lambda: expected in self.widget_text(h), timeout=5.0)

    def stub_picker_select_first(self, h: TmuxNvimHarness) -> None:
        h.lua(
            "(function() "
            "  local picker = require('strider.picker'); "
            "  _G._session_picker_title = ''; "
            "  _G._session_picker_labels = {}; "
            "  _G._original_session_picker_select = picker.select; "
            "  picker.select = function(title, items, on_select) "
            "    _G._session_picker_title = title; "
            "    _G._session_picker_labels = vim.tbl_map(function(item) return item.label end, items); "
            "    on_select(items[1]); "
            "    return true; "
            "  end; "
            "  return true "
            "end)()"
        )

    def restore_picker(self, h: TmuxNvimHarness) -> None:
        h.lua(
            "(function() "
            "  local picker = require('strider.picker'); "
            "  if _G._original_session_picker_select then "
            "    picker.select = _G._original_session_picker_select; "
            "  end; "
            "  return true "
            "end)()"
        )

    def test_strider_resume_uses_repo_local_session_id_prefix(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            self.write_session(
                project_root,
                "local-alpha.jsonl",
                "abc1234-local-alpha",
                "Local Alpha",
                "First local prompt",
                time.time(),
            )
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderResume abc1234")
                self.wait_for_session_widget(h, "Local Alpha abc1234")

                log_text = "\n".join(h.log_lines())
                self.assertIn("/resume abc1234", log_text)
                self.assertIn("Resumed session", log_text)

    def test_strider_resume_accepts_repo_local_jsonl_path(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            self.write_session(
                project_root,
                "local-beta.jsonl",
                "def5678-local-beta",
                "Local Beta",
                "Second local prompt",
                time.time(),
            )
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                h.ex("StriderResume .pi/sessions/local-beta.jsonl")
                self.wait_for_session_widget(h, "Local Beta def5678")

                log_text = "\n".join(h.log_lines())
                self.assertIn("/resume .pi/sessions/local-beta.jsonl", log_text)
                self.assertIn("Resumed session", log_text)

    def test_strider_sessions_lists_repo_local_sessions_and_resumes_pick(self) -> None:
        with FixtureProject(self.project_root) as project_root:
            now = time.time()
            self.write_session(
                project_root,
                "older.jsonl",
                "old1111-local",
                "Older Local Session",
                "Older prompt",
                now - 60,
            )
            self.write_session(
                project_root,
                "newer.jsonl",
                "new2222-local",
                "Newer Local Session",
                "Newer prompt",
                now,
            )
            with TmuxNvimHarness(self.repo_root, project_root) as h:
                self.stub_picker_select_first(h)
                try:
                    h.ex("StriderSessions")
                    h.wait_until(
                        lambda: int(h.lua("#(_G._session_picker_labels or {})")) == 2,
                        timeout=5.0,
                    )
                    labels = h.json_expr("luaeval('_G._session_picker_labels')")
                    title = h.lua("tostring(_G._session_picker_title)")
                finally:
                    self.restore_picker(h)

                self.assertEqual("Resume session", title)
                self.assertTrue(any("Newer Local Session" in label for label in labels), labels)
                self.assertTrue(any("Older Local Session" in label for label in labels), labels)
                self.assertIn("Newer Local Session", labels[0], labels)
                self.wait_for_session_widget(h, "Newer Local Session new2222")

                log_text = "\n".join(h.log_lines())
                self.assertIn("/sessions", log_text)
                self.assertIn("select: Resume session", log_text)
                self.assertIn("Resumed session", log_text)


if __name__ == "__main__":
    unittest.main()
