import json
import sys
import uuid
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def assistant_message(text: str) -> dict:
    return {
        "type": "message_end",
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
        },
    }


def emit_session_start(reason: str) -> None:
    emit({"type": "session_start", "reason": reason})
    emit({
        "type": "extension_ui_request",
        "method": "setStatus",
        "statusKey": "strider-session",
        "statusText": reason,
    })


def emit_streaming_thinking(text: str) -> None:
    """Emit thinking_start/thinking_delta/thinking_end events."""
    if not text:
        return
    emit({
        "type": "message_update",
        "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": ""}]},
        "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0},
    })
    chunk_size = max(len(text) // 3, 1)
    current = ""
    for offset in range(0, len(text), chunk_size):
        delta = text[offset : offset + chunk_size]
        current += delta
        emit({
            "type": "message_update",
            "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": current}]},
            "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": delta},
        })
    emit({
        "type": "message_update",
        "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": text}]},
        "assistantMessageEvent": {"type": "thinking_end", "contentIndex": 0, "content": text},
    })


def emit_streaming_assistant(text: str) -> None:
    """Emit message_update text_delta events followed by message_end."""
    chunk_size = max(len(text) // 3, 1)
    for offset in range(0, len(text), chunk_size):
        delta = text[offset : offset + chunk_size]
        emit({
            "type": "message_update",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": text[: offset + len(delta)]}],
            },
            "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": delta},
        })
    emit(assistant_message(text))


def fixture_path(relative: str) -> str:
    return str((Path.cwd() / relative).resolve())


def project_has(path: str) -> bool:
    return (Path.cwd() / path).exists()


def next_tool_id() -> str:
    return f"tool-{uuid.uuid4()}"


def first_changed_line(before: str, after: str) -> int:
    before_lines = before.splitlines()
    after_lines = after.splitlines()
    limit = min(len(before_lines), len(after_lines))
    for index in range(limit):
        if before_lines[index] != after_lines[index]:
            return index + 1
    return limit + 1


def diff_stub(before: str, after: str, line: int) -> str:
    before_lines = before.splitlines()
    after_lines = after.splitlines()
    index = max(line - 1, 0)
    old = before_lines[index] if index < len(before_lines) else ""
    new = after_lines[index] if index < len(after_lines) else ""
    if old and new:
        return f"-{line} {old}\n+{line} {new}"
    if new:
        return f"+{line} {new}"
    return f"-{line} {old}"


def emit_strider_plan(stops: list, scope: str = "free", base=None) -> None:
    """Emit a strider_plan tool call + end event carrying plan args."""
    tool_id = next_tool_id()
    args = {"scope": scope, "stops": stops}
    if base is not None:
        args["base"] = base
    emit({
        "type": "tool_execution_start",
        "toolName": "strider_plan",
        "toolCallId": tool_id,
        "args": args,
    })
    emit({
        "type": "tool_execution_end",
        "toolName": "strider_plan",
        "toolCallId": tool_id,
        "result": {"content": [{"type": "text", "text": f"ok: {len(stops)} stop(s)"}]},
    })


def emit_read(path: Path, offset: int = 1, limit: int = 20) -> None:
    tool_id = next_tool_id()
    emit({
        "type": "tool_execution_start",
        "toolName": "read",
        "toolCallId": tool_id,
        "args": {"path": str(path), "offset": offset, "limit": limit},
    })
    lines = path.read_text(encoding="utf-8").splitlines()
    snippet = "\n".join(lines[offset - 1: offset - 1 + limit])
    emit({
        "type": "tool_execution_end",
        "toolName": "read",
        "toolCallId": tool_id,
        "result": {"content": [{"type": "text", "text": snippet}]},
    })


def emit_tool_output(tool_name: str, args: dict, text: str) -> None:
    tool_id = next_tool_id()
    emit({"type": "tool_execution_start", "toolName": tool_name, "toolCallId": tool_id, "args": args})
    emit({
        "type": "tool_execution_end",
        "toolName": tool_name,
        "toolCallId": tool_id,
        "result": {"content": [{"type": "text", "text": text}]},
    })


def emit_edit(path: Path, after: str) -> int:
    before = path.read_text(encoding="utf-8")
    changed_line = first_changed_line(before, after)
    tool_id = next_tool_id()
    emit({"type": "tool_execution_start", "toolName": "edit", "toolCallId": tool_id, "args": {"path": str(path)}})
    path.write_text(after, encoding="utf-8")
    emit({
        "type": "tool_execution_end",
        "toolName": "edit",
        "toolCallId": tool_id,
        "result": {"details": {"firstChangedLine": changed_line, "diff": diff_stub(before, after, changed_line)}},
    })
    return changed_line
