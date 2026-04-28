import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class VimExecTests(unittest.TestCase):
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

    def exec_chunk(self, chunk: str):
        return self.run_lua_json(
            f"""
            local exec = require("strider.vim_exec")
            print(exec.exec({json.dumps(chunk)}))
            """
        )

    def test_exec_returns_json_value_from_live_neovim(self) -> None:
        result = self.exec_chunk(
            "return { cwd = vim.fn.getcwd(), buf = vim.api.nvim_get_current_buf() }"
        )

        self.assertTrue(result["ok"])
        self.assertEqual(str(self.repo_root), result["value"]["cwd"])
        self.assertIsInstance(result["value"]["buf"], int)

    def test_exec_can_mutate_live_neovim_state(self) -> None:
        result = self.exec_chunk(
            "vim.g.strider_vim_exec_test = 'changed'; return vim.g.strider_vim_exec_test"
        )

        self.assertEqual({"ok": True, "value": "changed"}, result)

    def test_exec_reports_load_and_runtime_errors(self) -> None:
        load_error = self.exec_chunk("return {")
        runtime_error = self.exec_chunk("error('boom')")

        self.assertFalse(load_error["ok"])
        self.assertEqual("load", load_error["phase"])
        self.assertIn("unexpected", load_error["error"].lower())
        self.assertFalse(runtime_error["ok"])
        self.assertEqual("execute", runtime_error["phase"])
        self.assertIn("boom", runtime_error["error"])

    def test_exec_inspects_values_that_json_cannot_encode(self) -> None:
        result = self.exec_chunk("return function() end")

        self.assertTrue(result["ok"])
        self.assertTrue(result["inspected"])
        self.assertIn("function", result["value"])


if __name__ == "__main__":
    unittest.main()
