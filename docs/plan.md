# Current plan

## What Sherpa ships now

Primary flows:
- `:SherpaSearch`
- `:SherpaReview`
- `:SherpaPatch`
- `:SherpaWork`

Supporting UX:
- dedicated review pane
- quickfix + telescope/fzf search selection
- range highlighting for review/search/edit targets
- local review comments summarized back to the agent
- fast fake-backend tmux e2e tests
- optional real-pi smoke tests

## Near-term priorities

### 1. Review pane polish

Done:
- dedicated `sherpa://review` pane
- current item metadata
- explanation text
- item-local comments
- end-of-review summary

Next:
- tighten formatting and visual hierarchy
- make active range pairing feel even clearer
- keep explanations shorter and more review-like

### 2. Review flow quality

Improve:
- better prompts for concise, code-review style explanations
- better handling of follow-up questions on selected ranges
- clearer item summaries for diff and search reviews

### 3. Work -> review handoff

Improve:
- stronger review suggestions after `:SherpaWork`
- better use of the latest touched file / search result set / diff as review entry points

### 4. Comment flow

Keep local for now, but preserve space for:
- future PR review imports
- future external comment mapping
- comment -> patch follow-up flows

## Testing strategy

### Fast default suite

Use the fake pi backend plus tmux+nvim harness:

```bash
python3 -m unittest tests.test_tmux_search tests.test_tmux_review tests.test_count_lines
```

Goal:
- stay in the low-seconds range

### Optional real-pi smoke

```bash
SHERPA_TEST_REAL_PI=1 python3 -m unittest tests.test_real_pi_smoke
```

Goal:
- stay under a minute
- cover at least review + patch on the bundled fixture project

## Future: Session persistence

See `docs/session-persistence.md` for the full plan.

## Non-goals right now

- code restoration / rewind
- GitHub review submission
- a separate Sherpa skill system
- a separate Sherpa instruction loader
- heavy shell parsing heuristics
- restoring the old pre-review command surface

## Related docs

- `docs/architecture.md`
- `docs/review-mode.md`
- `docs/session-persistence.md`
- `tests/README.md`
- `recordings/README.md`
