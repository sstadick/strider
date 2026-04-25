# Strider is a guided code workflow for Neovim powered by pi

## Project intent

A Neovim-first interface for a pi-backed coding workflow.

The product should feel like disciplined pair programming:
- work in bounded chunks
- keep the user in Neovim
- jump to touched files
- stay linear by default
- pause for a question, a plan proposal, or a stop acceptance before
  continuing

## Code conventions

- Files should not exceed 500 lines without a compelling reason.
- Functions should not exceed 30 lines without reason.
- Composition over inheritance.
- Keep objects small and data oriented.

## Architecture guidance

- Keep workflow logic in the pi extension when possible.
- Keep Neovim-specific UX and transport logic in the Lua client.
- Prefer explicit data flow and small modules over large abstractions.
- Start with the minimum viable RPC loop before building richer UI.

## Product rules

- `:StriderReview` is the primary walkthrough surface. Reviews are
  pre-planned via the `strider_plan` tool; navigation is mechanical.
- `:StriderNext` advances through the planned stops; `:StriderPrev`
  walks back.
- Review mode is read-only — one file, one small section per stop.
- `:StriderPatch` is selection-scoped and intended for small local edits.
- `:StriderChat` is the agent catch-all; slash-commands typed into the
  compose buffer (e.g. `/models`, `/tree`) are routed to pi extensions.
- Accepted stops and reviewed chunks are recorded in pi's session
  history for future restoration work.
- The agent should stop after each bounded chunk or stop and wait for
  user input.
