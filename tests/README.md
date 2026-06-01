# Strider test tooling

## Goals

These tests cover the Neovim UX layer that is hard to validate with pure unit tests:
- running Strider inside a real Neovim TUI
- driving it from a tmux session
- querying Neovim state over a `--listen` socket
- using a fake pi RPC backend for repeatable UX tests
- checking transcript rendering details such as fenced read/write output,
  compact command/search output, inline edit diffs, and log-follow behavior
- checking review pane rendering, RPC helper parsing, recording freshness,
  and the raw `strider_vim` Lua executor with fast headless-Neovim unit tests

## Pieces

- `support/fake_pi.py` — tiny fake pi RPC process for canned Strider responses
- `support/minimal_init.lua` — minimal Neovim init that loads Strider from this repo and reuses already-installed telescope/fzf plugins
- `support/tmux_nvim.py` — reusable tmux + Neovim harness
- `run_tmux_session.py` — manual launcher for an interactive tmux-backed Strider session
- `fixtures/app/` — small fixture project used by the UX tests

## Running tests

From the repo root:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

These fake-backend tmux tests should stay cheap to run: seconds, not minutes.

## Optional real-pi smoke test

Uses the bundled zero-dependency `fixtures/python_app` project and covers:
- `:StriderReview file`
- `:StriderPatch` on a selected line

```bash
STRIDER_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

## Manual tmux session

Fake backend:

```bash
python3 tests/run_tmux_session.py --project tests/fixtures/app
```

Real pi backend against another project:

```bash
python3 tests/run_tmux_session.py --project ../some-project --real-pi
```

Then attach with:

```bash
tmux attach -t <session-name>
```

## Notes

The fake backend keeps the tests deterministic.
The minimal init does not install plugins during test runs; it reuses the user's existing telescope/fzf setup.
The real-pi launcher and smoke test are for live model debugging and should stay optional.
