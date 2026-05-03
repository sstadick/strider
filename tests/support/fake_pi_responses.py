import re
from pathlib import Path

from fake_pi_events import emit_edit, emit_read, emit_strider_plan, emit_tool_output, fixture_path, project_has


def search_response(message: str) -> str:
    prompt = message[len("/search "):].lower()
    if project_has("src/main.tsx"):
        if "all" in prompt or "multiple" in prompt or "roots" in prompt:
            return "\n".join([
                f"{fixture_path('src/main.tsx')}:6:1,4,Main React entrypoint; mounts App into #root",
                f"{fixture_path('src/App.tsx')}:1:1,6,Top-level app component rendered from main.tsx",
            ])
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


def plan_response(_message: str) -> str:
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
            "annotations": [{"kind": "line", "line": 1, "text": "React + ReactDOM imports"}],
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
    if "Read-only chat mode is enabled." in message:
        return "Read-only prompt received. No changes were made."

    if "compact tool output" in message.lower():
        emit_tool_output("grep", {"pattern": "fixture", "path": "src"}, "# heading-like output\nsrc/App.tsx:1:export function App() {")
        return "Finished compact tool output pass."

    if "strider vim tool log" in message.lower():
        emit_tool_output(
            "strider_vim",
            {"intent": "inspect current Neovim state", "lua": "return { cwd = vim.fn.getcwd(), mode = vim.api.nvim_get_mode() }"},
            '{"ok":true,"value":{"cwd":"/tmp/project","mode":{"mode":"n"}}}',
        )
        return "Finished Vim tool log pass."

    if "tool argument headers" in message.lower():
        emit_tool_output("grep", {"pattern": "fixture", "path": "src", "glob": "*.tsx", "limit": 5}, "src/App.tsx:1:export function App() {")
        emit_tool_output("find", {"pattern": "*.lua", "path": "lua/strider", "limit": 3}, "lua/strider/rpc.lua\nlua/strider/ui.lua")
        emit_tool_output("ls", {"path": "lua/strider", "limit": 2}, "rpc.lua\nui.lua")
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
