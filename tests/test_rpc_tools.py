import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class RpcToolsTests(unittest.TestCase):
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

    def test_path_language_and_tool_result_helpers(self) -> None:
        result = self.run_lua_json(
            """
            local tools = require("strider.rpc.tools")
            print(vim.fn.json_encode({
              absolute = tools.absolute_path({ cwd = "/repo" }, "src/app.lua"),
              already_absolute = tools.absolute_path({ cwd = "/repo" }, "/tmp/app.lua"),
              language = tools.language_for_path("src/App.tsx"),
              text = tools.tool_result_text({
                result = {
                  content = {
                    { type = "text", text = "one" },
                    { type = "image", data = "ignored" },
                    { type = "text", text = "two" },
                  },
                },
              }),
            }))
            """
        )

        self.assertEqual("/repo/src/app.lua", result["absolute"])
        self.assertEqual("/tmp/app.lua", result["already_absolute"])
        self.assertEqual("tsx", result["language"])
        self.assertEqual("one\ntwo", result["text"])

    def test_changed_lines_and_diff_stats_use_tool_diff_details(self) -> None:
        result = self.run_lua_json(
            """
            local tools = require("strider.rpc.tools")
            local diff = table.concat({
              "+ 3 added line",
              "  4 context",
              "- 5 removed line",
              "+ 8 second add",
            }, "\\n")
            print(vim.fn.json_encode({
              changes = tools.changed_lines({
                result = { details = { firstChangedLine = 3, diff = diff } },
              }),
              stats = { tools.diff_stats("@@\\n+new\\n-old\\n+++ b/file\\n--- a/file") },
            }))
            """
        )

        self.assertEqual({"line": 3, "kind": "added"}, result["changes"][0])
        self.assertEqual({"line": 4, "kind": "removed"}, result["changes"][1])
        self.assertEqual({"line": 8, "kind": "added"}, result["changes"][2])
        self.assertEqual([1, 1], result["stats"])


if __name__ == "__main__":
    unittest.main()
