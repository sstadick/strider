# sherpa

Sherpa is a Neovim plugin for linear, chunked code generation powered by pi.

It keeps the user in Neovim, executes one bounded chunk at a time, jumps to touched files, and pauses between accepted checkpoints.

## Requirements

- Neovim 0.10+
- `pi` installed and available on `$PATH`
- a configured pi model/provider

## Install

### Local plugin development

Add the repository to your runtime path and load the plugin:

```lua
vim.opt.rtp:append(vim.fn.expand("~/dev/sherpa"))
vim.cmd("runtime plugin/sherpa.lua")
require("sherpa").setup()
```

## Commands

- `:SherpaQ {request}` — start or continue the current linear chunk flow
- `:SherpaNext` — accept the current chunk and continue to the next one
- `:SherpaChangeNext` — jump to the next changed line in the current chunk
- `:SherpaChangePrev` — jump to the previous changed line in the current chunk

## Development

Sherpa loads the extension in `pi/sherpa-stepper.ts`.

From the repo root, you can start pi with only this extension loaded:

```bash
pi --no-extensions --extension ./pi/sherpa-stepper.ts
```

To mirror Sherpa's backend setup more closely, start pi in RPC mode:

```bash
pi --mode rpc --no-extensions --extension ./pi/sherpa-stepper.ts
```

## Notes

- Sherpa uses pi's built-in session history and labels accepted chunks as checkpoints.
- Assistant output is written to a scratch log buffer.
- File jumps currently follow `read`, `edit`, and `write` tool calls.
- Sherpa keeps an open chunk state and shows when a chunk is waiting for `:SherpaNext`.
- Sherpa asks the model to work in the smallest reviewable chunks it can manage.
- A chunk may mutate exactly one file. If another file needs changes, that becomes the next chunk.
- Final chunks can end the workflow cleanly without asking for another chunk after acceptance.
- Code restoration is not implemented yet; checkpoints are history anchors for now, not workspace restores.
