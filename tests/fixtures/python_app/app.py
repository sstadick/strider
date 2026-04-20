from pathlib import Path


def greet(name: str) -> str:
    return f"hi, {name}"


def run() -> int:
    output = Path("run.log")
    output.write_text("started\n", encoding="utf-8")
    return 0
