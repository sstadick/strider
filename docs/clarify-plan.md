# Clarify plan

Design rationale for the `sherpa_clarify` tool, which lets the model
pause mid-turn to ask a clarifying question, propose a plan, or confirm
a destructive action before proceeding. Shipped and wired into
`:SherpaChat` and `:SherpaPatch` today; this doc captures the shape and
trade-offs.

> **Status update:** the UX described below has since been simplified.
> Clarify questions and plan-proposal bodies now render inline in the
> chat log, and the reply flows back through the compose buffer rather
> than a floating editor (a `[Clarify]` badge marks the hijacked state).
> The floating editor and floating preview windows were removed. See
> `docs/architecture.md` (Input editor / RPC events sections) for the
> current shape. The design reasoning below still explains *why* the
> tool exists and when the model should invoke it.

## Why

Before clarify existed, `:SherpaChat`, `:SherpaPatch`, and
`:SherpaReview` (for questions) went straight from user prompt → model
action. There was no handshake. When the user's request was ambiguous,
or the model realized the change was bigger than it looked, the options
were: guess, or bail with text. Both were bad.

We want an explicit escape hatch: the model can pause mid-turn, ask the
user something, and continue with the answer. Not required — only when
the model judges it useful.

## What "clarify" covers

Four distinct situations, all served by one tool with different `kind`s:

1. **Question** — open-ended ambiguity. Model asks, user replies freely.
   - "Refactor the auth flow" → "Which layer? Sessions too?"
2. **Plan proposal** — model has an approach but wants sign-off because
   the change is bigger or more nuanced than the prompt implies.
   - "Here's what I'll do: 1. X 2. Y 3. Z. Approve, edit, or reject?"
3. **Confirm** — yes/no gate before a destructive or expensive action.
   - "This will rewrite 400 lines across 8 files. Proceed?"
4. **(Dropped for v1)** **Blocker** — model is stopping. Just use a
   regular assistant text message; no tool needed.

## Mechanism

The extension API already exposes `ctx.ui.editor(title, prefill)`,
`ctx.ui.confirm(title, message)`, `ctx.ui.select(title, options)`, and
`ctx.ui.input(title, placeholder)` — all async Promise-returning. They
emit `extension_ui_request` events to the Lua plugin; the plugin is
expected to reply with `extension_ui_response` carrying the user's
answer. pi-coding-agent then resolves the awaiting Promise and the tool
continues.

**Today's gap:** our Lua side only handles `notify`, `setStatus`, and
`setWidget` extension UI methods. The dialog methods (`editor`,
`confirm`, `select`, `input`) are not wired up. Without them, any
extension tool that tries to open a dialog would hang forever.

So clarification is really two layers of work:

### Layer 1 — Lua-side extension-UI dialog handlers

One-time plumbing in `lua/sherpa/rpc.lua::handle_extension_ui`:

- `method == "editor"` — open a floating scratch editor (reuse
  `ui.open_prompt_editor` shape), submit via `<C-s>`, cancel via
  `<Esc><Esc>`. On submit send
  `{type: "extension_ui_response", id, value: text}`. On cancel send
  `{type: "extension_ui_response", id, cancelled: true}`.
- `method == "confirm"` — `vim.ui.select({"Yes", "No"}, ...)` or a
  small floating prompt. Response: `{confirmed: bool}` or
  `{cancelled: true}`.
- `method == "select"` — `vim.ui.select(options, ...)`. Response:
  `{value: string}` or `{cancelled: true}`.
- `method == "input"` — `vim.ui.input({prompt, default}, ...)`.
  Response: `{value: string}` or `{cancelled: true}`.

This plumbing is orthogonal to the clarify tool — once shipped, any
extension-side `ctx.ui.*` dialog works. The clarify tool is the first
consumer.

### Layer 2 — `sherpa_clarify` tool + prompt guidance

Register in `pi/sherpa-stepper.ts`:

```ts
{
  kind: "question" | "plan_proposal" | "confirm",
  title: string,                // one-line heading
  body: string,                 // question / proposed plan / warning (markdown)
  options?: string[],           // optional preset answers (for kind="confirm" mostly)
  default?: string,             // preselected option
}
```

Execute:
- `question` → `const reply = await ctx.ui.editor(title, "")` →
  return `{ output: reply ?? "[cancelled]", details: {cancelled: !reply} }`.
- `plan_proposal` → extension tags the title with a
  `[sherpa-plan-proposal]` sentinel and calls `ctx.ui.editor`. Lua
  strips the sentinel and routes to a three-step flow:
  1. Read-only floating preview of the proposal.
  2. `vim.ui.select({"Accept", "Modify", "Reject"})`.
  3. Accept → return the plan text as-is. Modify → open the standard
     clarify editor prefilled for in-place edits; submit returns the
     edited text. Reject → return cancellation.
  Separates reading (wide preview pane) from authoring (compose editor)
  rather than cramming both into one small box.
- `confirm` → `const ok = await ctx.ui.confirm(title, body)` →
  return `{ output: ok ? "yes" : "no" }`.

The model reads the tool output and continues its turn with the user's
answer in context.

### Budget

Gated in the tool's `execute`:

```ts
if (state.clarifyCount >= 1) {
  return { output: "error: clarify budget exhausted for this turn", isError: true };
}
state.clarifyCount++;
```

Reset to 0 on `message_end` (turn boundary). One clarify per turn is
enough for most real cases. Prevents pathological "ask about
everything" behavior.

## Where it applies

Enable clarify for:
- **`prompt`** — broadest implementation, highest ambiguity payoff
- **`patch`** — small edits; lower value but cheap to include

Do NOT enable for:
- **`plan`** — review planning already *is* a planning turn; adding a
  second layer of clarification muddies it
- **`review`** — question turns are user-driven; clarifying a user
  question is circular
- **`search`** — read-only structured output; no ambiguity to resolve

Implementation: the tool is registered globally but its prompt-time
guidance only appears in `promptRules()` and `patchRules()`.

## Prompt guidance

Append to `promptRules()` and `patchRules()`:

```
If the request is genuinely ambiguous, or you've discovered the change
is much larger or more nuanced than the prompt implies, you MAY call
the `sherpa_clarify` tool once before proceeding.

Prefer action over questions. Only clarify when a specific ambiguity
would change your approach in a non-trivial way. Do NOT clarify about
preferences, style, or anything you can reasonably decide yourself.

Use `kind: "question"` for open-ended ambiguity, `kind: "plan_proposal"`
for a large change where the user should see the shape before you act,
`kind: "confirm"` for destructive or expensive operations.
```

## Lifecycle

1. User: `:SherpaChat add session revocation to the auth middleware`.
2. Plugin sends `/prompt ...`; pi starts the prompt turn.
3. Model reads some files, then calls `sherpa_clarify`:
   ```json
   {
     "kind": "question",
     "title": "Clarify session revocation scope",
     "body": "Two interpretations:\n1. Revoke on logout only\n2. Revoke on logout AND on password change\n\nWhich do you want?"
   }
   ```
4. Extension's `execute` calls `ctx.ui.editor("Clarify...", "")`.
5. pi emits `extension_ui_request` to Lua.
6. Plugin opens a floating editor with the question body shown as
   virt_lines hint, user types reply.
7. Plugin sends `extension_ui_response` with the reply text.
8. Extension tool resolves, returns the reply as tool output.
9. Model continues its turn with the reply in context.
10. Turn ends; `clarifyCount` resets.

On cancellation (user `<Esc><Esc>`):
- Plugin sends `{cancelled: true}`.
- Tool returns `{ output: "[user cancelled clarification]" }`.
- Model sees cancellation signal and usually aborts with a short "no
  changes made" reply. User can re-run the command with more context.

## Logging

Every clarify round-trip should leave breadcrumbs in `sherpa://log`:

- On tool start: `[sherpa] clarify (question): Clarify session revocation scope` (in addition to the standard `[tool] sherpa_clarify`).
- On user submit: `[user]` block with the response text.
- On cancel: `[sherpa] clarify cancelled`.

This keeps the session transcript coherent with what the user actually
saw/typed.

## Open questions

1. **Opt-out per request.** Flag like `:SherpaChat --no-ask <prompt>`
   or config `allow_clarification = false`. Worth adding if the model
   clarifies annoyingly often in practice. v1: skip, just rely on the
   budget + prompt.
2. **Dialog shape for `confirm`.** `vim.ui.select({"Yes","No"}, ...)`
   is lightweight but visually inconsistent with our floating editor.
   Alternative: reuse the floating editor with ghost-text "type 'yes'
   or 'no' and submit". Decide based on how it feels in use.
3. **Plan proposal: approve-as-is vs. edit-in-place.** I lean
   edit-in-place (open the proposal in a floating editor prefilled
   with the proposed text; user submits the text they want as the
   approved plan). Gives the user real authorial control.
4. **Cancellation handling downstream.** Model sees
   `"[user cancelled clarification]"` — we need the prompt to tell it
   "on cancellation, stop and produce a short summary of why you were
   asking". Otherwise the model might interpret cancellation as
   "proceed anyway", which is exactly wrong.

## Alternative: plan-first-work

Instead of a generic clarify tool, make planning the default for
`:SherpaChat`. Every work request goes:
`:SherpaChat` → `/plan-work` → `sherpa_work_plan` tool → user approves
or edits → model executes the approved plan.

Pros:
- Zero guesswork about "should I ask?" — every request plans.
- Mirrors the review flow (plan → execute) for architectural consistency.
- Gives the user a reliable approval gate on every change.

Cons:
- Heavier. Small changes get ceremony they don't need.
- Duplicates `sherpa_plan` conceptually — two plan tools for two modes.
- Works against small-patch ergonomics.

## Recommended v1 scope

**Do:**
1. Implement Lua-side handlers for `editor` and `confirm` UI methods.
2. Register `sherpa_clarify` with `kind: question | plan_proposal | confirm`.
3. One-call budget per turn, reset on `message_end`.
4. Prompt guidance in `promptRules` and `patchRules`.
5. Log the round-trip to `sherpa://log`.
6. Tests: fake_pi can emit a clarify call; plugin opens the editor;
   test harness submits a canned response; assert model "sees" it.

**Don't (v1):**
- `select` / `input` dialog handlers — add when needed.
- Opt-out flags — defer until real usage shows the need.
- Plan-first-work — separate, bigger change. Build clarify first and
  decide based on how it feels.
- Review / plan / search mode clarify support.

Estimated ~120 lines of code + tests.

## Related docs

- `docs/review-planning.md` — smwyg-style review refactor (context for
  why we prefer explicit tool calls over prose sentinels).
- `docs/architecture.md` — overall RPC event flow.
