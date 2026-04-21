#!/usr/bin/env python3
import json
import re
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
            "content": [
                {
                    "type": "text",
                    "text": text,
                }
            ],
        },
    }


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


def diff_stub(line: int) -> str:
    return f"+ {line} edited" if line > 0 else "+ 1 edited"


def emit_sherpa_plan(stops: list, scope: str = "free", base=None) -> None:
    """Emit a sherpa_plan tool call + end event carrying the plan args.

    Mirrors the shape the real pi extension's sherpa_plan tool produces so
    rpc.lua's handle_tool_end can ingest it without needing the real agent.
    """
    tool_id = next_tool_id()
    args = {"scope": scope, "stops": stops}
    if base is not None:
        args["base"] = base
    emit({
        "type": "tool_execution_start",
        "toolName": "sherpa_plan",
        "toolCallId": tool_id,
        "args": args,
    })
    emit({
        "type": "tool_execution_end",
        "toolName": "sherpa_plan",
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
                "diff": diff_stub(changed_line),
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
    if "pi extension" in lower and project_has("pi/sherpa-stepper.ts"):
        emit_read(Path.cwd() / "pi" / "sherpa-stepper.ts", offset=1, limit=20)
        return "This stop focuses on the pi extension entrypoint and the explicit Sherpa commands it registers."
    if "src/main.tsx" in lower and project_has("src/main.tsx"):
        emit_read(Path.cwd() / "src" / "main.tsx", offset=1, limit=20)
        return "This stop focuses on src/main.tsx because it bootstraps the React app and renders App into the root node."
    if ("repo" in lower or "project" in lower) and project_has("readme.md"):
        emit_read(Path.cwd() / "README.md", offset=1, limit=20)
        return "This stop starts at the top-level README because it explains the plugin surface and how Sherpa is intended to be used."
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
        emit_sherpa_plan(stops, scope="free")
    return "Plan ready."


def prompt_response(message: str) -> str:
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


def main() -> int:
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        payload = json.loads(raw)
        message = payload.get("message", "")
        emit({"type": "response", "success": True})
        if message.startswith("/search "):
            emit(assistant_message(search_response(message)))
        elif message.startswith("/review "):
            emit_streaming_assistant(review_response(message))
        elif message.startswith("/plan "):
            emit_streaming_assistant(plan_response(message))
        elif message.startswith("/patch "):
            emit(assistant_message(patch_response(message)))
        elif message.startswith("/prompt "):
            emit(assistant_message(prompt_response(message)))
        else:
            emit(assistant_message("Fake pi response"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
