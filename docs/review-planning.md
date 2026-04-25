# Review planning refactor (historical design doc)

> **Status:** This design has been fully implemented. See
> `docs/review-mode.md` for the current review lifecycle and state shape.
> This document is preserved as design history.

Design notes for shifting Strider review from model-discovered stops to
pre-planned stops. Not user-facing docs — just the shape of the change
so we can argue about it before touching code.

## Goals

1. All three review kinds (free-form, selection, diff) share one code path.
2. Navigation (`:StriderNext` / `:StriderPrev`) is instant — no model round-trip.
3. For selection and diff reviews, every line of code is visited.
4. Free-form reviews let the model choose stops, but commit to them up front.
5. Status widget shows meaningful progress from the moment the command runs.
6. Plan is append-only mid-review (model can add stops, not reorder/delete).
7. End of review is "walked past the last stop" — drop `complete_suggested`.

## Three review origins, one plan shape

All reviews are planned by the model via an explicit tool call (see §3).
The model is told what context it has (range, diff mention, free prompt)
and self-labels the scope it's producing:

| Origin | User signal | Model's scope label | Coverage check |
|---|---|---|---|
| `:'<,'>StriderReview <focus>` | visual range | `"selection"` | every line in range must be in some stop |
| `:StriderReview <focus that mentions diff / PR / branch changes>` | prose | `"diff"` | every line in `git diff <base>...HEAD` must be in some stop |
| `:StriderReview <focus>` (no range, free prose) | prose | `"free"` | none |

No magic keywords. Scope is whatever the model says it is. If the user
runs `:StriderReview walk me through the diff on main`, the model should
return `scope: "diff"` and `base: "main"`; Lua then validates coverage.

If the model mislabels (returns `"free"` when the user clearly asked for
a diff), we lose the coverage guarantee but the review still works. That's
acceptable — the model is the authority on intent.

All three produce the same `plan: Stop[]` structure. Stop shape:

```lua
{
  id         = "path:start-end",
  path       = "/abs/path.ext",
  startLine  = 10,
  endLine    = 42,
  title      = "Short label",         -- sidebar + picker
  why        = "One sentence hook",   -- why this stop matters (plan-time)
  kind       = "selection"|"diff"|"free",
  excerpt    = "...",                 -- cached at plan time
  explanation = nil,                  -- filled in by model at visit time
  status     = "pending"|"reviewed"|"commented",
}
```

`why` is new. It's what the model wrote when it planned the stop, and it
shows up in the sidebar before we ever visit the stop. For selection/diff
scopes, `why` is auto-generated ("Selected range, lines 10-42") — the
field is always populated.

## State shape (replaces review.lua lines 689-703)

```lua
session.review = {
  active        = true,
  scope         = "free"|"selection"|"diff",
  source        = "review",
  goal          = "user's original focus text",

  plan          = { stop1, stop2, ... },  -- append-only after this point
  current_index = 0,                      -- 0 before first visit, 1..N while visiting
  planning      = true,                   -- true until plan lands; drives widget text

  comments      = {},
  summary       = nil,
  awaiting_summary = false,
  summary_forwarded = false,
}
```

Flags that disappear: `dynamic`, `expecting_next_item`, `complete_suggested`,
`pending_item`, `overview`, `last_overview`, `items` (renamed to `plan`).

`planning` replaces `dynamic` as the flag the sidebar/widget check for
"what state are we in?" — but it's only true during the initial plan call.

## Flow

### 1. Command dispatched

User runs `:StriderReview <focus>` (or with range, or `diff`).

`init.lua::M.review` picks scope:
- range → `scope = "selection"`
- `args == "diff"` or similar → `scope = "diff"`
- otherwise → `scope = "free"`

All three call one entry: `review.start({ scope = ..., focus = ..., range = ... })`.

### 2. Plan construction

`review.start` sets `session.review` with `planning = true, plan = {}`
and immediately calls `ui.start_activity("Planning review...", "review", "teach")`.
Widget and sidebar both show "Planning…" from this moment. **No blank window.**

Every review, regardless of origin, sends one `/plan` prompt to the
model. The prompt includes:

- The user's focus text.
- Any range context (`path:start-end`) if a visual range was provided.
- A hint that the model may need to consult git if the user mentioned
  diff/PR/branch changes.
- The rules for the plan (stops small, ordered pedagogically, cover the
  surface requested, each stop has a `why`).
- The scope-labeling contract: return `scope ∈ {"selection","diff","free"}`
  plus `base` for diff.

The model then calls the `strider_plan` tool (see §3) with the full plan.

### 3. Plan delivery: `strider_plan` extension tool

New tool registered in `pi/strider-stepper.ts`. Model calls it with:

```ts
{
  scope: "selection" | "diff" | "free",
  base?: string,                        // required if scope="diff"
  stops: Array<{
    path: string,
    startLine: number,
    endLine: number,
    title: string,
    why: string,
  }>,
}
```

The tool:
- Validates the shape (scope is one of the three; stops non-empty; line
  numbers are positive; required fields present).
- Returns an ACK result synchronously to the model (`{ ok: true, count: N }`).
- Emits a `extension_ui_request` event carrying the full plan payload
  back to Lua via the existing `pi.ui` channel — or more cleanly, the
  Lua side reads the tool args directly from `tool_execution_end`.

On the Lua side, `rpc.lua::handle_tool_end` gets a new branch:

```lua
if event.toolName == "strider_plan" and review.planning_active() then
  review.set_plan(event.args.scope, event.args.base, event.args.stops)
  -- coverage validation happens inside set_plan
  return
end
```

Because the model can't malform the plan silently (schema is enforced
tool-side), the "plan parse failed" failure mode from the earlier draft
is averted. If the model somehow doesn't call `strider_plan` at all on a
plan turn, we detect that at `message_end` (teach operation + planning
still active + no tool call of the right name) and surface a clean error
"Strider could not produce a plan — try rephrasing." No silent hang.

After plan is set:
- `planning = false`
- coverage validated (selection/diff only; see §5)
- `current_index = 1`
- focus first stop
- send a `/review` prompt to explain stop 1, using `review.build_prompt`
  (already exists, per-stop shape)

### 4. Per-stop explanation

`/review` stays focused: explain one stop. No behavioral change from
today beyond the prompt always referring to a plan-backed stop (so
`build_prompt` can rely on `item.why` being populated).

### 5. Coverage validation (selection and diff only)

When `set_plan` runs with `scope == "selection"`, Lua checks that the
union of `[startLine, endLine]` across stops covers every line of the
original range. Gaps → log a warning and auto-append filler stops to
close them. This enforces the "every line must be seen" invariant even
if the model dropped a stop.

When `scope == "diff"`, Lua runs `git diff <base>...HEAD --name-only`
and `git diff <base>...HEAD -- <file>` to get the set of changed line
ranges per file. Same check: stops must cover every changed line. Gaps
are auto-filled.

When `scope == "free"`: no coverage check. Model chose the stops.

### 6. Navigation

`:StriderNext` (the interesting case):

```lua
function M.next_step()
  local r = review.active_review()
  if not r then ... end

  -- Instant advance — no conditional on scope
  local item, finished = review.advance(1)
  if item then
    send_review_prompt(review.build_prompt(), "Review stop " .. r.current_index)
    return
  end

  -- Past the end: finish
  finish_and_summarize(r)
end
```

One path. No dynamic vs. non-dynamic branching. The "ask model for the
next stop" prompt is gone — because the plan already knows.

`:StriderPrev` is symmetric, minus the finish path.

### 7. Append-only plan amendment (free scope only)

Via a second extension tool: `strider_append_stops`. Same payload shape
as `strider_plan`'s `stops` field. Model can call it mid-review from
inside a `/review` turn if it decides another area is critical.

Lua handler in `rpc.lua::handle_tool_end`:
```lua
if event.toolName == "strider_append_stops" and review.has_active_review() then
  review.append_stops(event.args.stops)
  return
end
```

`review.append_stops` only appends — never inserts mid-list, never
reorders, never removes. Sidebar re-renders; "N/M stops" grows.

The tool is only registered/available during `/review` turns on `scope ==
"free"` reviews. For selection/diff, the extension rejects the call with
a clear reason — the plan is supposed to be fixed.

### 8. End of review

`review.advance(+1)` returns `finished = true` when `current_index == #plan`
and user presses `:StriderNext` again. That drives the existing
`finish_and_summarize` path (summary request with unresolved comments).

No more `complete_suggested`. No more "model said we're done" state.

## Status widget — must update immediately

The user asked for this explicitly. Current flow: `ui.start_activity`
fires in `send()` but only when a prompt is actually sent, and the
widget text is derived from `state.activeOperation` in the extension.
The free-scope path currently does: `review.start_dynamic` → `send_review_prompt`
(one activity start). The new flow needs:

1. `review.start` sets `review.planning = true` and calls
   `ui.start_activity("Planning review...", "review", "teach")`
   **before** any RPC send. That alone makes the bottom-left show
   "Strider review running…" immediately.
2. When plan is ready, update the activity title via a new
   `ui.update_activity(title)` (if that doesn't exist, add it) to
   something like `"Reviewing 1/N: <stop title>"`.
3. On each `:StriderNext`, update the title to `"Reviewing K/N: ..."`.
4. On end, `ui.finish_activity("Review complete", "success")`.

For the free scope, between step 1 and 2 the widget says
`Planning review (asking model)` and the model's planning turn is visible
in the log. Critically, **the user sees something happening from keystroke zero**.

For selection/diff, steps 1 and 2 are back-to-back (plan is synchronous),
so the widget flashes "Planning…" briefly then becomes
"Reviewing 1/N: ..." before the model starts streaming.

## Sidebar changes

Review pane markdown is now built in `lua/strider/review/render.lua`; the
stateful review workflow in `review.lua` calls into that renderer. The
sidebar work from this plan mostly meant:

- Remove `dynamic` / `expecting_next_item` / `complete_suggested` branches.
- Always render the TOC: `plan[i].title` with `→` marker on `current_index`.
  (Today, the sidebar only shows the current item's details. The TOC is
  a real upgrade — it's what smwyg-browser's sidebar gives you.)
- Add a "planning" placeholder block when `planning == true`.
- `why` renders above `Explanation` (or as the fallback text when no
  explanation has streamed yet).

## Prompt + extension changes (strider-stepper.ts)

Today: one `/review` prompt mode that does everything.

New:

1. Add a `/plan` command + prompt. Prompt asks the model to:
   - Read whatever it needs to understand the user's goal.
   - Classify the review: `scope ∈ {"selection","diff","free"}`. If
     `diff`, identify the `base` ref (merge-base or what user named).
   - Produce stops (small, ≤ `MAX_REVIEW_LINES`, pedagogically ordered,
     covering the requested surface for selection/diff, each with a `why`).
   - Deliver the plan by calling `strider_plan` — not by writing prose.
   - Do not start explaining yet.

2. Register a `strider_plan` tool. Schema validation inside. Returns
   `{ ok: true, count: N }`. Available only during `/plan` turns.

3. Register a `strider_append_stops` tool. Same schema as plan's `stops`.
   Available only during `/review` turns on `free`-scope reviews. Rejects
   on selection/diff scope with a reason string.

4. `/review` stays focused: explain one stop. `review.build_prompt` on
   the Lua side already builds this correctly — it just needs the
   plan-backed stop to include `why` so the prompt can reference it.

## Files that need to change

| File | Change |
|---|---|
| `lua/strider/review.lua` | new state shape; `plan_from_range`; `plan_from_diff`; `set_plan`; `append_stops`; prune old flags; keep comments/summary logic |
| `lua/strider/review/render.lua` | render review pane markdown: status, item details, excerpts, comments, controls, and TOC |
| `lua/strider/init.lua` | unify `M.review` scope dispatch; rewrite `M.next_step` / `M.prev_step` to single path; add `diff` arg |
| `lua/strider/rpc.lua` | handle `strider_plan` / `strider_append_stops` in `handle_tool_end`; drop the `review.note_read` call on read-tool-end (keep `state.record_file`) |
| `lua/strider/ui.lua` | `update_activity(title)` if missing; TOC rendering helper if useful |
| `pi/strider-stepper.ts` | add `plan` command and prompt; keep `teach` mostly as-is |
| `docs/review-mode.md` | update once the refactor lands |
| tests | extend `spec/review_*` with plan-shape tests, append tests, selection coverage test |

## Resolved decisions

1. **Plan transport**: `strider_plan` extension tool (not sentinel).
   Schema-validated; no silent malformation.
2. **Scope**: model self-labels `scope` in its tool call. No magic
   keyword in the user command. User phrasing is the only signal.
3. **Plan failure**: averted by (1). If model fails to call the tool at
   all on a plan turn, fail loudly with "Strider could not produce a
   plan — try rephrasing."
4. **`note_read`**: delete from review path. Keep `state.record_file`
   (independent recently-viewed tracking).
5. **Coverage**: enforced in `review.set_plan` for selection/diff scopes;
   auto-append filler stops on gaps.

## What this does NOT change

- Comments (`:StriderComment`), comment picker, unresolved-comments summary.
- Patch mode (`:StriderPatch`).
- Search mode.
- The `teach` read-only enforcement in `strider-stepper.ts`.
- The log buffer.

## Migration order (suggested commits)

1. Add `plan_from_range` and `plan_from_diff` helpers + coverage tests;
   don't wire them up yet.
2. Introduce the new state shape behind a feature flag; run selection
   reviews through it. Old dynamic path still works.
3. Add `/plan` prompt and sentinel parsing; move free-scope reviews to
   the new path. Old dynamic state fields become unreachable.
4. Delete dead flags and the `note_read`→`pending_item` code.
5. Add `diff` scope.
6. Update docs.

Each step is independently shippable; you can stop after 2 and still
have a cleaner selection review.
