local chat = require("vimgentic.ops.chat")
local selection = require("vimgentic.selection")
local util = require("vimgentic.util")

local M = {}

local actions = {
  {
    label = "Explain this code",
    prompt = table.concat({
      "Explain this existing code. Inspect relevant definitions and callers before describing behavior you cannot see here.",
      "Explain its role, data flow, and important failure cases using file and symbol references.",
      "Do not generate new code, replacement snippets, or patches. Do not edit files.",
      "Keep routine syntax brief; explain unfamiliar concepts through this code. Do not quiz me.",
    }, "\n"),
  },
  {
    label = "Plan the next change",
    prompt = table.concat({
      "Inspect the relevant code and use our current task to suggest the next small, complete change.",
      "Name the file and symbol, explain why the change belongs there, and state the behavior to preserve and check.",
      "Do not implement the change or generate replacement code yet.",
      "If the task is not clear from our conversation, ask one focused question instead of inventing work.",
    }, "\n"),
  },
}

function M.actions(options)
  local context, error_message = selection.capture(options)
  if not context then
    util.notify(error_message, vim.log.levels.WARN)
    return
  end
  vim.ui.select(actions, {
    prompt = "Vimgentic pair action",
    format_item = function(action) return action.label end,
  }, function(action)
    if action then
      chat.draft(action.prompt .. "\n\n" .. selection.render(context))
    end
  end)
end

return M
