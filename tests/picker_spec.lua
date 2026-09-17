local index = require("vimgentic.pi.index")
local picker = require("vimgentic.ui.picker")
local util = require("vimgentic.util")

local function fixture(callback, kind)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local entries = {
    { path = directory .. "/one.jsonl", kind = kind or "chat", cwd = "/one", prompt = "first project", created = 1 },
    { path = directory .. "/two.jsonl", kind = "search", cwd = "/two", prompt = "second project", created = 2 },
  }
  for _, entry in ipairs(entries) do
    vim.fn.writefile({ "{}" }, entry.path)
  end
  vim.fn.writefile({ vim.json.encode(entries) }, directory .. "/sessions.json")
  local store = index.Index.new({ path = directory .. "/sessions.json", log = directory .. "/session-log.jsonl" })
  local original_list, original_sync, original_cwd = index.list, index.sync_from_log, util.cwd
  local background = require("vimgentic.ops.background")
  local original_history = background.from_history
  local original_fzf = package.loaded["fzf-lua"]
  local original_previewer = package.loaded["fzf-lua.previewer.builtin"]
  local state = { pickers = {}, history = {} }
  background.from_history = function(entry, quickfix)
    table.insert(state.history, { entry = entry, quickfix = quickfix })
  end
  index.list = function(options, on_result) store:list(options, on_result) end
  index.sync_from_log = function(on_result) store:sync_from_log(on_result) end
  util.cwd = function() return "/one" end
  package.loaded["fzf-lua"] = {
    fzf_exec = function(lines, options)
      table.insert(state.pickers, { lines = lines, options = options })
    end,
  }
  package.loaded["fzf-lua.previewer.builtin"] = { base = { extend = function() return {} end } }
  local ok, error_message = xpcall(function() callback(state, entries) end, debug.traceback)
  index.list, index.sync_from_log, util.cwd = original_list, original_sync, original_cwd
  background.from_history = original_history
  package.loaded["fzf-lua"] = original_fzf
  package.loaded["fzf-lua.previewer.builtin"] = original_previewer
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.ui.picker history", function()
  it("review and tour history actions restore the report or quickfix on demand", function()
    for _, kind in ipairs({ "review", "tour" }) do
      fixture(function(state, entries)
        picker.history()
        wait_for(function() return #state.pickers == 1 end)
        local choice = state.pickers[1]
        eq({}, state.history)
        choice.options.actions["ctrl-r"]({ choice.lines[1] })
        choice.options.actions["ctrl-q"]({ choice.lines[1] })
        eq({ { entry = entries[1] }, { entry = entries[1], quickfix = true } }, state.history)
      end, kind)
    end
  end)

  it("opening history shows only the current project's sessions", function()
    fixture(function(state, entries)
      picker.history()
      wait_for(function() return #state.pickers == 1 end)
      eq({ entries[1] }, state.pickers[1].options._vimgentic_entries)
      truthy(state.pickers[1].lines[1]:find("first project", 1, true))
    end)
  end)

  it("toggling all projects shows other projects and toggling back restores the current scope", function()
    fixture(function(state, entries)
      picker.history()
      wait_for(function() return #state.pickers == 1 end)
      eq({ entries[1] }, state.pickers[1].options._vimgentic_entries)
      state.pickers[1].options.actions["ctrl-p"]()
      wait_for(function() return #state.pickers == 2 end)
      eq({ entries[2], entries[1] }, state.pickers[2].options._vimgentic_entries)
      truthy(state.pickers[2].lines[1]:find("two", 1, true))
      state.pickers[2].options.actions["ctrl-p"]()
      wait_for(function() return #state.pickers == 3 end)
      eq({ entries[1] }, state.pickers[3].options._vimgentic_entries)
    end)
  end)
end)
