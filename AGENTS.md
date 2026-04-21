# Sherpa is a guided, chunked code generation workflow for Neovim powered by pi

## Project intent

Sherpa is a Neovim-first interface for a pi-backed coding workflow.

The product should feel like disciplined pair programming:
- work in bounded chunks
- keep the user in Neovim
- jump to touched files
- stay linear by default
- pause for another question or chunk acceptance before continuing

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

- `:SherpaQ` starts or continues the current linear chunk flow.
- `:SherpaNext` accepts the current chunk or stop and advances linearly.
- Accepted chunks and tour stops should be recorded in pi's built-in history for future restoration work.
- Code chunks may mutate exactly one file.
- Review mode is read-only and should keep each stop to one file and one small section.
- The agent should stop after each bounded chunk or stop and wait for user input.
