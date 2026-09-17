local Terminal = require("vimgentic.chat.terminal").Terminal
local index = require("vimgentic.pi.index")
local sessions = require("vimgentic.pi.sessions")
local util = require("vimgentic.util")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local path = directory .. "/resumed.jsonl"
  vim.fn.writefile({ vim.json.encode({ type = "session", id = "resumed-id", cwd = "/other-project" }) }, path)
  local original_chat, original_new = package.loaded["vimgentic.ops.chat"], Terminal.new
  local original_sync, original_notify = index.sync_from_log, util.notify
  local original_metadata = sessions.read_metadata
  local state = { switches = {}, notices = {}, syncs = 0 }
  Terminal.new = function(options)
    state.on_session = options.on_session
    return {
      switch_session = function(_, session_path, cwd)
        table.insert(state.switches, { path = session_path, cwd = cwd, fast_event = vim.in_fast_event() })
      end,
      close = function() state.closed = true end,
      shutdown = function() state.stopped = true end,
    }
  end
  index.sync_from_log = function(on_result)
    state.syncs = state.syncs + 1
    on_result()
  end
  util.notify = function(message) table.insert(state.notices, message) end
  package.loaded["vimgentic.ops.chat"] = nil
  local ok, error_message = xpcall(function()
    callback(require("vimgentic.ops.chat"), state, path)
  end, debug.traceback)
  package.loaded["vimgentic.ops.chat"], Terminal.new = original_chat, original_new
  index.sync_from_log, util.notify = original_sync, original_notify
  sessions.read_metadata = original_metadata
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.ops.chat history", function()
  it("a history selection uses the session directory and switches outside the filesystem callback", function()
    fixture(function(chat, state, path)
      chat.switch_session(path)
      wait_for(function() return #state.switches == 1 end)
      eq({ { path = path, cwd = "/other-project", fast_event = false } }, state.switches)
      eq({}, state.notices)
    end)
  end)

  it("a missing session reports the read error without replacing the current terminal", function()
    fixture(function(chat, state, path)
      chat.switch_session(path .. ".missing")
      wait_for(function() return #state.notices == 1 end)
      truthy(state.notices[1]:find("ENOENT", 1, true))
      eq({}, state.switches)
    end)
  end)

  it("a late metadata response cannot replace a newer history selection", function()
    fixture(function(chat, state)
      local reads = {}
      sessions.read_metadata = function(path, callback) reads[path] = callback end
      chat.switch_session("/sessions/old.jsonl")
      chat.switch_session("/sessions/new.jsonl")
      reads["/sessions/new.jsonl"](nil, { cwd = "/new-project" })
      reads["/sessions/old.jsonl"](nil, { cwd = "/old-project" })
      wait_for(function() return #state.switches > 0 end)
      eq({ { path = "/sessions/new.jsonl", cwd = "/new-project", fast_event = false } }, state.switches)
    end)
  end)

  it("closing the sidebar cancels a history selection whose metadata is still pending", function()
    fixture(function(chat, state)
      local respond
      sessions.read_metadata = function(_, callback) respond = callback end
      chat.switch_session("/sessions/selected.jsonl")
      chat.close()
      respond(nil, { cwd = "/project" })
      local drained = false
      vim.schedule(function() drained = true end)
      wait_for(function() return drained end)
      eq(true, state.closed)
      eq({}, state.switches)
    end)
  end)

  it("native session changes refresh history from the session log", function()
    fixture(function(chat, state)
      chat.instance()
      state.on_session({ path = "/sessions/search.jsonl", cwd = "/project", id = "id" })
      eq(1, state.syncs)
      eq({}, state.switches)
    end)
  end)
end)
