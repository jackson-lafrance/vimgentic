# vimgentic

A native Neovim interface for [pi](https://github.com/earendil-works/pi-mono). Vimgentic uses pi's JSONL RPC mode, so search, visual rewrites, and chat keep pi's tools, extensions, skills, sessions, and model routing.

## Requirements

- Neovim 0.11 or newer with `vim.system`
- `pi` on `$PATH`
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) for history, model, fork, and completion pickers
- `fzf` for fzf-lua

## Install

```lua
vim.pack.add({
  "https://github.com/ibhagwan/fzf-lua",
  "https://github.com/jackson-lafrance/vimgentic",
})

require("vimgentic").setup({
  models = {
    search = nil, -- provider/model; nil uses pi's default
    visual = nil,
    chat = nil,
  },
  chat = {
    width = 0.45,
    show_thinking = false,
  },
})
```

Model choices made through `pick_model()` persist under `stdpath("data")/vimgentic/models.json` and override setup values.

## Suggested keymaps

```lua
local vimgentic = require("vimgentic")

vim.keymap.set("n", "<leader>9s", vimgentic.search, { desc = "Vimgentic: search" })
vim.keymap.set("x", "<leader>9v", vimgentic.visual, { desc = "Vimgentic: replace selection" })
vim.keymap.set("n", "<leader>9c", vimgentic.chat_toggle, { desc = "Vimgentic: chat focus" })
vim.keymap.set("x", "<leader>9c", vimgentic.chat_selection, { desc = "Vimgentic: send selection to chat" })
vim.keymap.set("n", "<leader>9C", vimgentic.chat_close, { desc = "Vimgentic: hide chat" })
vim.keymap.set("n", "<leader>9h", vimgentic.history, { desc = "Vimgentic: history" })
vim.keymap.set("n", "<leader>9o", vimgentic.reopen, { desc = "Vimgentic: reopen search" })
vim.keymap.set("n", "<leader>9x", vimgentic.abort_all, { desc = "Vimgentic: abort" })
vim.keymap.set("n", "<leader>9m", vimgentic.pick_model, { desc = "Vimgentic: pick model" })
vim.keymap.set("n", "<leader>9l", vimgentic.logs, { desc = "Vimgentic: logs" })
vim.keymap.set("n", "<leader>9T", vimgentic.terminal, { desc = "Vimgentic: terminal UI" })
```

## Search and visual rewrite

`search()` opens a prompt float. Write the prompt with `:w`. Pi searches from Neovim's current working directory and returns jumpable quickfix locations. `reopen()` restores the last search list.

`visual()` captures the selected line range, adds extmarks, and shows tool activity while pi works. It replaces the live range only after pi returns replacement code. A moved range stays tracked; a deleted range causes no edit.

Both operations create normal pi sessions and add them to vimgentic's session index.

## Chat

The right sidebar has a Markdown transcript and a multiline input buffer. Closing the sidebar hides its windows but keeps the RPC process alive.

| Key | Buffer | Action |
| --- | --- | --- |
| `<CR>` | input, normal | Submit; steer while pi streams |
| `<C-s>` | input, insert | Submit |
| `<C-f>` | input, normal | Queue a follow-up |
| `<C-f>` | input, insert | Pick a file under Neovim's cwd |
| `<Tab>` | transcript | Toggle the current thinking or tool fold |
| `<C-c>` | either | Abort the current agent operation |
| `q` | transcript | Hide the sidebar |

Type `!command` to run pi's RPC `bash` command. `@path` completion uses open buffers and `v:oldfiles`; it never runs `git ls-files`. Visual `chat_selection()` inserts an `@path:start-end` reference and a fenced copy of the selection.

### Slash commands

- `/model`, `/thinking`, `/compact`, `/new`, and `/name`
- `/session`, `/fork`, `/clone`, `/export`, and `/resume`
- `/tree`, `/abort`, and `/terminal`
- Pi extension commands, prompt templates, and skills from `get_commands`

`/terminal` stops the RPC process before it opens `pi --session <path>` in a terminal buffer. When the terminal exits, vimgentic reconnects through RPC and rebuilds the transcript.

## History

`history()` starts with vimgentic sessions for the current working directory.

- `ctrl-p` toggles all projects.
- `ctrl-a` toggles all pi sessions.
- `ctrl-q` restores a search session into quickfix.
- `ctrl-d` confirms and deletes a session with `trash`, when available.

Selecting a session switches the live chat process to that session. Session previews show the first user message and the last assistant message.

## Commands

Vimgentic defines `:VimgenticSearch`, `:VimgenticVisual`, `:VimgenticChatToggle`, `:VimgenticChatClose`, `:VimgenticHistory`, `:VimgenticOpen`, `:VimgenticAbortAll`, `:VimgenticPickModel`, `:VimgenticLogs`, and `:VimgenticTerminal`.

## Tests

```sh
make test
```

The suite runs with `nvim -l tests/run.lua` and has no plugin dependencies.

## License

MIT
