#!/usr/bin/env python3
import json
import sys
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


def handle_prompt(payload: dict) -> None:
    req_id = payload.get("id")
    message = payload.get("message", "")
    record_user_message(message)
    emit(response_ok(req_id, "prompt"))
    if message.startswith("/search "):
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
        elif cmd_type in ("steer", "follow_up"):
            emit(response_ok(payload.get("id"), cmd_type))
            emit(assistant_message("Fake pi response"))
        else:
            handle_command(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
