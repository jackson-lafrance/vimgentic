local util = require("vimgentic.util")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory .. "/vimgentic", "p")
  local target = directory .. "/vimgentic/models.json"
  vim.fn.writefile({ vim.json.encode({ search = "provider/previous" }) }, target)
  local original_models = package.loaded["vimgentic.pi.models"]
  local original_fzf = package.loaded["fzf-lua"]
  local original_stdpath, original_system, original_notify = vim.fn.stdpath, vim.system, util.notify
  local state = { notices = {} }
  vim.fn.stdpath = function(kind)
    if kind == "data" then return directory end
    return original_stdpath(kind)
  end
  vim.system = function(command, _, on_exit)
    state.command = command
    on_exit({ code = 0, stdout = "provider model\nopenai chosen\n" })
  end
  package.loaded["fzf-lua"] = {
    fzf_exec = function(entries, options)
      state.entries, state.options = entries, options
    end,
  }
  util.notify = function(message) table.insert(state.notices, message) end
  package.loaded["vimgentic.pi.models"] = nil
  local ok, error_message = xpcall(function()
    local models = require("vimgentic.pi.models")
    models.setup({ search = "provider/configured" })
    wait_for(function() return models.get("search") == "provider/previous" end)
    callback(models, state, target)
  end, debug.traceback)
  package.loaded["vimgentic.pi.models"] = original_models
  package.loaded["fzf-lua"] = original_fzf
  vim.fn.stdpath, vim.system, util.notify = original_stdpath, original_system, original_notify
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.pi.models picker", function()
  it("selecting pi default clears the model and persists a default override", function()
    fixture(function(models, state, target)
      local completed, chosen = false, "not called"
      models.pick("search", function(model)
        completed, chosen = true, model
      end)
      wait_for(function() return state.options ~= nil end)
      eq("(pi default)", state.entries[1])
      state.options.actions.enter({ "(pi default)" })
      wait_for(function() return completed end)
      eq(nil, chosen)
      eq(nil, models.get("search"))
      eq({ search = vim.NIL }, vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
      eq({ "search model: pi default" }, state.notices)
      models.setup({ search = "provider/configured" })
      wait_for(function() return models.get("search") == nil end)
    end)
  end)

  it("selecting a model persists its provider and model identifier", function()
    fixture(function(models, state, target)
      local chosen
      models.pick("search", function(model) chosen = model end)
      wait_for(function() return state.options ~= nil end)
      truthy(vim.tbl_contains(state.entries, "openai/chosen"))
      state.options.actions.enter({ "openai/chosen" })
      wait_for(function() return chosen ~= nil end)
      eq("openai/chosen", chosen)
      eq("openai/chosen", models.get("search"))
      eq({ search = "openai/chosen" }, vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
    end)
  end)

  it("review and tour model choices persist independently", function()
    fixture(function(models, state, target)
      for _, kind in ipairs({ "review", "tour" }) do
        local chosen
        state.options = nil
        models.pick(kind, function(model) chosen = model end)
        wait_for(function() return state.options ~= nil end)
        state.options.actions.enter({ "openai/chosen" })
        wait_for(function() return chosen ~= nil end)
        eq("openai/chosen", models.get(kind))
      end
      eq({ search = "provider/previous", review = "openai/chosen", tour = "openai/chosen" },
        vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
    end)
  end)

  it("cancelling the picker preserves the previous model without a callback", function()
    fixture(function(models, state, target)
      local called = false
      models.pick("search", function() called = true end)
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({})
      eq(false, called)
      eq("provider/previous", models.get("search"))
      eq({ search = "provider/previous" }, vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
      eq({}, state.notices)
    end)
  end)
end)
