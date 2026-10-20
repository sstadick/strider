"""No-model regression tests for pi's message-versus-run completion boundaries."""
import json
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class RpcLifecycleTests(unittest.TestCase):
    def run_lua(self, source):
        root = Path(__file__).resolve().parents[1]
        script = (
            f"vim.opt.rtp:prepend({json.dumps(str(root))})\n"
            f"local h = dofile({json.dumps(str(root / 'tests/support/rpc_lifecycle.lua'))})\n"
            + textwrap.dedent(source)
            + "\nprint('PASS')\nvim.cmd('qa!')\n"
        )
        with tempfile.TemporaryDirectory(prefix="strider-lifecycle-") as directory:
            path = Path(directory) / "test.lua"
            path.write_text(script)
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-l", str(path)],
                cwd=directory, capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn("PASS", result.stdout + result.stderr)

    def test_plan_dispatch_waits_for_settlement_not_final_message(self):
        self.run_lua("""
            local emit = h.start('review', 'plan')
            emit({ type = 'message_end', message = { role = 'user', content = 'plan' } })
            assert(h.state.peek_pending_request('review'))
            emit(h.message('Here is the plan.'))
            assert(h.state.peek_pending_request('review'), 'message_end released plan too early')
            assert(h.count('append_block') == 1, 'final text should render immediately')
            assert(h.count('finish_activity') == 0)
            assert(h.count('dispatch_review') == 0)
            emit({ type = 'agent_end', willRetry = false })
            assert(h.count('dispatch_review') == 0, 'agent_end is not settlement')
            emit({ type = 'agent_settled', aborted = false })
            assert(not h.state.peek_pending_request('review'))
            assert(h.count('dispatch_review') == 1)
            assert(h.count('append_block') == 1, 'settlement must not duplicate text')
            emit({ type = 'agent_settled', aborted = false })
            assert(h.count('dispatch_review') == 1, 'duplicate settlement is a no-op')
        """)

    def test_retry_keeps_q_running_until_successful_settlement(self):
        self.run_lua("""
            local emit = h.start('q', 'q')
            local failed = h.message(nil, 'error')
            failed.message.errorMessage = '529 overloaded'
            emit(failed)
            emit({ type = 'agent_end', willRetry = true })
            emit({ type = 'auto_retry_start', attempt = 1 })
            assert(h.state.peek_pending_request('q'), 'retry released request')
            assert(h.count('finish_q_answer') == 0)
            assert(h.count('finish_activity') == 0)
            emit({ type = 'message_update', assistantMessageEvent = {
                type = 'text_delta', contentIndex = 0, delta = 'Recovered answer',
            } })
            assert(h.last('update_q_answer')[1] == 'Recovered answer')
            emit(h.message('Recovered answer'))
            emit({ type = 'agent_end', willRetry = false })
            assert(h.count('finish_q_answer') == 0)
            emit({ type = 'agent_settled', aborted = false })
            assert(not h.state.peek_pending_request('q'))
            assert(h.last('finish_q_answer')[1] == 'Recovered answer')
            assert(h.last('finish_q_answer')[2] == 'success')
            assert(not h.state.get_session('q').last_error)
            assert(h.count('notify_flow_done') == 1)
        """)

    def test_terminal_error_and_abort_finish_once(self):
        for outcome in ("error", "aborted", "early_abort"):
            with self.subTest(outcome=outcome):
                self.run_lua(f"""
                    local emit = h.start('patch', 'patch')
                    local outcome = {json.dumps(outcome)}
                    if outcome ~= 'early_abort' then
                        local failed = h.message(nil, outcome)
                        failed.message.errorMessage = 'Request failed'
                        emit(failed)
                        assert(h.state.peek_pending_request('patch'))
                        assert(h.count('finish_patch_summary') == 0)
                    end
                    emit({{ type = 'agent_settled', aborted = outcome ~= 'error' }})
                    assert(not h.state.peek_pending_request('patch'))
                    assert(h.count('finish_patch_summary') == 1)
                    assert(h.last('finish_patch_summary')[2] ==
                        (outcome == 'error' and 'error' or 'cancelled'))
                    assert(h.count('append_block') == 1, 'error should appear once')
                    emit({{ type = 'agent_settled', aborted = false }})
                    assert(h.count('finish_patch_summary') == 1)
                """)

    def test_failed_partial_tool_call_is_not_a_successful_tool_only_run(self):
        self.run_lua("""
            local emit = h.start('q', 'q')
            local failed = h.message(nil, 'error')
            failed.message.content = { { type = 'toolCall', name = 'read' } }
            failed.message.errorMessage = 'Stream interrupted during tool arguments'
            emit(failed)
            assert(h.state.peek_pending_request('q'))
            assert(h.last('append_block')[2] == failed.message.errorMessage)
            assert(h.count('finish_q_answer') == 0)
            emit({ type = 'agent_settled', aborted = false })
            assert(h.last('finish_q_answer')[2] == 'error')
            assert(h.state.get_session('q').last_error == failed.message.errorMessage)
            assert(h.count('append_block') == 1)
            assert(h.count('notify_flow_done') == 0)
        """)

    def test_tool_only_plan_and_lane_isolation(self):
        self.run_lua("""
            local emit = h.start('review', 'plan')
            h.start('q', 'q')
            local tool_call = h.message(nil, 'toolUse')
            tool_call.message.content = { { type = 'toolCall', name = 'strider_plan' } }
            emit(tool_call)
            emit({ type = 'message_end', message = {
                role = 'toolResult', content = { { type = 'text', text = 'Plan stored' } },
            } })
            assert(h.state.peek_pending_request('review'))
            emit({ type = 'agent_settled', aborted = false })
            assert(not h.state.peek_pending_request('review'))
            assert(h.state.peek_pending_request('q'), 'other lane must stay busy')
            assert(h.count('dispatch_review') == 1, 'tool-only plan must complete')
        """)

    def test_review_summary_and_search_finish_only_when_settled(self):
        self.run_lua("""
            h.awaiting_summary = true
            local emit = h.start('review', 'review')
            emit(h.message('Review complete'))
            assert(h.count('complete_summary') == 0)
            emit({ type = 'agent_settled', aborted = false })
            assert(h.last('complete_summary')[1] == 'Review complete')
            local search = h.start('flow', 'search')
            search(h.message('results'))
            assert(h.count('search') == 0)
            search({ type = 'agent_settled', aborted = false })
            assert(h.last('search')[1] == 'results')
            assert(h.state.get_session('flow').last_summary == 'Search: results')
        """)

    def test_raw_commands_and_startup_errors_do_not_wait_for_settlement(self):
        self.run_lua("""
            local emit = h.start('main', 'command')
            emit({ type = 'response', success = true, command = 'compact' })
            assert(not h.state.peek_pending_request('main'))
            h.state.set_pending_request('plan', {}, 'main')
            emit({ type = 'extension_error', error = 'No model configured' })
            assert(not h.state.peek_pending_request('main'))
            h.state.set_pending_request('prompt', {}, 'main')
            emit({ type = 'response', success = false, command = 'prompt', error = 'Rejected' })
            assert(not h.state.peek_pending_request('main'))
        """)


if __name__ == "__main__":
    unittest.main()
