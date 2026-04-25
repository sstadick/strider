import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class ReviewRenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]

    def run_lua_json(self, lua: str):
        script = (
            f"vim.opt.rtp:prepend({json.dumps(str(self.repo_root))})\n"
            + textwrap.dedent(lua)
            + "\nvim.cmd('qa')\n"
        )
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as handle:
            handle.write(script)
            script_path = Path(handle.name)
        try:
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-l", str(script_path)],
                capture_output=True,
                text=True,
                check=True,
            )
        finally:
            script_path.unlink(missing_ok=True)

        raw = result.stdout.strip() or result.stderr.strip()
        output = raw.splitlines()
        self.assertTrue(output, result.stderr)
        return json.loads(output[-1])

    def test_panel_lines_render_current_stop_without_review_state(self) -> None:
        lines = self.run_lua_json(
            """
            local render = require("sherpa.review.render")
            local cwd = "/tmp/sherpa-render"
            local path = cwd .. "/src/app.lua"
            local review = {
              active = true,
              source = "review",
              goal = "Find issues",
              current_index = 1,
              scope = "free",
              items = {
                {
                  id = "one",
                  path = path,
                  startLine = 10,
                  endLine = 20,
                  title = "Defines run",
                  summary = "Short summary.",
                  why = "Detailed reason.",
                  excerpt = "local function run()\\nend",
                  status = "accepted",
                },
              },
              comments = {
                {
                  itemId = "one",
                  path = path,
                  startLine = 12,
                  endLine = 13,
                  text = "Check edge cases.",
                },
              },
            }
            print(vim.fn.json_encode(render.panel_lines(review, { cwd = cwd })))
            """
        )

        text = "\n".join(lines)
        self.assertIn("- accepted: `1/1`", text)
        self.assertIn("`src/app.lua:10-20`", text)
        self.assertIn("Status: accepted", text)
        self.assertIn("Synopsis: Short summary.", text)
        self.assertIn("Why: Detailed reason.", text)
        self.assertIn("```lua", text)
        self.assertIn("1. lines 12-13", text)

    def test_panel_lines_message_zero_hides_item_only_sections(self) -> None:
        lines = self.run_lua_json(
            """
            local render = require("sherpa.review.render")
            local review = {
              active = true,
              source = "review",
              current_index = 0,
              plan_message = "Read the entry point first.",
              items = {
                {
                  id = "one",
                  path = "/tmp/sherpa-render/src/app.lua",
                  startLine = 1,
                  endLine = 4,
                  title = "Entry point",
                  excerpt = "local function main()\\nend",
                },
              },
              comments = {
                { itemId = "one", startLine = 1, endLine = 1, text = "Hidden on synopsis." },
              },
            }
            print(vim.fn.json_encode(render.panel_lines(review, {})))
            """
        )

        text = "\n".join(lines)
        self.assertIn("- stop: `0/1`", text)
        self.assertIn("## Synopsis", text)
        self.assertIn("Read the entry point first.", text)
        self.assertIn("[0] Synopsis", text)
        self.assertNotIn("Comments on this item", text)
        self.assertNotIn("## Excerpt", text)

    def test_completed_review_renders_final_next_actions(self) -> None:
        lines = self.run_lua_json(
            """
            local render = require("sherpa.review.render")
            local review = {
              active = false,
              source = "review",
              goal = "Find issues",
              current_index = 1,
              scope = "free",
              summary = "Review complete. No unresolved comments.",
              summary_forwarded = true,
              items = {
                {
                  id = "one",
                  path = "/tmp/sherpa-render/src/app.lua",
                  startLine = 10,
                  endLine = 20,
                  title = "Defines run",
                  summary = "Short summary.",
                  why = "Detailed reason.",
                  status = "accepted",
                },
              },
              comments = {},
            }
            print(vim.fn.json_encode(render.panel_lines(review, { cwd = "/tmp/sherpa-render" })))
            """
        )

        text = "\n".join(lines)
        self.assertIn("# Sherpa Review Complete", text)
        self.assertIn("- state: `complete`", text)
        self.assertIn("- summary: `forwarded to main chat`", text)
        self.assertIn("## Review summary", text)
        self.assertIn("## Next actions", text)
        self.assertIn(":SherpaLogReview", text)
        self.assertNotIn("## Controls", text)

    def test_chunk_title_and_item_label_are_exposed_for_review_state(self) -> None:
        result = self.run_lua_json(
            """
            local render = require("sherpa.review.render")
            local item = {
              path = "/tmp/sherpa-render/src/app.lua",
              startLine = 2,
              endLine = 8,
              title = "Entry point",
              status = "accepted",
            }
            print(vim.fn.json_encode({
              import = render.chunk_title("", "fallback", "import thing from './thing'"),
              declaration = render.chunk_title("", "fallback", "local function build()"),
              fallback = render.chunk_title("", "fallback", "\\n# comment\\n"),
              label = render.item_label(item, 1, 3),
            }))
            """
        )

        self.assertEqual("Imports and setup", result["import"])
        self.assertEqual("Defines build", result["declaration"])
        self.assertEqual("fallback", result["fallback"])
        self.assertIn("[1/3]", result["label"])
        self.assertIn("[accepted]", result["label"])


if __name__ == "__main__":
    unittest.main()
