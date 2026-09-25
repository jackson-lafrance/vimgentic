local util = require("vimgentic.util")
local rpc = require("vimgentic.pi.rpc")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory .. "/vimgentic", "p")
  local target = directory .. "/vimgentic/models.json"
  vim.fn.writefile({ vim.json.encode({ search = "provider/previous" }) }, target)
  local original_models = package.loaded["vimgentic.pi.models"]
  local original_fzf = package.loaded["fzf-lua"]
  local original_stdpath, original_system, original_notify = vim.fn.stdpath, vim.system, util.notify
  local original_rpc = rpc.new
  local state = { notices = {}, queries = {}, writes = {}, closed = 0, levels = { "off", "low", "medium", "high" } }
  rpc.new = function(options)
    state.rpc_options = options
    return {
      on_event = function(_, callback)
        state.event = callback
        return function() state.unsubscribed = true end
      end,
      send = function(_, command, callback)
        table.insert(state.queries, command)
        if state.defer_response then
          state.reply = callback
        else
          callback(state.response or { success = true, data = { levels = state.levels } })
        end
      end,
      close = function() state.closed = state.closed + 1 end,
      write = function(_, message) table.insert(state.writes, message) end,
    }
  end
  vim.fn.stdpath = function(kind)
    if kind == "data" then return directory end
    return original_stdpath(kind)
  end
  vim.system = function(command, _, on_exit)
    state.command = command
    on_exit({ code = 0, stdout = state.output or "provider model\nopenai chosen\n" })
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
  rpc.new = original_rpc
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
      eq("Thinking for search> ", state.options.prompt)
      eq("provider/previous", models.get("search"))
      state.options.actions.enter({ "(pi default)" })
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
        state.options.actions.enter({ "(pi default)" })
        wait_for(function() return chosen ~= nil end)
        eq("openai/chosen", models.get(kind))
      end
      eq({ search = "provider/previous", review = "openai/chosen", tour = "openai/chosen" },
        vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
    end)
  end)

  it("the thinking picker shows Pi's supported levels and persists the selected level with the model", function()
    fixture(function(models, state, target)
      local chosen
      models.pick("search", function(model) chosen = model end)
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      eq({ "(pi default)", "off", "low", "medium", "high" }, state.entries)
      eq({ "pi", "--mode", "rpc", "--model", "openai/chosen", "--no-session" }, state.rpc_options.argv)
      eq({ { type = "get_available_thinking_levels" } }, state.queries)
      eq(1, state.closed)
      eq(true, state.options.no_hide)
      eq(true, state.options.no_resume)
      state.options.actions.enter({ "high" })
      wait_for(function() return chosen ~= nil end)
      eq("openai/chosen:high", chosen)
      eq("openai/chosen:high", models.get("search"))
      eq({ search = "openai/chosen:high" }, vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
      models.setup({ search = "provider/configured" })
      wait_for(function() return models.get("search") == "openai/chosen:high" end)
    end)
  end)

  it("model tags containing colons keep their full identifier when a thinking level is appended", function()
    fixture(function(models, state)
      state.output = "provider model\nollama qwen:7b\n"
      local chosen
      models.pick("visual", function(model) chosen = model end)
      wait_for(function() return state.options ~= nil end)
      truthy(vim.tbl_contains(state.entries, "ollama/qwen:7b"))
      state.options.actions.enter({ "ollama/qwen:7b" })
      state.options.actions.enter({ "low" })
      wait_for(function() return chosen ~= nil end)
      eq("ollama/qwen:7b:low", chosen)
    end)
  end)

  it("a non-reasoning model offers only off and Pi default rather than unsupported thinking levels", function()
    fixture(function(models, state)
      state.levels = { "off" }
      models.pick("chat")
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      eq({ "(pi default)", "off" }, state.entries)
    end)
  end)

  it("cancelling thinking selection preserves both the saved model and the current chat callback", function()
    fixture(function(models, state, target)
      local called = false
      models.pick("search", function() called = true end)
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      state.options.actions.enter({})
      eq(false, called)
      eq("provider/previous", models.get("search"))
      eq({ search = "provider/previous" }, vim.json.decode(table.concat(vim.fn.readfile(target), "\n")))
      eq({}, state.notices)
    end)
  end)

  it("a thinking lookup failure closes Pi and leaves the previous choice intact", function()
    fixture(function(models, state)
      state.response = { success = false, error = "Model is unavailable" }
      models.pick("search")
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      eq({ "Model is unavailable" }, state.notices)
      eq("provider/previous", models.get("search"))
      eq(1, state.closed)
      eq(true, state.unsubscribed)
    end)
  end)

  it("a malformed thinking response closes Pi without changing the saved model", function()
    for _, data in ipairs({ vim.NIL, { levels = {} }, { levels = { "high\n" } } }) do
      fixture(function(models, state)
        state.response = { success = true, data = data }
        models.pick("search")
        wait_for(function() return state.options ~= nil end)
        state.options.actions.enter({ "openai/chosen" })
        truthy(state.notices[1]:find("Pi returned", 1, true))
        eq("provider/previous", models.get("search"))
        eq(1, state.closed)
      end)
    end
  end)

  it("a thinking process that cannot start leaves the saved model intact", function()
    fixture(function(models, state)
      rpc.new = function() error("pi executable missing") end
      models.pick("search")
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      truthy(state.notices[1]:find("pi executable missing", 1, true))
      eq("provider/previous", models.get("search"))
      eq(0, state.closed)
    end)
  end)

  it("a delayed thinking response cannot replace a newer picker", function()
    fixture(function(models, state)
      state.defer_response = true
      models.pick("search")
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      models.pick("review")
      eq(1, state.closed)
      wait_for(function() return state.options.prompt == "Model for review> " end)
      state.reply({ success = true, data = { levels = { "off", "high" } } })
      eq("Model for review> ", state.options.prompt)
      eq("provider/previous", models.get("search"))
      eq(1, state.closed)
    end)
  end)

  it("thinking lookup cancels extension dialogs instead of approving them", function()
    fixture(function(models, state)
      state.defer_response = true
      models.pick("search")
      wait_for(function() return state.options ~= nil end)
      state.options.actions.enter({ "openai/chosen" })
      state.event({ type = "extension_ui_request", id = "permission", method = "confirm", title = "Allow access?" })
      eq({ { type = "extension_ui_response", id = "permission", cancelled = true } }, state.writes)
      eq({ "Model selection needs Pi input: Allow access?" }, state.notices)
      eq(1, state.closed)
      eq("provider/previous", models.get("search"))
    end)
  end)

  it("model-list warnings and a missing model table do not become bogus picker choices", function()
    for _, case in ipairs({
      { output = "No models available.\n", entries = { "(pi default)" } },
      { output = "Catalog refresh warning\nprovider model\nopenai chosen\n", entries = { "(pi default)", "openai/chosen" } },
    }) do
      fixture(function(models, state)
        state.output = case.output
        models.pick("search")
        wait_for(function() return state.options ~= nil end)
        eq(case.entries, state.entries)
      end)
    end
  end)

  it("a failed model-list process does not block a later retry", function()
    fixture(function(models, state)
      local original = vim.system
      vim.system = function() error("pi executable missing") end
      local failure, found
      models.fetch(function(error_message) failure = error_message end)
      wait_for(function() return failure ~= nil end)
      truthy(failure:find("pi executable missing", 1, true))
      vim.system = original
      models.fetch(function(error_message, available)
        eq(nil, error_message)
        found = available
      end)
      wait_for(function() return found ~= nil end)
      eq({ "openai/chosen" }, found)
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
