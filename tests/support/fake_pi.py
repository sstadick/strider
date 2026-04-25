#!/usr/bin/env python3
import json
import re
import sys
import time
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
            "content": [
                {
                    "type": "text",
                    "text": text,
                }
            ],
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
        "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": ""}],
        },
        "assistantMessageEvent": {
            "type": "thinking_start",
            "contentIndex": 0,
        },
    })
    chunk_size = max(len(text) // 3, 1)
    current = ""
    for offset in range(0, len(text), chunk_size):
        delta = text[offset : offset + chunk_size]
        current += delta
        emit({
            "type": "message_update",
            "message": {
                "role": "assistant",
                "content": [{"type": "thinking", "thinking": current}],
            },
            "assistantMessageEvent": {
                "type": "thinking_delta",
                "contentIndex": 0,
                "delta": delta,
            },
        })
    emit({
        "type": "message_update",
        "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": text}],
        },
        "assistantMessageEvent": {
            "type": "thinking_end",
            "contentIndex": 0,
            "content": text,
        },
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
            "assistantMessageEvent": {
                "type": "text_delta",
                "contentIndex": 0,
                "delta": delta,
            },
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
    """Emit a strider_plan tool call + end event carrying the plan args.

    Mirrors the shape the real pi extension's strider_plan tool produces so
    rpc.lua's handle_tool_end can ingest it without needing the real agent.
    """
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
        "args": {
            "path": str(path),
            "offset": offset,
            "limit": limit,
        },
    })
    lines = path.read_text(encoding="utf-8").splitlines()
    snippet = "\n".join(lines[offset - 1: offset - 1 + limit])
    emit({
        "type": "tool_execution_end",
        "toolName": "read",
        "toolCallId": tool_id,
        "result": {
            "content": [{"type": "text", "text": snippet}],
        },
    })


def emit_tool_output(tool_name: str, args: dict, text: str) -> None:
    tool_id = next_tool_id()
    emit({
        "type": "tool_execution_start",
        "toolName": tool_name,
        "toolCallId": tool_id,
        "args": args,
    })
    emit({
        "type": "tool_execution_end",
        "toolName": tool_name,
        "toolCallId": tool_id,
        "result": {
            "content": [{"type": "text", "text": text}],
        },
    })


def emit_edit(path: Path, after: str) -> int:
    before = path.read_text(encoding="utf-8")
    changed_line = first_changed_line(before, after)
    tool_id = next_tool_id()
    emit({
        "type": "tool_execution_start",
        "toolName": "edit",
        "toolCallId": tool_id,
        "args": {
            "path": str(path),
        },
    })
    path.write_text(after, encoding="utf-8")
    emit({
        "type": "tool_execution_end",
        "toolName": "edit",
        "toolCallId": tool_id,
        "result": {
            "details": {
                "firstChangedLine": changed_line,
                "diff": diff_stub(before, after, changed_line),
            },
        },
    })
    return changed_line


def search_response(message: str) -> str:
    prompt = message[len("/search "):].lower()
    if project_has("src/main.tsx"):
        if "all" in prompt or "multiple" in prompt or "roots" in prompt:
            return "\n".join(
                [
                    f"{fixture_path('src/main.tsx')}:6:1,4,Main React entrypoint; mounts App into #root",
                    f"{fixture_path('src/App.tsx')}:1:1,6,Top-level app component rendered from main.tsx",
                ]
            )
        return f"{fixture_path('src/main.tsx')}:6:1,4,Main React entrypoint; mounts App into #root"

    if project_has("main.py"):
        return f"{fixture_path('main.py')}:4:1,6,Primary Python entrypoint; calls greet() and run() from main()"

    return ""


def review_response(message: str) -> str:

    lower = message.lower()
    if "<review_comments>" in lower:
        return "I found unresolved review comments. The main follow-up is to clarify the reviewed code and keep the intent documented."
    if "pi extension" in lower and project_has("pi/strider-stepper.ts"):
        emit_read(Path.cwd() / "pi" / "strider-stepper.ts", offset=1, limit=20)
        return "This stop focuses on the pi extension entrypoint and the explicit Strider commands it registers."
    if "src/main.tsx" in lower and project_has("src/main.tsx"):
        emit_read(Path.cwd() / "src" / "main.tsx", offset=1, limit=20)
        return "This stop focuses on src/main.tsx because it bootstraps the React app and renders App into the root node."
    if ("repo" in lower or "project" in lower) and project_has("readme.md"):
        emit_read(Path.cwd() / "README.md", offset=1, limit=20)
        return "This stop starts at the top-level README because it explains the plugin surface and how Strider is intended to be used."
    if "main.py" in lower or "greet" in lower:
        if project_has("main.py"):
            emit_read(Path.cwd() / "main.py", offset=1, limit=20)
        return "This review item shows the main Python flow. It wires the entrypoint through main(), formats the greeting, and then calls run()."
    if "app.py" in lower:
        if project_has("app.py"):
            emit_read(Path.cwd() / "app.py", offset=1, limit=20)
        return "This review item focuses on the small helper and the file-writing function. The key thing to notice is the pure greeting helper versus the side-effecting run() call."
    if project_has("src/main.tsx"):
        emit_read(Path.cwd() / "src" / "main.tsx", offset=1, limit=20)
    return "This range is part of the current review. It is the main place where the app bootstraps or where the selected code is being discussed."


def patch_response(message: str) -> str:
    match = re.search(r"Patch target file: (.+)", message)
    if not match:
        return "Applied the requested local patch."
    path = Path(match.group(1).strip())
    emit_read(path)
    contents = path.read_text(encoding="utf-8")
    if "hi," in contents:
        updated = contents.replace("hi,", "hello,", 1)
    elif "Hello from fixture app" in contents:
        updated = contents.replace("Hello from fixture app", "Hello from patched fixture app", 1)
    else:
        updated = contents + "\n# patched by fake pi\n"
    emit_edit(path, updated)
    return "Applied the requested local patch."


def plan_response(message: str) -> str:
    """Pick a couple of plausible stops from the project for the plan tool."""
    stops: list = []
    if project_has("src/main.tsx"):
        stops.append({
            "path": fixture_path("src/main.tsx"),
            "startLine": 1,
            "endLine": 6,
            "firstLineText": 'import React from "react"',
            "title": "main.tsx entry",
            "why": "React entrypoint — where the app is bootstrapped.",
            "summary": "The React bootstrap. Creates the DOM root and mounts App into #root.",
            "explanation": "This file is the React bootstrap. It creates the root via ReactDOM and mounts the App component into the #root element. Standard Vite/React entrypoint pattern — short, functional, no surprises.",
            "annotations": [
                {"kind": "line", "line": 1, "text": "React + ReactDOM imports"},
            ],
        })
        if project_has("src/App.tsx"):
            stops.append({
                "path": fixture_path("src/App.tsx"),
                "startLine": 1,
                "endLine": 3,
                "firstLineText": "export function App() {",
                "title": "App component",
                "why": "Top-level UI component rendered by main.",
                "summary": "Top-level App component rendered by main.tsx.",
                "explanation": "The top-level App component. Renders the application UI surface. This is what main.tsx mounts.",
            })
    elif project_has("app.py"):
        stops.append({
            "path": fixture_path("app.py"),
            "startLine": 1,
            "endLine": 5,
            "firstLineText": "from pathlib import Path",
            "title": "app greeting",
            "why": "Pure greeting helper at the top of the file.",
            "summary": "Pure greeting helper used by the entrypoint.",
            "explanation": "A pure helper that formats a greeting string. No side effects. Used by the main entrypoint.",
        })
    elif project_has("wide.txt"):
        stops.append({
            "path": fixture_path("wide.txt"),
            "startLine": 1,
            "endLine": 5,
            "firstLineText": "line 1",
            "title": "top of wide.txt",
            "why": "First section of the fixture.",
            "summary": "Opening section of the test fixture file.",
            "explanation": "Opening section of the test fixture file. Used to exercise the review pane's rendering for long-line content.",
        })
    if stops:
        emit_strider_plan(stops, scope="free")
    return "Plan ready."


def prompt_thinking(_message: str) -> str:
    return "Checking the relevant files first, then making the smallest useful edit before summarizing the change."


def prompt_response(message: str) -> str:
    if "compact tool output" in message.lower():
        emit_tool_output(
            "grep",
            {"pattern": "fixture", "path": "src"},
            "# heading-like output\nsrc/App.tsx:1:export function App() {",
        )
        return "Finished compact tool output pass."

    if "tool argument headers" in message.lower():
        emit_tool_output(
            "grep",
            {"pattern": "fixture", "path": "src", "glob": "*.tsx", "limit": 5},
            "src/App.tsx:1:export function App() {",
        )
        emit_tool_output(
            "find",
            {"pattern": "*.lua", "path": "lua/strider", "limit": 3},
            "lua/strider/rpc.lua\nlua/strider/ui.lua",
        )
        emit_tool_output(
            "ls",
            {"path": "lua/strider", "limit": 2},
            "rpc.lua\nui.lua",
        )
        return "Finished tool argument header pass."

    if project_has("src/App.tsx"):
        path = Path.cwd() / "src" / "App.tsx"
        emit_read(path)
        contents = path.read_text(encoding="utf-8")
        if "Loading fixture app" not in contents:
            updated = contents.replace("Hello from fixture app", "Loading fixture app", 1)
            emit_edit(path, updated)
        return "Finished a broader work pass. The main thing to review next is the updated app surface in src/App.tsx."

    if project_has("app.py"):
        path = Path.cwd() / "app.py"
        emit_read(path)
        contents = path.read_text(encoding="utf-8")
        updated = contents.replace("hi,", "hello,", 1) if "hi," in contents else contents
        if updated != contents:
            emit_edit(path, updated)
        return "Finished a broader work pass. The main thing to review next is the greeting helper in app.py."

    return "Finished a broader work pass."




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


def handle_command(payload: dict) -> None:
    cmd_type = payload["type"]
    req_id = payload.get("id")

    if cmd_type == "get_fork_messages":
        emit(response_with_data(req_id, {"messages": list(_fork_messages)}, cmd_type))
        return

    if cmd_type == "fork":
        entry_id = payload.get("entryId")
        if not entry_id:
            emit(response_error(req_id, "fork requires entryId", cmd_type))
            return
        text = ""
        for msg in _fork_messages:
            if msg["entryId"] == entry_id:
                text = msg["text"]
                break
        emit(response_with_data(req_id, {"text": text, "cancelled": False}, cmd_type))
        emit_session_start("fork")
        return

    if cmd_type == "new_session":
        emit(response_with_data(req_id, {"cancelled": False}, cmd_type))
        emit_session_start("new")
        return

    if cmd_type == "compact":
        if payload.get("customInstructions") == "__strider_delay__":
            time.sleep(0.8)
        emit(response_with_data(req_id, {
            "summary": "Compacted.",
            "firstKeptEntryId": None,
            "tokensBefore": 5000,
            "details": {},
        }, cmd_type))
        return

    if cmd_type == "export_html":
        emit(response_with_data(req_id, {"path": "/tmp/strider-export.html"}, cmd_type))
        return

    if cmd_type == "switch_session":
        emit(response_with_data(req_id, {"cancelled": False}, cmd_type))
        emit_session_start("resume")
        return

    if cmd_type == "get_state":
        emit(response_with_data(req_id, {
            "model": {"id": "fake-model", "name": "Fake Model", "provider": "fake"},
            "isStreaming": False,
            "isCompacting": False,
        }, cmd_type))
        return

    if cmd_type == "abort":
        emit(response_ok(req_id, cmd_type))
        return

    # Unknown command — still succeed so we don't break the protocol.
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
            # Steering / follow-up: ack and echo.
            emit(response_ok(payload.get("id"), cmd_type))
            emit(assistant_message("Fake pi response"))
        else:
            handle_command(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
