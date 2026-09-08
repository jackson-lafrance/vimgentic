local function command(name, callback, options)
  vim.api.nvim_create_user_command(name, callback, options or {})
end

command("VimgenticSearch", function(args)
  require("vimgentic").search({ prompt = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "Search with pi and open quickfix" })

command("VimgenticVisual", function(args)
  require("vimgentic").visual({ prompt = args.args ~= "" and args.args or nil })
end, { nargs = "?", range = true, desc = "Replace the selected lines with pi" })

command("VimgenticChatToggle", function() require("vimgentic").chat_toggle() end, { desc = "Focus or open vimgentic chat" })
command("VimgenticChatClose", function() require("vimgentic").chat_close() end, { desc = "Hide vimgentic chat" })
command("VimgenticHistory", function() require("vimgentic").history() end, { desc = "Open pi session history" })
command("VimgenticOpen", function() require("vimgentic").reopen() end, { desc = "Reopen the last search quickfix" })
command("VimgenticAbortAll", function() require("vimgentic").abort_all() end, { desc = "Abort all vimgentic requests" })
command("VimgenticPickModel", function() require("vimgentic").pick_model() end, { desc = "Pick a model for each operation" })
command("VimgenticLogs", function() require("vimgentic").logs() end, { desc = "Open vimgentic logs" })
command("VimgenticTerminal", function() require("vimgentic").terminal() end, { desc = "Open the current chat in pi's terminal UI" })
