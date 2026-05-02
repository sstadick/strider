# Review mode

How `:StriderReview` works today. For the underlying architecture see
`docs/architecture.md`; for the design rationale of the plan-based flow
see `docs/review-planning.md`.

## Mental model

Review is pre-planned. The model commits to a full ordered list of stops
up front; Strider then walks that list stop-by-stop. Navigation is
mechanical (`:StriderNext` increments an index, `:StriderNext!` accepts the
current stop before advancing); explanations render into the
`strider://review` pane as each stop becomes active.

This is the smwyg-browser pattern: plan first, navigate fast, deepen on
demand.

## Review scopes

Every review is one of three scopes. The **model self-labels** the scope
in its plan — there is no magic keyword in the user command. What the
user typed, and whether they had a visual range, are the only signals.

| Scope | User signal | Coverage guarantee |
|---|---|---|
| `selection` | `:'<,'>StriderReview ...` with a visual range | every line in the range appears in some stop |
| `diff` | prose mentions diff / PR / branch changes | every line in `git diff <base>...HEAD` appears in some stop |
| `free` | anything else | none — the model picks what matters |

Coverage is validated at plan-ingest time by comparing stop ranges to
the original range or the diff. Gaps are auto-filled or surfaced as
`coverage: incomplete` in the review pane.

## Lifecycle

1. **User starts a review.** `:StriderReview <prose>` with optional visual
   range. The start editor defaults to a fresh review context; pressing
   `<C-g>c` toggles copying the current main chat transcript into the review
   prompt as background. The review pane opens immediately in
   `stop: planning...` state — the user sees activity from keystroke zero.
2. **Strider sends `/plan <prose>`** to the extension. If main-chat context was
   selected, Strider appends it in a bounded `<MAIN_CHAT_CONTEXT>` block. The
   extension's `plan` command tells the model to produce a plan by calling the
   `strider_plan` tool. No prose explanation yet.
3. **Model reads what it needs** and calls `strider_plan` with
   `{ scope, base?, stops: [{ path, startLine, endLine, title, why }] }`.
4. **Strider ingests the plan.** Stops are normalized (cwd-relative paths
   made absolute), coverage is checked, `current_index` is set to 1, the
   first stop is focused in the code window, and the TOC renders in the
   review pane.
5. **Strider focuses stop 1.** The explanation was already written by
   the planner as part of `strider_plan`'s payload — it's already in
   `items[1].explanation` and renders in the review pane. No second
   model round-trip happens on plan completion.
6. **User navigates.** `:StriderNext` / `:StriderPrev` increment/decrement
   `current_index`. `:StriderNext!` marks the current stop accepted and
   then advances. Navigation is a local index change plus a buffer jump
   — no model call. `:StriderReviewItems` opens a picker over the plan.
7. **Mid-review questions.** `:StriderReview <question>` with an active
   review sends a `/review` scoped to the current stop, carrying the
   question as the user focus. Plain follow-up answers render in the review
   pane under the current stop; visual-range questions render inline over the
   selected range. The review log stays hidden unless opened explicitly.
8. **Mid-review plan growth (free scope only).** The model may call
   `strider_append_stops` during a `/review` turn to add more stops.
   Append-only — no reorder, no deletion. Selection/diff plans are fixed.
9. **End of review.** Walking past the last stop ends the review in the
   `strider://review` pane. The review log is not opened automatically. If any
   comments are unresolved, Strider sends a final `/review` in the background
   that feeds the comments back to the agent for summary/follow-up; the final
   summary renders in the review pane and is forwarded into the main chat
   transcript.

## Tools (extension)

- **`strider_plan`** — called by the model during `/plan`. Payload:
  `{ scope: "selection"|"diff"|"free", base?: string, stops: Stop[] }`.
  Rejects when scope is `"diff"` without a `base`. Rejects empty stops.
- **`strider_append_stops`** — called by the model mid-`/review`. Payload:
  `{ stops: Stop[] }`. Only honored when the active review has
  `scope == "free"`; otherwise Strider drops it on the floor.

## UI rules during review

- The **review pane** (`strider://review`) is the primary surface. It
  shows source, goal, current stop, scope, TOC (when >1 stops),
  explanation, excerpt, comments, and controls.
- The **code window** stays on the active planned stop. The model's
  `read` / `bash` / etc. tool calls during `/plan` or `/review` do **not**
  auto-jump the buffer. Jumps happen only on stop changes (`:StriderNext`,
  `:StriderPrev`, picker selection).
- The **review log buffer** (`strider://StriderLogReview`) is secondary —
  transcript and tool activity for debugging. Review start, mid-review
  questions, and review end do not open it automatically; users can toggle it
  explicitly with `:StriderLogReview`.

Implementation boundary:
- `lua/strider/review.lua` owns state changes: starting reviews, ingesting
  plans, advancing stops, comments, summaries, and prompts.
- `lua/strider/review/render.lua` owns the review pane markdown. It is
  intentionally state-free: callers pass a review table and cwd, and it
  returns the lines to write to `strider://review`.
- `lua/strider/ui.lua` owns the Neovim buffer/window mechanics for showing
  those lines and rendering code-buffer annotations.

## State shape

```lua
session.review = {
  active        = true,
  scope         = "selection" | "diff" | "free",
  base          = string | nil,        -- diff scope only
  source        = "review",
  goal          = "user's original prompt",
  planned       = true,
  planning      = bool,                -- true until strider_plan lands
  coverage_ok   = bool,

  items         = { ...stops... },     -- the plan
  current_index = number,              -- 0 while planning, 1..N after

  comments      = { ...review comments... },
  accepted_stops = {},                 -- stop ids accepted via :StriderNext!
  awaiting_summary = bool,
  summary       = string | nil,
  summary_forwarded = bool,
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
  status     = "pending" | "reviewed" | "commented" | "accepted",
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

`:StriderComment <text>` attaches a comment to the active stop, or to a
visual sub-range inside it. Comments stay local to Strider — they are
**not** submitted anywhere. At end-of-review, any unresolved comments
are gathered into a final `/review` prompt so the agent can summarize
concerns and propose follow-ups.

The comment data shape leaves room for future GitHub PR review
integration; that integration is not implemented yet.

## Prompt shapes (extension)

Each operation has a specific prompt. They live in `pi/strider-stepper.ts`:

- **`/plan`** — tells the model to call `strider_plan`, self-label scope,
  keep stops small, order pedagogically, provide a `why` per stop.
- **`/review`** — only sent when the user asks a question with
  `:StriderReview <question>` on an active review. Built by
  `review.build_prompt` on the Lua side, carrying `file`, `line range`,
  `title`, `why`, `excerpt`, and the user's focus text. Default per-stop
  explanations are pre-computed by the planner, not fetched here.
- **`/search`**, **`/patch`**, **`/prompt`** — unrelated to review; see
  README.

`/plan` and `/review` are both read-only (no edit/write tools).
