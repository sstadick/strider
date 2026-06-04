#!/usr/bin/env python3
import json
import sys
import threading
import time

from fake_pi_events import (
    assistant_message,
    emit,
    emit_session_start,
    emit_streaming_assistant,
    emit_streaming_thinking,
)
from fake_pi_responses import (
    patch_response,
    plan_response,
    prompt_response,
    prompt_thinking,
    review_response,
    search_response,
)


# Simulated user messages available for forking.
_fork_messages = []
_fork_seq = 0
_chat_read_only = False
_pending_plan_proposal_id = None


def record_user_message(message: str) -> str:
    global _fork_seq
    _fork_seq += 1
    entry_id = f"entry-{_fork_seq}"
    _fork_messages.append({"entryId": entry_id, "text": message})
    return entry_id


def response_with_data(req_id, data: dict, command: str = None) -> dict:
    r: dict = {"id": req_id, "type": "response", "success": True, "data": data}
    if command:
        r["command"] = command
    return r


def response_ok(req_id, command: str = None) -> dict:
    r: dict = {"id": req_id, "type": "response", "success": True}
    if command:
        r["command"] = command
    return r


def response_error(req_id, message: str, command: str = None) -> dict:
    r: dict = {"id": req_id, "type": "response", "success": False, "error": message}
    if command:
        r["command"] = command
    return r


def fork_text(entry_id: str) -> str:
    for msg in _fork_messages:
        if msg["entryId"] == entry_id:
            return msg["text"]
    return ""


def handle_fork(payload: dict) -> None:
    req_id = payload.get("id")
    entry_id = payload.get("entryId")
    if not entry_id:
        emit(response_error(req_id, "fork requires entryId", "fork"))
        return
    emit(response_with_data(req_id, {"text": fork_text(entry_id), "cancelled": False}, "fork"))
    emit_session_start("fork")


def handle_compact(payload: dict) -> None:
    if payload.get("customInstructions") == "__strider_delay__":
        time.sleep(0.8)
    emit(response_with_data(payload.get("id"), {
        "summary": "Compacted.",
        "firstKeptEntryId": None,
        "tokensBefore": 5000,
        "details": {},
    }, "compact"))


def handle_command(payload: dict) -> None:
    cmd_type = payload["type"]
    req_id = payload.get("id")

    if cmd_type == "get_fork_messages":
        emit(response_with_data(req_id, {"messages": list(_fork_messages)}, cmd_type))
    elif cmd_type == "fork":
        handle_fork(payload)
    elif cmd_type == "new_session":
        emit(response_with_data(req_id, {"cancelled": False}, cmd_type))
        emit_session_start("new")
    elif cmd_type == "compact":
        handle_compact(payload)
    elif cmd_type == "export_html":
        emit(response_with_data(req_id, {"path": "/tmp/strider-export.html"}, cmd_type))
    elif cmd_type == "switch_session":
        emit(response_with_data(req_id, {"cancelled": False}, cmd_type))
        emit_session_start("resume")
    elif cmd_type == "get_state":
        emit(response_with_data(req_id, {
            "model": {"id": "fake-model", "name": "Fake Model", "provider": "fake"},
            "isStreaming": False,
            "isCompacting": False,
        }, cmd_type))
    elif cmd_type == "abort":
        emit(response_ok(req_id, cmd_type))
    else:
        emit(response_ok(req_id, cmd_type))


def handle_chat_read_only_command(payload: dict, message: str) -> None:
    global _chat_read_only
    value = message.removeprefix("/strider_chat_read_only").strip().lower()
    if value in ("", "toggle"):
        _chat_read_only = not _chat_read_only
    else:
        _chat_read_only = value in ("on", "true", "1", "enable", "enabled")
    emit(response_ok(payload.get("id"), "prompt"))


def emit_delayed_readonly_write_attempt() -> None:
    time.sleep(0.5)
    if _chat_read_only:
        emit(assistant_message("Blocked edit because Strider chat read-only mode is active"))
    else:
        emit(assistant_message("Write slipped through chat read-only mode"))


def emit_plan_proposal_demo() -> None:
    global _pending_plan_proposal_id
    _pending_plan_proposal_id = "fake-plan-proposal-1"
    emit_streaming_thinking("The request is broad enough that I should propose a small plan before changing files.")
    emit({
        "type": "extension_ui_request",
        "method": "editor",
        "id": _pending_plan_proposal_id,
        "title": "[strider-plan-proposal] Approve plan",
        "prefill": "\n".join([
            "1. Inspect the current greeting flow.",
            "2. Make the smallest scoped change.",
            "3. Report exactly what changed.",
        ]),
    })


def handle_extension_ui_response(payload: dict) -> None:
    global _pending_plan_proposal_id
    if payload.get("id") != _pending_plan_proposal_id:
        emit(response_ok(payload.get("id"), "extension_ui_response"))
        return
    _pending_plan_proposal_id = None
    if payload.get("cancelled"):
        emit(assistant_message("Plan rejected. No changes made."))
        return
    value = payload.get("value") or "(empty plan)"
    emit(assistant_message("Plan accepted from chat compose.\n\nApproved plan:\n" + value))


def handle_prompt(payload: dict) -> None:
    req_id = payload.get("id")
    message = payload.get("message", "")
    if message.startswith("/strider_chat_read_only"):
        handle_chat_read_only_command(payload, message)
        return
    record_user_message(message)
    emit(response_ok(req_id, "prompt"))
    if "__strider_attempt_write_after_readonly__" in message:
        threading.Thread(target=emit_delayed_readonly_write_attempt, daemon=True).start()
    elif "propose a plan before changing files" in message.lower():
        emit_plan_proposal_demo()
    elif message.startswith("/search "):
        emit(assistant_message(search_response(message)))
    elif message.startswith("/review "):
        emit_streaming_thinking("Tracing the active stop and checking the nearby code before explaining it.")
        emit_streaming_assistant(review_response(message))
    elif message.startswith("/plan "):
        emit_streaming_thinking("Scanning the repo for a few useful walkthrough stops before laying out the plan.")
        emit_streaming_assistant(plan_response(message))
    elif message.startswith("/patch "):
        emit(assistant_message(patch_response(message)))
    elif message.startswith(("/sessions", "/resume", "/switch_session")):
        emit_session_start("resume")
    elif message.startswith("/prompt "):
        if "__strider_stream_delay__" in message:
            time.sleep(0.8)
        emit_streaming_thinking(prompt_thinking(message))
        emit(assistant_message(prompt_response(message)))
    else:
        emit(assistant_message("Fake pi response"))


def main() -> int:
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        payload = json.loads(raw)
        cmd_type = payload.get("type", "")
        if cmd_type == "prompt":
            handle_prompt(payload)
        elif cmd_type == "extension_ui_response":
            handle_extension_ui_response(payload)
        elif cmd_type in ("steer", "follow_up"):
            emit(response_ok(payload.get("id"), cmd_type))
            emit(assistant_message("Fake pi response"))
        else:
            handle_command(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
