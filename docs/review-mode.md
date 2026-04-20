# Review mode plan

## Summary

Sherpa should grow from a linear chunk tool into a small family of explicit workflows:

- `Work` for larger changes
- `Review` / `Teach` for interactive walkthroughs and questions
- `Patch` for selection-scoped edits
- `Search` for p99-style project search into a navigable result list

The key product shift is that teach should no longer be only a read-only variant of the chunk flow.
It should become a first-class review system that can be entered directly, especially after larger changes.

## Why change direction

Current Sherpa is strongest when work can be split into tiny reviewable chunks.
That is useful, but it is too narrow as the main product shape.

What we want instead:
- kick off larger prompts without constant interruption
- review changes afterward in an interactive `/teach` flow
- visually select a range and ask a question about that range
- leave comments during review and circle back later
- keep a p99-style precise edit tool for small local rewrites
- add p99-style search so the model can surface relevant code locations with notes

## What to borrow from p99

p99 has three especially relevant interaction types:

### 1. Search

`search()` asks the model to return project locations in a strict location format with notes.
Those results are opened in quickfix.

Useful traits to borrow:
- project-wide semantic/code search
- structured result format
- location list navigation
- short explanation per result
- easy jump into deeper follow-up actions

### 2. Tutorial

`tutorial()` produces a one-shot Markdown tutorial in its own split.

Useful traits to borrow:
- explicit explanation flow
- dedicated output surface
- not tied to mutation

### 3. Visual

`visual()` scopes work to the current visual selection and replaces that range.

Useful traits to borrow:
- visual selection as a first-class input
- highly bounded edits
- low-friction local operations

## How Sherpa and p99 are similar and different

## Similarities

- Both are Neovim-first AI workflows.
- Both benefit from explicit interaction types instead of one generic prompt box.
- Both want good editor-native navigation.
- Both are stronger when they keep context local and concrete.

## Differences today

### Sherpa today

Sherpa is now built around explicit flows:
- `:SherpaSearch`
- `:SherpaReview`
- `:SherpaPatch`
- `:SherpaWork`
- file jumps and range highlighting
- a dedicated review pane for walkthroughs

### p99 today

p99 splits interactions more explicitly:
- `search()` for result discovery into quickfix
- `tutorial()` for a one-shot explainer window
- `visual()` for selection-scoped replacement

p99's tutorial is similar to Sherpa teach mode in intent, but the UX shape is different.

## p99 tutorial vs Sherpa teach/review

### What is similar

Both are for explanation rather than code mutation.
Both can help a user understand a codebase or topic.

### What is different

p99 tutorial:
- is one-shot
- returns a Markdown tutorial buffer
- is not inherently stepwise
- is not centered on diff/review traversal
- does not appear to have built-in review comments or circle-back flow

Sherpa teach/review should be:
- multi-stop and interactive
- anchored to files and highlighted ranges
- able to explain a codebase, a diff, a file, or a selection
- able to pause for questions at each stop
- able to collect review comments and return to them later

So the plan is **not** to copy p99 tutorial exactly.
The plan is to borrow its explicitness while keeping Sherpa's stronger stepwise navigation and interaction loop.

## Proposed product model

### 1. Work mode

Purpose:
- larger prompts
- multi-file implementation
- less interruption

Example:
- `:SherpaWork implement session auth for the admin area`

Behavior:
- allow broader edits than the current one-file chunk model
- still encourage reasonable bounded progress, but not tiny forced stops
- record enough metadata to review the resulting diff afterward
- offer `:SherpaReview last` when complete

### 2. Review mode

Purpose:
- interactive walkthroughs
- post-change review
- codebase teaching
- selection/file/diff questions

Example entry points:
- `:SherpaReview last`
- `:SherpaReview diff`
- `:SherpaReview file`
- `:'<,'>SherpaReview why does this block matter?`
- `:SherpaReview auth flow`

Behavior:
- read-only
- navigates a list of review items
- jumps and highlights the active range
- explains one item at a time
- allows follow-up questions without leaving review mode
- supports comments that can be revisited after the full pass

Review items can come from:
- the last Sherpa work session
- git diff hunks
- search results
- a selected file or range
- an exploratory project tour request

### 3. Patch mode

Purpose:
- p99-style small edit abilities
- precise local changes

Examples:
- `:'<,'>SherpaPatch rewrite this function to remove mutation`
- `:'<,'>SherpaPatch add error handling here`

Behavior:
- selection-first
- very strong edit bounds
- ideal for local refactors or rewrites
- can be launched directly from a review comment

### 4. Search mode

Purpose:
- borrow p99 search directly
- find likely relevant code with notes
- serve as a navigation primitive for both work and review

Examples:
- `:SherpaSearch where is auth token refresh handled?`
- `:SherpaSearch show me all websocket entrypoints`

Behavior:
- return structured locations with short notes
- populate quickfix or location list
- jump to the selected result
- optionally start review from the results

Strong recommendation:
- start with the p99-style output contract of `path:line:column,count,notes`
- populate quickfix first
- later optionally add a richer Sherpa-native result list

## Recommended commands

### New commands

- `:SherpaWork {prompt}`
- `:SherpaSearch {prompt}`
- `:SherpaReview [scope] [prompt]`
- `:'<,'>SherpaPatch {prompt}`
- `:SherpaPrev`
- `:SherpaComment {text}`
- `:SherpaComments`

### Navigation

- keep `:SherpaNext`
- keep `:SherpaPrev`
- review should be the primary walkthrough surface

## Review mode UX

A review session should have a list of review items.
Each review item should include:
- file
- start/end line
- type: `change | search-result | selection | tour-stop`
- title
- short summary
- status: `pending | reviewed | commented | resolved`

### Core review loop

1. open review session
2. jump to current item
3. highlight range
4. explain item
5. allow follow-up question or comment
6. `:SherpaNext` / `:SherpaPrev` moves through the list
7. finish with a comment summary and possible follow-up actions

### Asking about a selected chunk

This should be first-class.

Flow:
1. user is in review mode
2. user visually selects a sub-range
3. user asks a question about the selection
4. Sherpa answers using:
   - selected text
   - surrounding file context
   - current review item context
   - original work goal when available

### Review comments

Comments should attach to either:
- the active review item
- or a smaller visual sub-range

Useful follow-up actions:
- jump through unresolved comments
- turn a comment into a patch request
- summarize unresolved comments at the end

For the first pass, comments are **local Sherpa review comments**.
They are not submitted anywhere.
At the end of a review, unresolved comments should be fed back to the agent as structured follow-up context so the agent can:
- answer open questions
- propose fixes
- turn comments into patch or work follow-ups

Important design constraint:
- leave room for a future GitHub review integration where Sherpa can load an existing PR review surface and eventually submit or sync comments
- do not implement GitHub submission/storage yet
- keep the local comment model general enough that a future external review source can map onto it

## Architecture direction

## Current state limitation

Current Sherpa state is optimized for exactly one open chunk/stop.
That is too narrow for review sessions with multiple items and comments.

## Proposed state shape

```ts
type SessionMode = "idle" | "work" | "review" | "patch" | "search";

type ReviewItem = {
  id: string;
  path: string;
  startLine: number;
  endLine: number;
  kind: "change" | "search-result" | "selection" | "tour-stop";
  title?: string;
  summary?: string;
  status: "pending" | "reviewed" | "commented" | "resolved";
};

type ReviewComment = {
  id: string;
  itemId: string;
  path: string;
  startLine: number;
  endLine: number;
  text: string;
  resolved: boolean;
  source?: "local" | "github";
  externalId?: string;
};
```

## Data sources for review items

### v1

Use sources that are already available or easy to derive:
- git diff hunks for `:SherpaReview diff`
- current file/range for file and selection review
- p99-style search results for search-driven review

### later

Add richer semantic grouping:
- group multiple hunks into one conceptual change
- connect review items back to the originating work prompt
- preserve review sessions in history

## Recommendation on search

Search should not be hidden inside teach mode.
It should be its own first-class primitive that review mode can consume.

That means:
- `Search` finds candidate locations
- `Review` walks them interactively
- `Patch` can edit one of them precisely
- `Work` can perform broader implementation

This matches the strongest parts of p99 while still leaving room for Sherpa's guided review identity.

## Additional p99 ideas worth borrowing

Beyond search, tutorial, and visual, there are a few more ideas worth borrowing in spirit.

### Skills / rules via prompt completion

p99 supports lightweight `#rule` insertion backed by `SKILL.md` files.
For Sherpa, this is largely already handled by pi.

Recommendation:
- do not build a separate Sherpa skill system in the first pass
- lean on pi's existing skill and instruction mechanisms
- only add Sherpa-specific UX later if prompt capture ergonomics need improvement

### `@file` prompt references

p99 supports `@file` completion and injects the referenced file content.
This is also a good fit for Sherpa prompts.

Recommendation:
- add `@file` completion in prompt capture
- start with git-aware file discovery
- cap file size and number of injected files
- use telescope or fzf for selection when the user wants a picker

### AGENTS / markdown context lookup

p99 walks upward and auto-adds files like `AGENT.md`.
For Sherpa, this also largely comes for free through pi.

Recommendation:
- do not build a parallel Sherpa-only instruction loading system
- rely on pi's project instruction handling
- consider better visibility later if users want to see what context pi injected

### Work memory / persistent work item

p99 has a lightweight worker concept that stores a work item and then runs search against it.
The exact implementation should not be copied, but the idea is useful.

Recommendation:
- allow a named current work item / goal
- make search and review aware of that current goal
- use it to ask `what is left?` after a work pass

### Telescope / fzf pickers

Assume telescope and fzf are available.
Sherpa should use them for:
- selecting review sessions
- selecting search result groups
- selecting unresolved comments
- choosing review scopes and referenced files

This should be treated as part of the main plan, not an optional add-on.

## Why Sherpa should probably not be a p99 fork

Even ignoring licensing, the architecture is different enough that a fork likely creates more friction than value.

p99 is built around:
- separate operations like `search`, `tutorial`, `visual`, `vibe`
- external AI CLIs behind its own operation layer
- temp-file based output contracts for some operations
- request history that can be reopened later

Sherpa is built around:
- pi RPC as the abstraction boundary
- streamed tool events
- extension-managed workflow state
- file jumps and range highlighting from live tool activity
- stepwise review / teach interaction

So the better move is:
- borrow UX ideas and product primitives from p99
- keep Sherpa's own pi-native architecture
- do not try to mechanically converge the codebases

## License note

At the time of review, the 99 repository did not appear to include a license file.
That usually means the code is not openly licensed for reuse, redistribution, or public forks by default.

Practical recommendation:
- do not fork or copy code unless a license is added or explicit permission is given
- treat 99 as product inspiration and a reference point
- implement Sherpa's version independently

## Milestones

### Milestone 1

Search:
- add `:SherpaSearch`
- use p99-style location output with notes
- populate quickfix/location list
- add telescope/fzf picker entry points over recent search results

### Milestone 2

Explicit review entry points:
- add `:SherpaReview`
- support `selection`, `file`, `diff`, and `last`
- allow read-only questions on a selected range
- support `:SherpaPrev`
- allow `Teach from search results`

### Milestone 3

Comments:
- add `:SherpaComment`
- persist comments in session state
- mark comments visually
- summarize unresolved comments at the end of review
- feed unresolved comments back to the agent as structured end-of-review context
- add telescope/fzf navigation for unresolved comments and review items
- keep comment data shaped so a future GitHub PR review integration can map onto it

### Milestone 4

Patch:
- add `:SherpaPatch`
- selection-scoped edit prompt
- support comment -> patch flow

### Milestone 5

Broader work mode:
- add `:SherpaWork`
- support larger implementation runs
- auto-offer review after work completes
- optionally keep a lightweight current work item in Sherpa state

## Non-goals for the first pass

- perfect semantic grouping of changes
- full workspace restoration
- replacing quickfix with a custom UI immediately
- building all mode types before search/review basics are solid
- building a separate Sherpa skill system
- building a separate Sherpa AGENTS/instruction loader
- implementing GitHub PR comment submission/storage in the first pass

## Recommendation

Short version:
- adopt p99-style `Search`
- keep Sherpa's stepwise strength for `Review`
- keep selection-first local edits for `Patch`
- move larger prompts into `Work`
- treat current tiny chunking as a specialized tool, not the whole product
