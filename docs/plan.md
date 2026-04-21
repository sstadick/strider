# Current plan

## What Sherpa ships now

Primary flows:
- `:SherpaSearch`
- `:SherpaReview` (pre-planned walkthrough — see `docs/review-mode.md`)
- `:SherpaPatch`
- `:SherpaChat`

Supporting UX:
- dedicated review pane with a plan TOC
- quickfix + telescope/fzf search selection
- range highlighting for search/edit targets (suppressed during review)
- local review comments summarized back to the agent at review end
- fast fake-backend tmux e2e tests
- optional real-pi smoke tests

## Near-term priorities

### 1. Review ergonomics

Done:
- model-led planning via the `sherpa_plan` tool (one-shot plan, fixed navigation)
- plan-time explanations at three detail tiers (`why` → sidebar hook,
  `summary` → sidebar synopsis, `explanation` → in-buffer block annotation
  above startLine)
- optional inline annotations per stop (`kind: "block"` or `kind: "line"`)
  pinned to sub-ranges of the code; budgeted at ≤1 block + 25% of lines
- annotation lifecycle: cleared when the active stop changes or the review
  ends; extmarks are in-memory only so nvim exit cleans up automatically
- `:SherpaNext` / `:SherpaPrev` are instant — no per-stop model call
- TOC in the review pane for multi-stop plans (rendered below comments)
- coverage guarantees for `selection` and `diff` scopes
- append-only mid-review plan growth for free-scope (`sherpa_append_stops`)
- no auto-jump during review — code window stays on the active stop
- `/review` reserved for user questions on an active stop
  (`:SherpaReview <question>`); default explanations are pre-computed

Next:
- prompt hardening: better guidance for when explanations are too terse
  or too generic
- `:SherpaRetry` today only handles a stalled `/plan` turn — consider
  whether `/review` question turns need recovery too

### 2. Work → review handoff

Improve:
- stronger review suggestions after `:SherpaChat`
- better use of the latest touched file / search result set / diff as
  review entry points

### 3. Comment flow

Keep local for now, but preserve space for:
- future PR review imports
- future external comment mapping
- comment → patch follow-up flows

## Testing strategy

### Fast default suite

Fake pi backend + tmux+nvim harness:

```bash
python3 -m unittest tests.test_tmux_search tests.test_tmux_review tests.test_tmux_popups tests.test_plan_helpers tests.test_count_lines
```

Goal: stay in the low-seconds range.

### Optional real-pi smoke

```bash
SHERPA_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

Goal: stay under a minute; cover at least review + patch on the bundled
fixture project.

## Future: Session persistence

See `docs/session-persistence.md`.

## Non-goals right now

- code restoration / rewind
- GitHub review submission
- a separate Sherpa skill system
- a separate Sherpa instruction loader
- heavy shell parsing heuristics
- restoring the old pre-refactor dynamic-discovery review flow

## Related docs

- `docs/architecture.md`
- `docs/review-mode.md`
- `docs/review-planning.md`
- `docs/session-persistence.md`
- `tests/README.md`
- `recordings/README.md`
