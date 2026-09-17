# vimgentic

A Neovim interface for [pi](https://github.com/earendil-works/pi-mono). Search, local reviews, guided tours, and visual rewrites use pi's JSONL RPC mode. Chat runs pi's native interactive UI in a right-hand terminal sidebar.

## Requirements

- Neovim 0.11 or newer with `vim.system`
- LuaJIT on macOS or Linux for the session index's operating-system lock
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
    review = nil,
    tour = nil,
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
vim.keymap.set({ "n", "x" }, "<leader>9r", vimgentic.review, { desc = "Vimgentic: local review" })
vim.keymap.set("n", "<leader>9R", vimgentic.review_open, { desc = "Vimgentic: open review" })
vim.keymap.set({ "n", "x" }, "<leader>9t", vimgentic.tour, { desc = "Vimgentic: code tour" })
vim.keymap.set("n", "<leader>9g", vimgentic.tour_open, { desc = "Vimgentic: open tour" })
vim.keymap.set("n", "<leader>9j", vimgentic.tour_next, { desc = "Vimgentic: next tour stop" })
vim.keymap.set("n", "<leader>9k", vimgentic.tour_prev, { desc = "Vimgentic: previous tour stop" })
vim.keymap.set("x", "<leader>9v", vimgentic.visual, { desc = "Vimgentic: request replacement" })
vim.keymap.set("n", "<leader>9v", vimgentic.visual_preview, { desc = "Vimgentic: preview replacement" })
vim.keymap.set({ "n", "x" }, "<leader>9p", vimgentic.pair, { desc = "Vimgentic: pair actions" })
vim.keymap.set("n", "<leader>9e", vimgentic.explain_error, { desc = "Vimgentic: explain diagnostic" })
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

## Explain this error

`explain_error()`, `:VimgenticExplainError`, or `<leader>9e` prepares an editable chat draft for the diagnostic under the cursor. If the cursor is outside the diagnostic's highlighted range, it uses diagnostics on the current line. Multiple matches open a picker; no match produces a notification without opening chat.

The draft contains the verbatim diagnostic message, severity, source, code, location, and up to twenty live-buffer lines on each side of the cursor. It captures the diagnostic and code before the picker opens, so later edits cannot mix different versions of the context. Warnings and informational diagnostics work too.

The draft asks for an evidence-based explanation, not an automatic fix. It does not submit the request, clear Pi's input, or change the source buffer. Press Enter in Pi when the draft is ready. Chat retains its normal tools; the explanation-only instruction is not a sandbox.

## Background reviews and guided tours

`review()` and `tour()` open a prompt for a target and focus. Both run while you edit, show tool activity, and notify on completion. Completion does not open a report, replace quickfix, or take focus.

1. Start a local review with `<leader>9r`, or a tour with `<leader>9t`.
2. Name the files, selection, Git comparison, or code flow. Submit the prompt with `:w`.
3. Open a completed review with `<leader>9R`, or start the completed tour with `<leader>9g`.
4. In a review, press Enter inside a location section to jump. In a tour, use the Left/Right arrows in normal mode.

### The tour player

Opening a tour moves the editor directly to its first stop. The editor highlights the active line range; a panel on the right shows **Step N of M** and that range's explanation. Each arrow step opens the next file or range in the same editor window, moves the highlight, and replaces the side explanation. The player never inserts comments into source files.

- **Right / Left:** next / previous stop, in normal mode in the tour editor or side panel. Up/Down and insert-mode arrows keep their normal behavior.
- **Escape:** exit tour mode. `q` in the panel, `tour_close()`, and `:VimgenticTourClose` also exit. Cleanup removes the highlight and restores prior editor mappings.
- **`g?` in the panel:** toggle the tour overview. Arrow navigation returns to the current step's explanation.
- **`gq` in the panel:** exit the player and open all tour stops in quickfix.

Tour stops preserve narrative order, including multiple ranges within one file and later returns to that file. `<leader>9j` / `<leader>9k` and `]t` / `[t` in the panel also navigate. Each tab keeps its own active tour; completion of another request does not replace the tour you currently walk. The open command selects the latest completed tour and resumes its previous stop when available. Closing either player window exits tour mode. A tour without usable locations shows its scope question or raw report instead.

### Review reports

Review reports retain Enter to jump, `]t` / `[t` for next / previous, `gq` for quickfix, and `q` to close. `review_quickfix()` / `:VimgenticReviewQuickfix` opens findings directly. Review and tour quickfix lists do not replace the remembered search list. The open commands restore the latest completed result for the current project; a running or failed request does not clear the previous result. History can select an older review or tour.

### Context and boundaries

Both operations capture Neovim's directory before the prompt opens. Visual mode and explicit command ranges also capture selected whole lines, including unsaved edits. Normal mode supplies the current filename as a reference, not an implicit review scope; it does not supply buffer text. Save a file before requesting a disk review, or select the unsaved lines you want to review.

Examples from the Vimgentic checkout:

```vim
:VimgenticReview Review lua/vimgentic/chat/terminal.lua for lifecycle races.
:VimgenticReview Review unstaged changes in lua/vimgentic/ops for error handling.
:2,5VimgenticReview Review this selection for boundary errors.
:VimgenticTour Trace :VimgenticSearch from its command to quickfix.
```

Reviews use the bundled `review-local` skill and its checklist. Vimgentic explicitly loads it with `--skill`, checks the registered skill's path, and invokes `/skill:review-local`. A missing or shadowed skill stops the request. An ambiguous target returns a scope question in the report; a clean review needs no findings. Malformed model output remains readable, with a warning and no guessed jump coordinates.

**Reviews and tours keep normal Pi tools, including shell and editing tools.** Their no-edit, local-only boundaries are agent instructions, not a sandbox. Project instructions and loaded extensions still apply. Vimgentic does not automatically approve extension dialogs: a background dialog cancels the request and reports the need for input. `<leader>9x` / `:VimgenticAbortAll` abort these requests too.

Locations retain their source: working tree, editor snapshot, index, or revision. Jumps always open current buffers; they do not reconstruct Git versions or remap old line numbers. Review jumps warn for historical sources or a missing/mismatched source-line anchor; the tour player shows these warnings in its side panel. An anchor match checks one line, not the whole finding. Quickfix labels this limitation; native `:cnext` does not run the extra Enter checks. Check the evidence against current code before acting on a finding.

`models.review` and `models.tour` select independent models; unset values use Pi's default. Both appear in the model picker and session history. Results stay in memory for quick reopening; after a restart, use history's `ctrl-r` to read the saved session response.

## Local review skill

`skills/review-local/SKILL.md` provides a local-only review workflow based on the same evidence-first approach as a PR review. It covers named files, symbols, selections, and explicitly scoped Git changes without a GitHub PR. Its checklist covers correctness, concurrency, security, persistence, tests, and architectural fit.

The skill instructs Pi to inspect code without editing files, running project commands, or contacting GitHub. This is an instruction policy, not a sandbox. Findings include severity, file locations, evidence, suggested corrections, and confidence. Editor snapshots and changing source receive explicit provenance and stale-location notes.

The skill is bundled, not installed globally. The background review command loads it explicitly. To use it manually from your project directory with a checkout at `~/vimgentic`:

```sh
pi --skill ~/vimgentic/skills/review-local
```

Then invoke `/skill:review-local` with an explicit target and focus. For example, inside the Vimgentic checkout:

```text
/skill:review-local Review lua/vimgentic/chat/terminal.lua for lifecycle races.
```

## Terminal chat

`chat_toggle()` opens interactive `pi` in one right-hand Neovim terminal window. The terminal gives direct access to Pi's transcript, editor, tools, slash commands, extensions, settings, tree, login, and other native UI features.

Closing the sidebar hides its window but leaves the terminal job alive. Opening it again restores the same process and screen.

When Neovim's directory differs from the chat directory, the next sidebar open, draft, or active model command asks before switching projects. **Switch project** stops Pi and starts a new chat in Neovim's directory. Saved sessions remain in history, but the switch interrupts any running task and loses unsent terminal input. **Keep current chat** continues the requested action in the existing chat. Cancel leaves the process and its input untouched.

The bundled extension reports native `/new`, `/fork`, and `/resume` changes to a private per-terminal state file. Vimgentic reads it asynchronously while Pi runs, before chat actions, and after Pi exits. Reopening an exited terminal resumes its latest session, not its startup session. Reports from an earlier terminal process cannot overwrite a newer session selection.

- `<leader>9c` opens the sidebar or switches focus between the editor and sidebar.
- `<leader>9C` hides the sidebar without stopping pi.
- Escape in the sidebar enters terminal-normal mode; `i` or `a` returns to terminal-insert mode.
- `q` hides the sidebar from terminal-normal mode.
- `<leader>9x` sends Ctrl-C to pi and aborts RPC search, review, tour, or visual requests.
- `chat_selection()` inserts the absolute path, line range, and live selected text through bracketed paste without submitting it.

Drafts with terminal control characters are rejected before anything is sent. Newlines and tabs are supported.

Use Pi's native commands such as `/model`, `/thinking`, `/tree`, `/settings`, `/hotkeys`, `/share`, and `/login` directly. The chat choice in `pick_model()` sends Pi's native `/model` command when the terminal runs.

## History

`history()` starts with vimgentic sessions for the current working directory. That list includes sessions the chat terminal switched to with `/new`, `/fork`, or `/resume` inside pi: the bundled `pi/session-log.js` extension appends each session file the terminal runs to `stdpath("data")/vimgentic/session-log.jsonl`, and `history()` folds new entries into the index before it opens.

- `ctrl-p` toggles all projects.
- `ctrl-a` toggles all pi sessions.
- `ctrl-r` opens a review report or starts the tour player from the session's last assistant response.
- `ctrl-q` restores search, review, or tour locations into quickfix.
- `ctrl-d` confirms and deletes a session with `trash`, when available.

Selecting a session stops the current terminal job before it starts `pi --session <path>` in that session's directory. This does not change Neovim's directory. Session previews show the first user message and the last assistant message.

Index updates and pruning share an operating-system lock at `stdpath("data")/vimgentic/sessions.json.lock`. Contending instances wait asynchronously for up to five seconds, then report a timeout without writing. The operating system releases the lock if Neovim crashes. The JSON index format stays unchanged. Do not delete the lock file while Neovim runs: its stable identity keeps all instances on the same lock.

Restart every Neovim instance after this update; older plugin instances do not use the lock. Save your buffers and finish running Pi tasks before restarting.

## Commands

Vimgentic defines `:VimgenticSearch`, `:VimgenticVisual`, `:VimgenticVisualPreview`, `:VimgenticPair`, `:VimgenticExplainError`, `:VimgenticChatToggle`, `:VimgenticChatClose`, `:VimgenticHistory`, `:VimgenticOpen`, `:VimgenticAbortAll`, `:VimgenticPickModel`, `:VimgenticLogs`, and `:VimgenticTerminal`.

Background commands: `:VimgenticReview [prompt]`, `:VimgenticTour [prompt]`, `:VimgenticReviewOpen`, and `:VimgenticTourOpen`. Both start commands accept a line range. Navigation commands: `:VimgenticReviewQuickfix`, `:VimgenticTourNext`, `:VimgenticTourPrev`, and `:VimgenticTourClose`.

`:VimgenticTerminal` is an alias for the terminal sidebar toggle.

## Tests

```sh
make test
```

The Lua suite runs with `nvim -l tests/run.lua`, including concurrent Neovim writers and lock recovery after a killed process. Extension tests run with `node --test tests/session_log_spec.js`. Neither suite needs plugin dependencies or a model connection.

## License

MIT
