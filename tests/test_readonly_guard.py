import json
import subprocess
import textwrap
import unittest
from pathlib import Path


class ReadOnlyGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo_root = Path(__file__).resolve().parents[1]

    def run_node_json(self, script: str):
        result = subprocess.run(
            ["node", "--input-type=module", "-e", textwrap.dedent(script)],
            cwd=self.repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_chat_read_only_prompt_blocks_writes_without_bash_guard(self) -> None:
        result = self.run_node_json(
            """
            import { isWriteTool, parseChatReadOnlyArg, readOnlyGuard } from './pi/readonly-guard.ts';
            const guard = readOnlyGuard({ activeOperation: 'prompt', chatReadOnly: true });
            console.log(JSON.stringify({
              label: guard?.label,
              blocksBash: guard?.blocksBash,
              edit: isWriteTool('edit'),
              write: isWriteTool('write'),
              bash: isWriteTool('bash'),
              promptWithoutReadonly: readOnlyGuard({ activeOperation: 'prompt', chatReadOnly: false }) ?? null,
              parseOn: parseChatReadOnlyArg('on', false),
              parseOff: parseChatReadOnlyArg('off', true),
              parseToggle: parseChatReadOnlyArg('toggle', false),
            }));
            """
        )
        self.assertEqual("Strider chat read-only mode", result["label"])
        self.assertFalse(result["blocksBash"])
        self.assertTrue(result["edit"])
        self.assertTrue(result["write"])
        self.assertFalse(result["bash"])
        self.assertIsNone(result["promptWithoutReadonly"])
        self.assertTrue(result["parseOn"])
        self.assertFalse(result["parseOff"])
        self.assertTrue(result["parseToggle"])

    def test_plan_review_search_keep_bash_guard(self) -> None:
        result = self.run_node_json(
            """
            import { readOnlyGuard } from './pi/readonly-guard.ts';
            console.log(JSON.stringify(['plan', 'review', 'search'].map((activeOperation) => {
              const guard = readOnlyGuard({ activeOperation });
              return { activeOperation, label: guard?.label, blocksBash: guard?.blocksBash };
            })));
            """
        )
        self.assertEqual(
            [
                {"activeOperation": "plan", "label": "Strider plan mode", "blocksBash": True},
                {"activeOperation": "review", "label": "Strider review mode", "blocksBash": True},
                {"activeOperation": "search", "label": "Strider search mode", "blocksBash": True},
            ],
            result,
        )


if __name__ == "__main__":
    unittest.main()
