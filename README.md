# vimgentic

A Neovim interface for [pi](https://github.com/earendil-works/pi-mono). Search and visual rewrites use pi's JSONL RPC mode. Chat runs pi's native interactive UI in a right-hand terminal sidebar.

## Requirements

- Neovim 0.11 or newer with `vim.system`
- `pi` on `$PATH`
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) for history and model pickers
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
    chat = nil,   -- initial model for the terminal
  },
  chat = {
    width = 0.45,
  },
})
```

Model choices made through `pick_model()` persist under `stdpath("data")/vimgentic/models.json` and override setup values.

## Suggested keymaps

```lua
local vimgentic = require("vimgentic")

vim.keymap.set("n", "<leader>9s", vimgentic.search, { desc = "Vimgentic: search" })
vim.keymap.set("x", "<leader>9v", vimgentic.visual, { desc = "Vimgentic: replace selection" })
vim.keymap.set("n", "<leader>9c", vimgentic.chat_toggle, { desc = "Vimgentic: terminal focus" })
vim.keymap.set("x", "<leader>9c", vimgentic.chat_selection, { desc = "Vimgentic: send selection to chat" })
vim.keymap.set("n", "<leader>9C", vimgentic.chat_close, { desc = "Vimgentic: hide terminal" })
vim.keymap.set("n", "<leader>9h", vimgentic.history, { desc = "Vimgentic: history" })
vim.keymap.set("n", "<leader>9o", vimgentic.reopen, { desc = "Vimgentic: reopen search" })
vim.keymap.set("n", "<leader>9x", vimgentic.abort_all, { desc = "Vimgentic: abort" })
vim.keymap.set("n", "<leader>9m", vimgentic.pick_model, { desc = "Vimgentic: pick model" })
vim.keymap.set("n", "<leader>9l", vimgentic.logs, { desc = "Vimgentic: logs" })
```

## Search and visual rewrite

`search()` opens a prompt float. Write the prompt with `:w`. Pi searches from Neovim's current working directory and returns jumpable quickfix locations. `reopen()` restores the last search list.

`visual()` captures the selected line range, adds extmarks, and shows tool activity while pi works. It replaces the live range only after pi returns replacement code. A moved range stays tracked; a deleted range causes no edit.

Both operations create normal pi sessions and add them to vimgentic's session index.

## Terminal chat

`chat_toggle()` opens interactive `pi` in one right-hand Neovim terminal window. The terminal gives direct access to Pi's transcript, editor, tools, slash commands, extensions, settings, tree, login, and other native UI features.

Closing the sidebar hides its window but leaves the terminal job alive. Opening it again restores the same process and screen.

- `<leader>9c` opens the sidebar or switches focus between the editor and sidebar.
- `<leader>9C` hides the sidebar without stopping pi.
- `q` hides the sidebar after entering terminal-normal mode with `<C-\><C-n>`.
- `<leader>9x` sends Ctrl-C to pi and aborts RPC search or visual requests.
- `chat_selection()` inserts `@path:start-end` and the selected text through bracketed paste.

Use Pi's native commands such as `/model`, `/thinking`, `/tree`, `/settings`, `/hotkeys`, `/share`, and `/login` directly. The chat choice in `pick_model()` sends Pi's native `/model` command when the terminal runs.

## History

`history()` starts with vimgentic sessions for the current working directory.

- `ctrl-p` toggles all projects.
- `ctrl-a` toggles all pi sessions.
- `ctrl-q` restores a search session into quickfix.
- `ctrl-d` confirms and deletes a session with `trash`, when available.

Selecting a session stops the current terminal job before it starts `pi --session <path>`. Session previews show the first user message and the last assistant message.

## Commands

Vimgentic defines `:VimgenticSearch`, `:VimgenticVisual`, `:VimgenticChatToggle`, `:VimgenticChatClose`, `:VimgenticHistory`, `:VimgenticOpen`, `:VimgenticAbortAll`, `:VimgenticPickModel`, `:VimgenticLogs`, and `:VimgenticTerminal`.

`:VimgenticTerminal` is an alias for the terminal sidebar toggle.

## Tests

```sh
make test
```

The suite runs with `nvim -l tests/run.lua` and has no plugin dependencies.

## License

MIT
