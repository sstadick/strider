import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_recordings.py"


class CheckRecordingsTests(unittest.TestCase):
    def run_script(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *map(str, args)],
            capture_output=True,
            text=True,
            check=check,
        )

    def make_root(self, tmp: str) -> Path:
        root = Path(tmp)
        (root / "recordings" / "vhs").mkdir(parents=True)
        return root

    def test_ok_when_gif_is_newer_than_tape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_root(tmp)
            tape = root / "recordings" / "vhs" / "demo.tape"
            gif = root / "recordings" / "demo.gif"
            tape.write_text("Output .gif recordings/demo.gif\n", encoding="utf-8")
            time.sleep(0.01)
            gif.write_bytes(b"GIF89a")

            result = self.run_script(root)

            self.assertIn("ok", result.stdout)
            self.assertIn("recordings/vhs/demo.tape", result.stdout)

    def test_reports_stale_and_missing_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_root(tmp)
            stale_tape = root / "recordings" / "vhs" / "stale.tape"
            stale_gif = root / "recordings" / "stale.gif"
            stale_gif.write_bytes(b"GIF89a")
            time.sleep(0.01)
            stale_tape.write_text("Output .gif recordings/stale.gif\n", encoding="utf-8")
            missing_tape = root / "recordings" / "vhs" / "missing.tape"
            missing_tape.write_text("Output .gif recordings/missing.gif\n", encoding="utf-8")

            result = self.run_script(root, check=False)

            self.assertEqual(1, result.returncode)
            self.assertIn("stale", result.stdout)
            self.assertIn("missing", result.stdout)

    def test_default_output_path_matches_tape_stem(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.make_root(tmp)
            tape = root / "recordings" / "vhs" / "implicit.tape"
            gif = root / "recordings" / "implicit.gif"
            tape.write_text("Set Shell bash\n", encoding="utf-8")
            time.sleep(0.01)
            gif.write_bytes(b"GIF89a")

            result = self.run_script(root)

            self.assertIn("recordings/implicit.gif", result.stdout)


if __name__ == "__main__":
    unittest.main()
