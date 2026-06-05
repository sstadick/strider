import unittest
from pathlib import Path

from tests.support.tmux_nvim import TmuxNvimHarness


class TmuxSearchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]
        self.project_root = self.repo_root / "tests" / "fixtures" / "app"

    def test_search_single_result_opens_picker(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderSearch where is the main entrypoint?")

            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 1)
            state = h.current_state()
            self.assertEqual(1, len(state["qf"]["items"]))
            self.assertIn("Strider Search", state["qf"]["title"])

            picker_label = h.lua("(require('strider.search').picker_items(require('strider.search').last_result_set().results))[1].label")
            self.assertRegex(picker_label, r":\d+-\d+\s{4,}\S")

            log_text = "\n".join(h.flow_log_lines())
            self.assertIn("Strider search: 1 match", log_text)
            self.assertNotIn(":6:1,4,", log_text)

            h.wait_until(lambda: "TelescopeResults" in h.window_filetypes())
            h.send("Enter")

            def jumped_to_main() -> bool:
                state = h.current_state()
                return state["buf"].endswith("src/main.tsx") and state["line"] == 6

            h.wait_until(jumped_to_main)

    def test_search_multiple_results_populates_picker_and_quickfix(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderSearch show all entry roots")

            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 2)
            state = h.current_state()
            self.assertEqual(2, len(state["qf"]["items"]))
            self.assertGreaterEqual(state["wins"], 2)

            if "TelescopeResults" in h.window_filetypes():
                rendered = h.capture_pane()
                self.assertIn("src/main.tsx", rendered)
                self.assertIn("src/App.tsx", rendered)

    def test_search_reopens_log_when_backend_is_already_running(self) -> None:
        with TmuxNvimHarness(self.repo_root, self.project_root) as h:
            h.ex("StriderSearch where is the main entrypoint?")
            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 1)

            # Hide the chat/log surfaces so the next StriderSearch has to
            # reopen the log from scratch. StriderChat toggles; calling
            # it here just to close (no args, both surfaces visible).
            h.ex("StriderChat")
            h.ex("StriderSearch show all entry roots")

            h.wait_until(lambda: "strider://log" in h.json_expr('map(getwininfo(), {_, v -> bufname(v.bufnr)})'))
            h.wait_until(lambda: len(h.current_state()["qf"]["items"]) == 2)

if __name__ == "__main__":
    unittest.main()
