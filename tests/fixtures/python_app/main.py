from app import greet, run


def main() -> int:
    print(greet("world"))
    return run()


if __name__ == "__main__":
    raise SystemExit(main())
