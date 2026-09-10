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
  pairing = {
    enabled = false, -- opt in to intent-based guidance for native chat sessions
  },
})
```

Model choices made through `pick_model()` persist under `stdpath("data")/vimgentic/models.json` and override setup values.

## Suggested keymaps

```lua
local vimgentic = require("vimgentic")

vim.keymap.set("n", "<leader>9s", vimgentic.search, { desc = "Vimgentic: search" })
vim.keymap.set("x", "<leader>9v", vimgentic.visual, { desc = "Vimgentic: request replacement" })
vim.keymap.set("n", "<leader>9v", vimgentic.visual_preview, { desc = "Vimgentic: preview replacement" })
vim.keymap.set({ "n", "x" }, "<leader>9p", vimgentic.pair, { desc = "Vimgentic: pair actions" })
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

`visual()` captures the selected lines from the live buffer, including unsaved changes, and shows tool activity while pi works. All visual modes use whole lines. `:2,5VimgenticVisual <request>` uses the explicit line range.

1. Request a replacement with `visual()` or visual-mode `<leader>9v`.
2. Wait for the ready notification. The reply does not change the source or take focus.
3. Use `visual_preview()`, `:VimgenticVisualPreview`, or normal-mode `<leader>9v` in the source buffer to open the diff.
4. Press Enter to accept, or `q`/Escape to discard. Acceptance changes the buffer, not the file on disk.

The preview compares the original selected text with the live range again at acceptance. Edits outside the range can move it safely. Changed text, a deleted range, a renamed buffer, or a readonly buffer prevents application. A newer request in the same buffer discards the older pending replacement; late replies cannot revive it. A request that already runs can finish in the background.

Visual requests allow only Pi's `read`, `grep`, `find`, and `ls` tools. They cannot use Pi's normal editing or shell tools before acceptance. This is a tool allowlist, not an operating-system sandbox; trusted extensions still run in the Pi process. Search and native chat keep their existing tools.

Both operations create normal pi sessions and add them to vimgentic's session index. Saving a source file does not start an agent turn.

## Pair programming

`pair()` or `:VimgenticPair` offers two actions:

- **Explain this code:** inspect relevant definitions and callers, explain the existing behavior, and do not generate new code or edit files.
- **Plan the next change:** inspect the relevant code, suggest one complete step and its check, and ask for the task if the conversation does not establish one.

The action pastes an editable draft into Pi's existing native input. It does not submit the draft or clear existing input. Press Enter in Pi when the request is ready. Visual mode uses the selected whole lines; normal mode includes up to twenty lines on either side of the cursor. Each draft includes an absolute path, line range, and snapshot of the live buffer. The action picker never captures terminal or scratch buffers.

Set `pairing.enabled = true` to add the bundled `pi/pairing.md` guidance to chat sessions that Vimgentic starts or resumes. The small Pi extension appends it before each agent turn without replacing project instructions. It does not change global Pi files or sessions started outside Vimgentic. Restart the terminal process after you change this setting; hiding the sidebar does not restart it.

The guidance follows request intent: explanation requests stay explanations; explicit requests to fix, implement, or write tests authorize that named work. Broad problems start with inspection, while precise edits do not trigger a new approval loop or lesson. Existing approvals for major decisions still apply. This guidance is not a technical write barrier: chat retains its editing and shell tools.

## Terminal chat

`chat_toggle()` opens interactive `pi` in one right-hand Neovim terminal window. The terminal gives direct access to Pi's transcript, editor, tools, slash commands, extensions, settings, tree, login, and other native UI features.

Closing the sidebar hides its window but leaves the terminal job alive. Opening it again restores the same process and screen.

- `<leader>9c` opens the sidebar or switches focus between the editor and sidebar.
- `<leader>9C` hides the sidebar without stopping pi.
- Escape in the sidebar enters terminal-normal mode; `i` or `a` returns to terminal-insert mode.
- `q` hides the sidebar from terminal-normal mode.
- `<leader>9x` sends Ctrl-C to pi and aborts RPC search or visual requests.
- `chat_selection()` inserts the absolute path, line range, and live selected text through bracketed paste without submitting it.

Drafts with terminal control characters are rejected before anything is sent. Newlines and tabs are supported.

Use Pi's native commands such as `/model`, `/thinking`, `/tree`, `/settings`, `/hotkeys`, `/share`, and `/login` directly. The chat choice in `pick_model()` sends Pi's native `/model` command when the terminal runs.

## History

`history()` starts with vimgentic sessions for the current working directory. That list includes sessions the chat terminal switched to with `/new`, `/fork`, or `/resume` inside pi: the bundled `pi/session-log.js` extension appends each session file the terminal runs to `stdpath("data")/vimgentic/session-log.jsonl`, and `history()` folds new entries into the index before it opens.

- `ctrl-p` toggles all projects.
- `ctrl-a` toggles all pi sessions.
- `ctrl-q` restores a search session into quickfix.
- `ctrl-d` confirms and deletes a session with `trash`, when available.

Selecting a session stops the current terminal job before it starts `pi --session <path>`. Session previews show the first user message and the last assistant message.

## Commands

Vimgentic defines `:VimgenticSearch`, `:VimgenticVisual`, `:VimgenticVisualPreview`, `:VimgenticPair`, `:VimgenticChatToggle`, `:VimgenticChatClose`, `:VimgenticHistory`, `:VimgenticOpen`, `:VimgenticAbortAll`, `:VimgenticPickModel`, `:VimgenticLogs`, and `:VimgenticTerminal`.

`:VimgenticTerminal` is an alias for the terminal sidebar toggle.

## Tests

```sh
make test
```

The suite runs with `nvim -l tests/run.lua` and has no plugin dependencies.

## License

MIT
