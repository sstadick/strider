# Review mode

How `:SherpaReview` works today. For the underlying architecture see
`docs/architecture.md`; for the design rationale of the plan-based flow
see `docs/review-planning.md`.

## Mental model

Review is pre-planned. The model commits to a full ordered list of stops
up front; Sherpa then walks that list stop-by-stop. Navigation is
mechanical (`:SherpaNext` increments an index); explanations stream into
the `sherpa://review` pane as each stop becomes active.

This is the smwyg-browser pattern: plan first, navigate fast, deepen on
demand.

## Review scopes

Every review is one of three scopes. The **model self-labels** the scope
in its plan — there is no magic keyword in the user command. What the
user typed, and whether they had a visual range, are the only signals.

| Scope | User signal | Coverage guarantee |
|---|---|---|
| `selection` | `:'<,'>SherpaReview ...` with a visual range | every line in the range appears in some stop |
| `diff` | prose mentions diff / PR / branch changes | every line in `git diff <base>...HEAD` appears in some stop |
| `free` | anything else | none — the model picks what matters |

Coverage is validated at plan-ingest time by comparing stop ranges to
the original range or the diff. Gaps are auto-filled or surfaced as
`coverage: incomplete` in the review pane.

## Lifecycle

1. **User starts a review.** `:SherpaReview <prose>` with optional visual
   range. The review pane opens immediately in `stop: planning...` state
   — the user sees activity from keystroke zero.
2. **Sherpa sends `/plan <prose>`** to the extension. The extension's
   `plan` command tells the model to produce a plan by calling the
   `sherpa_plan` tool. No prose explanation yet.
3. **Model reads what it needs** and calls `sherpa_plan` with
   `{ scope, base?, stops: [{ path, startLine, endLine, title, why }] }`.
4. **Sherpa ingests the plan.** Stops are normalized (cwd-relative paths
   made absolute), coverage is checked, `current_index` is set to 1, the
   first stop is focused in the code window, and the TOC renders in the
   review pane.
5. **Sherpa focuses stop 1.** The explanation was already written by
   the planner as part of `sherpa_plan`'s payload — it's already in
   `items[1].explanation` and renders in the review pane. No second
   model round-trip happens on plan completion.
6. **User navigates.** `:SherpaNext` / `:SherpaPrev` increment/decrement
   `current_index`. Navigation is a local index change plus a buffer
   jump — no model call. `:SherpaReviewItems` opens a picker over the
   plan.
7. **Mid-review questions.** `:SherpaReview <question>` with an active
   review sends a `/review` scoped to the current stop, carrying the
   question as the user focus. This is the one place per-stop model
   round-trips happen.
8. **Mid-review plan growth (free scope only).** The model may call
   `sherpa_append_stops` during a `/review` turn to add more stops.
   Append-only — no reorder, no deletion. Selection/diff plans are fixed.
9. **End of review.** Walking past the last stop ends the review; if any
   comments are unresolved, Sherpa sends a final `/review` that feeds the
   comments back to the agent for summary/follow-up.

## Tools (extension)

- **`sherpa_plan`** — called by the model during `/plan`. Payload:
  `{ scope: "selection"|"diff"|"free", base?: string, stops: Stop[] }`.
  Rejects when scope is `"diff"` without a `base`. Rejects empty stops.
- **`sherpa_append_stops`** — called by the model mid-`/review`. Payload:
  `{ stops: Stop[] }`. Only honored when the active review has
  `scope == "free"`; otherwise Sherpa drops it on the floor.

## UI rules during review

- The **review pane** (`sherpa://review`) is the primary surface. It
  shows source, goal, current stop, scope, TOC (when >1 stops),
  explanation, excerpt, comments, and controls.
- The **code window** stays on the active planned stop. The model's
  `read` / `bash` / etc. tool calls during `/plan` or `/review` do **not**
  auto-jump the buffer. Jumps happen only on stop changes (`:SherpaNext`,
  `:SherpaPrev`, picker selection).
- The **log buffer** (`sherpa://log`) is secondary — transcript and tool
  activity for debugging.

## State shape

```lua
session.review = {
  active        = true,
  scope         = "selection" | "diff" | "free",
  base          = string | nil,        -- diff scope only
  source        = "review",
  goal          = "user's original prompt",
  planned       = true,
  planning      = bool,                -- true until sherpa_plan lands
  coverage_ok   = bool,

  items         = { ...stops... },     -- the plan
  current_index = number,              -- 0 while planning, 1..N after

  comments      = { ...review comments... },
  awaiting_summary = bool,
  summary       = string | nil,
}
```

A stop:
```lua
{
  id         = "path:start-end",
  path       = "/abs/path.ext",
  startLine  = 10,
  endLine    = 42,
  kind       = "selection" | "diff" | "planned",
  title      = "Short label for the TOC",
  why        = "One-sentence hook, sidebar current-item card",
  summary    = "2-3 sentence synopsis, sidebar Explanation section",
  excerpt    = "Cached snippet of the range",
  explanation = "3-5 sentence narrative, rendered as a block annotation above startLine in the code buffer",
  annotations = {           -- optional extras
    { kind = "block", startLine = ..., endLine = ..., text = "..." },
    { kind = "line",  line = ...,                      text = "..." },
  },
  status     = "pending" | "reviewed" | "commented",
}
```

### Three tiers of detail

The planner writes each stop at three levels:

| Field | Length | Where it renders |
|---|---|---|
| `why` | 1 sentence | Sidebar current-item card and TOC |
| `summary` | 2-3 sentences | Sidebar Explanation section — skimmable |
| `explanation` | 3-5 sentences | Block annotation above the stop's startLine in the code buffer |

`summary` and `explanation` are not duplicates — one is for the sidebar,
one is pinned to the code.

### Inline annotations

`annotations` are optional extra pinned notes inside a stop:
- `kind: "block"` with `startLine`/`endLine` → multi-line note above the sub-range.
- `kind: "line"` with `line` → end-of-line inline comment.

Budget (enforced in prompt, not code): at most one `block` annotation per
stop, and at most 25% of the stop's lines may receive a `line` annotation.
They're rendered as virtual text/lines via a dedicated extmark namespace
and cleared when the active stop changes or the review ends.

## Comments

`:SherpaComment <text>` attaches a comment to the active stop, or to a
visual sub-range inside it. Comments stay local to Sherpa — they are
**not** submitted anywhere. At end-of-review, any unresolved comments
are gathered into a final `/review` prompt so the agent can summarize
concerns and propose follow-ups.

The comment data shape leaves room for future GitHub PR review
integration; that integration is not implemented yet.

## Prompt shapes (extension)

Each operation has a specific prompt. They live in `pi/sherpa-stepper.ts`:

- **`/plan`** — tells the model to call `sherpa_plan`, self-label scope,
  keep stops small, order pedagogically, provide a `why` per stop.
- **`/review`** — only sent when the user asks a question with
  `:SherpaReview <question>` on an active review. Built by
  `review.build_prompt` on the Lua side, carrying `file`, `line range`,
  `title`, `why`, `excerpt`, and the user's focus text. Default per-stop
  explanations are pre-computed by the planner, not fetched here.
- **`/search`**, **`/patch`**, **`/work`** — unrelated to review; see
  README.

`/plan` and `/review` are both read-only (no edit/write tools).
