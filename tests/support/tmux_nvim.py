import json
import shlex
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Optional


class TmuxNvimHarness:
    def __init__(self, repo_root: Path, project_root: Path, real_pi: bool = False) -> None:
        self.repo_root = repo_root.resolve()
        self.project_root = project_root.resolve()
        self.real_pi = real_pi
        self.session_name = f"strider-test-{uuid.uuid4().hex[:8]}"
        self.socket_path = Path(tempfile.gettempdir()) / f"{self.session_name}.sock"
        self.init_path = self.repo_root / "tests" / "support" / "minimal_init.lua"
        self.nvim_data_home = self.repo_root / "tests" / ".nvim-data"
        self.nvim_cache_home = self.repo_root / "tests" / ".nvim-cache"
        self.nvim_state_home = self.repo_root / "tests" / ".nvim-state"

    def _run(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, capture_output=True, text=True, check=check)

    def start(self) -> None:
        self.nvim_data_home.mkdir(parents=True, exist_ok=True)
        self.nvim_cache_home.mkdir(parents=True, exist_ok=True)
        self.nvim_state_home.mkdir(parents=True, exist_ok=True)
        env_parts = [
            f"STRIDER_TEST_ROOT={shlex.quote(str(self.repo_root))}",
            f"STRIDER_TEST_REAL_PI={'1' if self.real_pi else '0'}",
            f"XDG_DATA_HOME={shlex.quote(str(self.nvim_data_home))}",
            f"XDG_CACHE_HOME={shlex.quote(str(self.nvim_cache_home))}",
            f"XDG_STATE_HOME={shlex.quote(str(self.nvim_state_home))}",
        ]
        cmd = " ".join(env_parts + [
            "nvim",
            "--clean",
            "--listen",
            shlex.quote(str(self.socket_path)),
            "-u",
            shlex.quote(str(self.init_path)),
        ])
        self._run("tmux", "new-session", "-d", "-s", self.session_name, "-c", str(self.project_root), cmd)
        self.wait_for_server()
        self.wait_until(
            lambda: self.lua_bool("select(1, pcall(require, 'telescope')) and select(1, pcall(require, 'strider'))"),
            timeout=20.0,
        )

    def stop(self) -> None:
        self._run("tmux", "kill-session", "-t", self.session_name, check=False)
        try:
            if self.socket_path.exists():
                self.socket_path.unlink()
        except FileNotFoundError:
            pass

    def wait_for_server(self, timeout: float = 20.0) -> None:
        deadline = time.time() + timeout
        last_error = None
        while time.time() < deadline:
            try:
                self.expr("1")
                return
            except subprocess.CalledProcessError as exc:
                last_error = exc
                time.sleep(0.1)
        raise RuntimeError(f"Neovim server did not start: {last_error}")

    def expr(self, expression: str) -> str:
        result = self._run("nvim", "--server", str(self.socket_path), "--remote-expr", expression)
        return result.stdout.strip()

    def ex(self, command: str) -> str:
        quoted = "'" + command.replace("'", "''") + "'"
        return self.expr(f"execute({quoted})")

    def json_expr(self, expression: str):
        raw = self.expr(f"json_encode({expression})")
        return json.loads(raw)

    def lua(self, expression: str) -> str:
        return self.expr(f"luaeval({json.dumps(expression)})")

    def lua_bool(self, expression: str) -> bool:
        return self.lua(expression) in {"1", "v:true", "true"}

    def capture_pane(self) -> str:
        result = self._run("tmux", "capture-pane", "-pt", f"{self.session_name}:0")
        return result.stdout

    def send_keys(self, *keys: str) -> None:
        self._run("tmux", "send-keys", "-t", f"{self.session_name}:0", *keys)

    def send(self, *keys: str, pause: float = 0.2) -> None:
        self.send_keys(*keys)
        time.sleep(pause)

    def window_filetypes(self):
        return self.json_expr('map(getwininfo(), {_, v -> getbufvar(v.bufnr, "&filetype")})')

    def buffer_lines_by_filetype(self, filetype: str):
        lua_src = (
            "local ft = ...; "
            "local out = {}; "
            "for _, buf in ipairs(vim.api.nvim_list_bufs()) do "
            "  if vim.bo[buf].filetype == ft then "
            "    out[#out + 1] = vim.api.nvim_buf_get_lines(buf, 0, -1, false); "
            "  end; "
            "end; "
            "return out"
        )
        return json.loads(self.expr(f"json_encode(luaeval({json.dumps(lua_src)}, {json.dumps(filetype)}))"))

    def wait_until(self, predicate, timeout: float = 10.0, interval: float = 0.1) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(interval)
        raise AssertionError("condition not met before timeout")

    def current_state(self):
        return self.json_expr('{"buf": bufname("%"), "line": line("."), "qf": getqflist({"title": 1, "items": 1}), "wins": winnr("$")}')

    def log_lines(self):
        return self.json_expr('getbufline("strider://log", 1, "$")')

    def flow_log_lines(self):
        return self.json_expr('getbufline("strider://StriderLogFlow", 1, "$")')

    def review_log_lines(self):
        return self.json_expr('getbufline("strider://StriderLogReview", 1, "$")')

    def buffer_lines(self, name: str):
        return self.json_expr(f"getbufline({json.dumps(name)}, 1, '$')")

    def popup_open(self, name: str = "strider://prompt") -> bool:
        return self.expr(f"bufexists('{name}')") == "1"

    def submit_popup(self, text: Optional[str] = None, name: str = "strider://prompt",
                     timeout: float = 3.0, pause: float = 0.3) -> None:
        self.wait_until(lambda: self.popup_open(name), timeout=timeout)
        if text is None:
            self.send("C-s", pause=pause)
        else:
            self.send(text, "C-s", pause=pause)
        self.wait_until(lambda: not self.popup_open(name), timeout=timeout)

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.stop()
