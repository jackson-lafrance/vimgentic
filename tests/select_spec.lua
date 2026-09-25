local select_ui = require("vimgentic.ui.select")

local function fixture(callback)
  local original_fzf, original_actions = package.loaded["fzf-lua"], package.loaded["fzf-lua.actions"]
  local picker
  package.loaded["fzf-lua"] = {
    fzf_exec = function(lines, options) picker = { lines = lines, options = options } end,
  }
  package.loaded["fzf-lua.actions"] = {
    act = function(selected, options) options.actions.enter(selected) end,
  }
  local choices = {}
  select_ui.open({ "Start new chat", "Cancel" }, { prompt = "Confirm replacement" }, function(item, position)
    table.insert(choices, { item = item, position = position })
  end)
  local ok, error_message = xpcall(function() callback(picker, choices) end, debug.traceback)
  package.loaded["fzf-lua"], package.loaded["fzf-lua.actions"] = original_fzf, original_actions
  assert(ok, error_message)
end

describe("vimgentic.ui.select", function()
  it("confirmations disable hiding and resumption so Escape cancels the action", function()
    fixture(function(picker, choices)
      eq({ "1. Start new chat", "2. Cancel" }, picker.lines)
      eq(true, picker.options.no_hide)
      eq(true, picker.options.no_resume)
      picker.options.fn_selected(nil, picker.options)
      wait_for(function() return #choices == 1 end)
      eq({ {} }, choices)
    end)
  end)

  it("selection returns the item once even when fzf completes again", function()
    fixture(function(picker, choices)
      picker.options.fn_selected({ picker.lines[1] }, picker.options)
      wait_for(function() return #choices == 1 end)
      picker.options.fn_selected(nil, picker.options)
      vim.wait(10)
      eq({ { item = "Start new chat", position = 1 } }, choices)
    end)
  end)
end)
