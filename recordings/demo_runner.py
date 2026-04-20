#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORK_ROOT = REPO_ROOT / "recordings" / "_workspace"
MINIMAL_INIT = REPO_ROOT / "tests" / "support" / "minimal_init.lua"


class DemoNvim:
    def __init__(self, project_root: Path) -> None:
        self.project_root = project_root.resolve()
        self.socket_path = Path(tempfile.gettempdir()) / f"sherpa-demo-{os.getpid()}.sock"
        self.proc = None

    def start(self, file_to_open: str | None = None) -> None:
        env = os.environ.copy()
        env["SHERPA_TEST_ROOT"] = str(REPO_ROOT)
        env["SHERPA_TEST_REAL_PI"] = "0"
        cmd = [
            "nvim",
            "--clean",
            "--listen",
            str(self.socket_path),
            "-u",
            str(MINIMAL_INIT),
        ]
        if file_to_open:
            cmd.append(file_to_open)
        self.proc = subprocess.Popen(cmd, cwd=self.project_root, env=env)
        self.wait_for_server()
        self.wait_until(lambda: self.lua_bool("select(1, pcall(require, 'sherpa'))"), timeout=10)
        time.sleep(0.4)

    def stop(self) -> None:
        try:
            self.send(":qall!<CR>")
            if self.proc is not None:
                self.proc.wait(timeout=5)
        except Exception:
            if self.proc is not None:
                self.proc.kill()
        finally:
            try:
                self.socket_path.unlink(missing_ok=True)
            except Exception:
                pass

    def run(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, check=True, capture_output=True, text=True)

    def wait_for_server(self, timeout: float = 10.0) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                self.expr("1")
                return
            except subprocess.CalledProcessError:
                time.sleep(0.1)
        raise RuntimeError("Neovim server did not start")

    def expr(self, expression: str) -> str:
        return self.run("nvim", "--server", str(self.socket_path), "--remote-expr", expression).stdout.strip()

    def lua(self, expression: str) -> str:
        import json
        return self.expr(f"luaeval({json.dumps(expression)})")

    def lua_bool(self, expression: str) -> bool:
        return self.lua(expression) in {"1", "true", "v:true"}

    def send(self, keys: str, pause: float = 0.8) -> None:
        subprocess.run(["nvim", "--server", str(self.socket_path), "--remote-send", keys], check=True)
        time.sleep(pause)

    def command(self, command: str, pause: float = 1.0) -> None:
        self.send(f":{command}<CR>", pause=pause)

    def wait_until(self, predicate, timeout: float = 10.0, interval: float = 0.1) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(interval)
        raise RuntimeError("condition not met before timeout")

    def line(self) -> int:
        return int(self.expr('line(".")'))


def reset_workspace(name: str, fixture: str) -> Path:
    src = REPO_ROOT / "tests" / "fixtures" / fixture
    dst = WORK_ROOT / name
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst)
    return dst


def init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.email", "demo@example.com"], cwd=path, check=True)
    subprocess.run(["git", "config", "user.name", "Sherpa Demo"], cwd=path, check=True)
    subprocess.run(["git", "add", "."], cwd=path, check=True)
    subprocess.run(["git", "commit", "-qm", "base"], cwd=path, check=True)


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def prepare_diff_workspace() -> Path:
    project = reset_workspace("review_diff", "app")
    init_git_repo(project)
    app = project / "src" / "App.tsx"
    write(app, 'export function App() {\n  return <main>Hello from diff demo</main>\n}\n')
    return project


def prepare_work_workspace() -> Path:
    project = reset_workspace("work_review", "app")
    init_git_repo(project)
    return project


def prepare_app_workspace(name: str) -> Path:
    return reset_workspace(name, "app")


def prepare_python_workspace(name: str) -> Path:
    return reset_workspace(name, "python_app")


def scenario_search() -> None:
    project = prepare_app_workspace("search")
    nvim = DemoNvim(project)
    try:
        nvim.start("index.html")
        nvim.command("SherpaSearch where is the main entrypoint?", pause=1.2)
        nvim.wait_until(lambda: nvim.line() == 6, timeout=5)
        time.sleep(1.2)
    finally:
        nvim.stop()


def scenario_review_file() -> None:
    project = prepare_app_workspace("review_file")
    nvim = DemoNvim(project)
    try:
        nvim.start("src/main.tsx")
        nvim.command("SherpaReview file", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        time.sleep(1.2)
        nvim.command("SherpaNext", pause=0.9)
        time.sleep(1.0)
        nvim.command("SherpaPrev", pause=0.9)
        time.sleep(1.0)
    finally:
        nvim.stop()


def scenario_review_diff() -> None:
    project = prepare_diff_workspace()
    nvim = DemoNvim(project)
    try:
        nvim.start("src/App.tsx")
        nvim.command("SherpaReview diff", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        time.sleep(1.8)
    finally:
        nvim.stop()


def scenario_review_searches() -> None:
    project = prepare_app_workspace("review_searches")
    nvim = DemoNvim(project)
    try:
        nvim.start("src/main.tsx")
        nvim.command("SherpaSearch show all entry roots", pause=1.0)
        nvim.wait_until(lambda: "TelescopeResults" in nvim.expr('json_encode(map(getwininfo(), {_, v -> getbufvar(v.bufnr, "&filetype")}))'), timeout=5)
        time.sleep(1.0)
        nvim.send("<CR>", pause=1.0)
        nvim.command("SherpaReview searches", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        time.sleep(1.5)
    finally:
        nvim.stop()


def scenario_review_selection() -> None:
    project = prepare_app_workspace("review_selection")
    nvim = DemoNvim(project)
    try:
        nvim.start("src/main.tsx")
        nvim.command("SherpaReview file", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        nvim.send("ggjVj:SherpaReview why does this block matter?<CR>", pause=1.2)
        time.sleep(1.5)
    finally:
        nvim.stop()


def scenario_review_comment() -> None:
    project = prepare_app_workspace("review_comment")
    nvim = DemoNvim(project)
    try:
        nvim.start("src/main.tsx")
        nvim.command("SherpaReview file", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        nvim.send("ggjVj:SherpaComment<CR>", pause=0.8)
        nvim.send("This branch needs a clearer name<CR>Maybe mention root rendering too<C-s>", pause=1.2)
        time.sleep(1.5)
    finally:
        nvim.stop()


def scenario_patch() -> None:
    project = prepare_python_workspace("patch")
    nvim = DemoNvim(project)
    try:
        nvim.start("app.py")
        nvim.send("gg4jV:SherpaPatch change the greeting literal from hi to hello and only touch this line<CR>", pause=1.2)
        time.sleep(2.0)
    finally:
        nvim.stop()


def scenario_work_review() -> None:
    project = prepare_work_workspace()
    nvim = DemoNvim(project)
    try:
        nvim.start("src/App.tsx")
        nvim.command("SherpaWork add loading states to the lobby flow", pause=1.4)
        time.sleep(1.2)
        nvim.command("SherpaReview diff", pause=1.2)
        nvim.wait_until(lambda: nvim.lua_bool("require('sherpa.review').has_active_review()"), timeout=5)
        nvim.send("ggjVj:SherpaComment this branch needs a clearer empty state<CR>", pause=1.0)
        time.sleep(0.8)
        nvim.command("SherpaNext", pause=1.2)
        time.sleep(1.8)
    finally:
        nvim.stop()


SCENARIOS = {
    "search": scenario_search,
    "review-file": scenario_review_file,
    "review-diff": scenario_review_diff,
    "review-searches": scenario_review_searches,
    "review-selection": scenario_review_selection,
    "review-comment": scenario_review_comment,
    "patch": scenario_patch,
    "work-review": scenario_work_review,
}


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in SCENARIOS:
        print("usage: demo_runner.py <scenario>", file=sys.stderr)
        print("scenarios: " + ", ".join(sorted(SCENARIOS)), file=sys.stderr)
        return 2
    SCENARIOS[sys.argv[1]]()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
