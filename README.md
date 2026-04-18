# sherpa

Sherpa is a Neovim plugin for guided, chunked code generation powered by pi.

It keeps the user in Neovim, lets pi make one bounded change at a time, jumps to touched files, and pauses for questions or revisions before continuing.

## Requirements

- Neovim 0.10+
- `pi` installed and available on `$PATH`
- a configured pi model/provider

## Install

### lazy.nvim

```lua
{
  dir = "~/dev/sherpa",
  config = function()
    require("sherpa").setup()
  end,
}
```

### packpath

Clone the repository into your Neovim package path and call:

```lua
require("sherpa").setup()
```

## Commands

- `:SherpaStart {goal}`
- `:SherpaQ {question}`
- `:SherpaRevise {feedback}`
- `:SherpaNext`
- `:SherpaStatus`

## Development

Sherpa loads the extension in `pi/sherpa-stepper.ts`.

From the repo root, you can start pi with just this extension loaded:

```bash
pi --no-extensions --extension ./pi/sherpa-stepper.ts
```

To mirror Sherpa's backend setup more closely, start pi in RPC mode:

```bash
pi --mode rpc --no-extensions --extension ./pi/sherpa-stepper.ts
```

## Notes

- Sherpa starts pi in RPC mode and loads `pi/sherpa-stepper.ts`.
- Assistant output is written to a scratch log buffer.
- File jumps currently follow `read`, `edit`, and `write` tool calls.
- Each chunk ends with a pause so you can ask questions, request revisions, or advance with `:SherpaNext`.
