local M = {}

-- Confirmations must finish on Escape, not remain hidden in fzf's resume state.
function M.open(items, options, on_choice)
  options = options or {}
  local lines = {}
  for position, item in ipairs(items) do
    lines[position] = position .. ". " .. (options.format_item and options.format_item(item) or tostring(item))
  end
  local done = false
  local function finish(position)
    if done then return end
    done = true
    on_choice(position and items[position] or nil, position)
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = (options.prompt or "Select") .. "> ",
    no_hide = true,
    no_resume = true,
    previewer = false,
    fzf_opts = { ["--no-multi"] = "" },
    actions = {
      ["enter"] = function(selected)
        finish(selected[1] and tonumber(selected[1]:match("^(%d+)%.")))
      end,
    },
    fn_selected = vim.schedule_wrap(function(selected, picker_options)
      if selected then require("fzf-lua.actions").act(selected, picker_options) end
      if not done then finish() end
    end),
  })
end

return M
