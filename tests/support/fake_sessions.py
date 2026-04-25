from __future__ import annotations

import json
import re
import uuid
from pathlib import Path
from typing import Callable

Emit = Callable[[dict], None]


def collapse_whitespace(text) -> str:
    if text is None:
        return ""
    if not isinstance(text, str):
        text = json.dumps(text)
    return re.sub(r"\s+", " ", text).strip()


def message_text(message: dict) -> str:
    content = message.get("content", "")
    if isinstance(content, str):
        return collapse_whitespace(content)
    if isinstance(content, list):
        parts = [part.get("text", "") for part in content if isinstance(part, dict)]
        return collapse_whitespace(" ".join(parts))
    return collapse_whitespace(content)


def short_session_id(session_id: str) -> str:
    return (session_id or "")[:7]


def looks_like_path(value: str) -> bool:
    return (
        value.startswith((".", "/", "~"))
        or "/" in value
        or "\\" in value
        or value.endswith(".jsonl")
        or re.match(r"^[A-Za-z]:[\\/]", value) is not None
    )


def resolve_path(value: str) -> Path:
    if value == "~" or value.startswith("~/"):
        home = Path.home()
        return home if value == "~" else home / value[2:]
    path = Path(value)
    return path if path.is_absolute() else Path.cwd() / path


class SessionSwitchingFake:
    def __init__(self, emit: Emit, emit_session_start: Callable[[str], None]) -> None:
        self.emit = emit
        self.emit_session_start = emit_session_start
        self.pending_selects: dict[str, dict[str, dict]] = {}
        self.current_session_id = None

    def session_record(self, path: Path) -> dict:
        session_id = path.stem
        name = ""
        first_message = ""
        message_count = 0
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not raw.strip():
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            session_id = entry.get("id") or entry.get("sessionId") or session_id
            name = entry.get("name") or entry.get("sessionName") or name
            message = entry.get("message") if entry.get("type") == "message" else None
            if isinstance(message, dict):
                message_count += 1
                if not first_message and message.get("role") == "user":
                    first_message = message_text(message)
        title = collapse_whitespace(name) or first_message or path.name
        return {
            "id": session_id,
            "path": str(path.resolve()),
            "title": title,
            "messageCount": message_count,
            "modified": path.stat().st_mtime,
        }

    def local_sessions(self) -> list[dict]:
        session_dir = Path.cwd() / ".pi" / "sessions"
        if not session_dir.exists():
            return []
        sessions = [self.session_record(path) for path in session_dir.glob("*.jsonl")]
        return sorted(sessions, key=lambda item: item["modified"], reverse=True)

    def session_label(self, record: dict) -> str:
        marker = "●" if record["id"] == self.current_session_id else " "
        count = record["messageCount"]
        count_label = f"{count} {'msg' if count == 1 else 'msgs'}"
        title = record["title"][:32].ljust(32)
        return f"{marker} Today 00:00  {title} {short_session_id(record['id']).ljust(7)} {count_label}"

    def emit_notify(self, message: str, notify_type: str = "info") -> None:
        self.emit({
            "type": "extension_ui_request",
            "method": "notify",
            "message": message,
            "notifyType": notify_type,
        })

    def emit_session_widget(self, record: dict) -> None:
        self.emit({
            "type": "extension_ui_request",
            "method": "setWidget",
            "widgetLines": [f"Session: {record['title']} {short_session_id(record['id'])}"],
        })

    def resume_record(self, record: dict) -> None:
        self.current_session_id = record["id"]
        self.emit_session_start("resume")
        self.emit_session_widget(record)
        self.emit_notify(f"Resumed session {record['title']} {short_session_id(record['id'])}")

    def browse_sessions(self) -> None:
        sessions = self.local_sessions()
        if not sessions:
            self.emit_notify("No saved sessions found", "warning")
            return
        select_id = f"select-{uuid.uuid4()}"
        labels = [self.session_label(record) for record in sessions]
        self.pending_selects[select_id] = dict(zip(labels, sessions))
        self.emit({
            "type": "extension_ui_request",
            "id": select_id,
            "method": "select",
            "title": "Resume session",
            "options": labels,
        })

    def resume_by_input(self, raw_input: str) -> None:
        value = raw_input.strip()
        if not value:
            self.browse_sessions()
            return
        if looks_like_path(value):
            path = resolve_path(value)
            if not path.exists():
                self.emit_notify(f"Session file not found: {path}", "error")
                return
            self.resume_record(self.session_record(path))
            return

        matches = [record for record in self.local_sessions() if record["id"].startswith(value)]
        if len(matches) == 1:
            self.resume_record(matches[0])
        elif len(matches) > 1:
            ids = ", ".join(short_session_id(record["id"]) for record in matches[:5])
            self.emit_notify(f"Multiple sessions match {value}: {ids}", "warning")
        else:
            self.emit_notify(f"No saved sessions match: {value}", "warning")

    def handle_prompt(self, message: str) -> None:
        if message in {"/sessions", "/resume"}:
            self.browse_sessions()
        elif message.startswith("/resume "):
            self.resume_by_input(message[len("/resume "):])
        elif message.startswith("/switch_session "):
            self.resume_by_input(message[len("/switch_session "):])
        else:
            self.emit_notify(f"Unknown session command: {message}", "warning")

    def handle_ui_response(self, payload: dict) -> None:
        choices = self.pending_selects.pop(payload.get("id"), None)
        if not choices or payload.get("cancelled"):
            return
        record = choices.get(payload.get("value"))
        if record:
            self.resume_record(record)
