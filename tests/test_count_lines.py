import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "count_lines.py"


class CountLinesTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *map(str, args)],
            capture_output=True,
            text=True,
            check=True,
        )

    def test_lines_counts_python_files_in_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "keep.lua").write_text("a\nb\nc\n", encoding="utf-8")
            (root / "count.py").write_text("1\n2\n3\n4\n", encoding="utf-8")

            result = self.run_script("lines", root)

            self.assertIn("keep.lua", result.stdout)
            self.assertIn("count.py", result.stdout)
            self.assertIn("     7  total lines", result.stdout)

    def test_python_file_is_counted_for_lines_and_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "count.py"
            content = "print('a')\nprint('b')\n"
            path.write_text(content, encoding="utf-8")

            lines_result = self.run_script("lines", path)
            bytes_result = self.run_script("bytes", path)

            self.assertIn("count.py", lines_result.stdout)
            self.assertIn("     2  total lines", lines_result.stdout)
            self.assertIn("count.py", bytes_result.stdout)
            self.assertIn(f"{len(content.encode('utf-8')):>6}  total bytes", bytes_result.stdout)

    def test_default_lines_command_counts_python_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "count.py"
            path.write_text("x\ny\nz\n", encoding="utf-8")

            result = self.run_script(path)

            self.assertIn("count.py", result.stdout)
            self.assertIn("     3  total lines", result.stdout)

    def test_default_lines_command_counts_python_files_in_directories(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nested = root / "nested"
            nested.mkdir()
            (nested / "count.py").write_text("1\n2\n", encoding="utf-8")
            (nested / "count.lua").write_text("a\nb\nc\n", encoding="utf-8")

            result = self.run_script(root)

            self.assertIn("nested/count.py", result.stdout)
            self.assertIn("nested/count.lua", result.stdout)
            self.assertIn("     5  total lines", result.stdout)

    def test_lines_still_skips_ignored_directories_with_python_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ignored = root / "__pycache__"
            ignored.mkdir()
            (root / "count.py").write_text("1\n2\n", encoding="utf-8")
            (ignored / "ignored.py").write_text("a\nb\nc\n", encoding="utf-8")

            result = self.run_script("lines", root)

            self.assertIn("count.py", result.stdout)
            self.assertNotIn("ignored.py", result.stdout)
            self.assertIn("     2  total lines", result.stdout)

    def test_lines_skips_generated_workspaces_and_binary_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            generated = root / "recordings" / "_workspace" / "demo"
            generated.mkdir(parents=True)
            cache = root / "tests" / ".nvim-cache"
            cache.mkdir(parents=True)

            (root / "source.lua").write_text("return true\n", encoding="utf-8")
            (root / ".DS_Store").write_text("ignored\n", encoding="utf-8")
            (root / "nvim.log").write_text("ignored\n", encoding="utf-8")
            (root / "demo.gif").write_bytes(b"GIF89a\nnot a text file\n")
            (generated / "app.py").write_text("ignored\n", encoding="utf-8")
            (cache / "state.lua").write_text("ignored\n", encoding="utf-8")

            result = self.run_script("lines", root)

            self.assertIn("source.lua", result.stdout)
            self.assertNotIn(".DS_Store", result.stdout)
            self.assertNotIn("nvim.log", result.stdout)
            self.assertNotIn("demo.gif", result.stdout)
            self.assertNotIn("recordings/_workspace", result.stdout)
            self.assertNotIn(".nvim-cache", result.stdout)
            self.assertIn("     1  total lines", result.stdout)


if __name__ == "__main__":
    unittest.main()
