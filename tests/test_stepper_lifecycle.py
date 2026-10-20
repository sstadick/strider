"""Zero-provider lifecycle regressions against the actual TypeScript extension.

Requires Node >=22.15 (native type stripping and registerHooks). No installed pi,
npm dependencies, user configuration, Neovim, or fake RPC backend are used.
"""
import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tests" / "support" / "stepper_lifecycle.mjs"
MODES = ("plan", "review", "search")


class StepperLifecycleTests(unittest.TestCase):
    def run_scenario(self, scenario: str, *args: str) -> None:
        # Do not inherit Node preloads that could load user code/configuration.
        env = {key: value for key, value in os.environ.items()
               if key not in {"NODE_OPTIONS", "NODE_PATH"}}
        result = subprocess.run(
            ["node", "--experimental-strip-types", str(HARNESS), scenario, *args],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(
            0, result.returncode,
            f"{scenario} {' '.join(args)}\n{result.stdout}\n{result.stderr}",
        )
        self.assertIn(f"PASS {scenario}", result.stdout)

    def test_each_message_end_preserves_operation_guard_and_tools(self) -> None:
        for mode in MODES:
            for message in ("user", "tool-call", "toolResult", "final", "retry-error", "retry-final", "aborted"):
                with self.subTest(mode=mode, message=message):
                    self.run_scenario("messageBoundary", mode, message)

    def test_agent_end_does_not_release_even_without_retry(self) -> None:
        for mode in MODES:
            for will_retry in ("true", "false"):
                with self.subTest(mode=mode, will_retry=will_retry):
                    self.run_scenario("lowLevelEnd", mode, will_retry)

    def test_tool_and_retry_sequence_keeps_tools_until_settlement(self) -> None:
        for mode in MODES:
            with self.subTest(mode=mode):
                self.run_scenario("retrySequence", mode)

    def test_settlement_releases_success_abort_error_and_accepts_next_request(self) -> None:
        for mode in MODES:
            for outcome in ("success", "abort", "early-abort", "error", "no-message"):
                with self.subTest(mode=mode, outcome=outcome):
                    self.run_scenario("settlement", mode, outcome)

    def test_chat_read_only_setting_is_independent_of_operation_cleanup(self) -> None:
        self.run_scenario("chatReadOnly")

    def test_per_message_cost_and_widget_updates_are_preserved(self) -> None:
        self.run_scenario("costAndWidgets")


if __name__ == "__main__":
    unittest.main()
