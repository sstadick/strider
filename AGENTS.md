# Sherpa is a guided, chunked code generation workflow for Neovim powered by pi

## Project intent

Sherpa is a Neovim-first interface for a pi-backed coding workflow.

The product should feel like disciplined pair programming:
- work in bounded chunks
- keep the user in Neovim
- jump to touched files
- pause for questions, revisions, or approval before continuing

## Code Conventions

- Files should not be larger than 500 lines unless there is a very compelling reason.
- Functions should not be larger then 30 lines without reason.
- Composition over inheritance.
- Keep objects small and data oriented.

## Architecture guidance

- Keep workflow logic in the pi extension when possible.
- Keep Neovim-specific UX and transport logic in the Lua client.
- Prefer explicit data flow and small modules over large abstractions.
- Start with the minimum viable RPC loop before building richer UI.

## Product rules

- `:SherpaQ` is a non-progressing question turn about the current chunk.
- `:SherpaRevise` modifies the current chunk without advancing.
- `:SherpaNext` advances only after the current chunk has paused.
- The agent should stop after each bounded chunk and wait for user input.
