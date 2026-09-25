local index = require("vimgentic.pi.index")
local picker = require("vimgentic.ui.picker")
local util = require("vimgentic.util")
local qf = require("vimgentic.ui.qf")

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
  local original_chat, original_quickfix = package.loaded["vimgentic.ops.chat"], qf.open
  local state = { pickers = {}, history = {}, chats = {}, cwd = "/one" }
  package.loaded["vimgentic.ops.chat"] = { switch_session = function(path) table.insert(state.chats, path) end }
  qf.open = function(results, title) state.quickfix = { results = results, title = title } end
  background.from_history = function(entry, quickfix)
    table.insert(state.history, { entry = entry, quickfix = quickfix })
  end
  index.list = function(options, on_result) store:list(options, on_result) end
  index.sync_from_log = function(on_result) store:sync_from_log(on_result) end
  util.cwd = function() return state.cwd end
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
  package.loaded["vimgentic.ops.chat"], qf.open = original_chat, original_quickfix
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

  it("Enter opens saved reviews and tours while Ctrl-o explicitly resumes their chats", function()
    for _, kind in ipairs({ "review", "tour" }) do
      fixture(function(state, entries)
        picker.history()
        wait_for(function() return #state.pickers == 1 end)
        local choice = state.pickers[1]
        choice.options.actions.enter({ choice.lines[1] })
        eq({ { entry = entries[1] } }, state.history)
        eq({}, state.chats)
        choice.options.actions["ctrl-o"]({ choice.lines[1] })
        eq({ entries[1].path }, state.chats)
      end, kind)
    end
  end)

  it("Enter on a chat resumes that session without opening a report", function()
    fixture(function(state, entries)
      picker.history()
      wait_for(function() return #state.pickers == 1 end)
      local choice = state.pickers[1]
      choice.options.actions.enter({ choice.lines[1] })
      eq({ entries[1].path }, state.chats)
      eq({}, state.history)
    end)
  end)

  it("Enter on a search restores its saved locations instead of resuming chat", function()
    fixture(function(state, entries)
      vim.fn.writefile({ vim.json.encode({ type = "message", message = { role = "assistant", content = "/tmp/target.lua:2:1,3,The matching code" } }) }, entries[1].path)
      picker.history()
      wait_for(function() return #state.pickers == 1 end)
      local choice = state.pickers[1]
      choice.options.actions.enter({ choice.lines[1] })
      wait_for(function() return state.quickfix ~= nil end)
      eq({ { path = "/tmp/target.lua", lnum = 2, col = 1, count = 3, notes = "The matching code" } }, state.quickfix.results)
      eq({}, state.chats)
    end, "search")
  end)

  it("an empty project still opens history so other projects remain reachable", function()
    fixture(function(state, entries)
      state.cwd = "/empty-project"
      picker.history()
      wait_for(function() return #state.pickers == 1 end)
      eq({}, state.pickers[1].lines)
      truthy(state.pickers[1].options.fzf_opts["--header"]:find("No matching sessions", 1, true))
      state.pickers[1].options.actions["ctrl-p"]()
      wait_for(function() return #state.pickers == 2 end)
      eq({ entries[2], entries[1] }, state.pickers[2].options._vimgentic_entries)
    end)
  end)

  it("the tour fallback picker excludes chats and searches across projects", function()
    fixture(function(state, entries)
      picker.history({ kind = "tour", all_projects = true })
      wait_for(function() return #state.pickers == 1 end)
      eq({ entries[1] }, state.pickers[1].options._vimgentic_entries)
      eq("Pi tour history> ", state.pickers[1].options.prompt)
    end, "tour")
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
