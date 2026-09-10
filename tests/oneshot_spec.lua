local oneshot = require("vimgentic.ops.oneshot")
local rpc = require("vimgentic.pi.rpc")
local util = require("vimgentic.util")

local function fixture(callback)
  local original_new, original_notify = rpc.new, util.notify
  local state = { results = {}, writes = {}, notices = {}, finishes = 0, closes = 0, stops = 0 }
  local client = {
    on_event = function(_, listener)
      state.event = listener
      return function() state.unsubscribed = true end
    end,
    send = function(_, command, on_response)
      if command.type == "get_last_assistant_text" then
        on_response({ success = true, data = { text = "return total" } })
      else
        on_response({ success = true })
      end
    end,
    write = function(_, command) table.insert(state.writes, command) end,
    close = function() state.closes = state.closes + 1 end,
  }
  rpc.new = function(options)
    state.argv = options.argv
    return client
  end
  util.notify = function(message) table.insert(state.notices, message) end
  local ok, error_message = xpcall(function()
    oneshot.run({
      kind = "visual",
      user_prompt = "Use total",
      prompt = "Return replacement code",
      tools = { "read", "grep", "find", "ls" },
      status = { stop = function() state.stops = state.stops + 1 end },
      on_result = function(text) table.insert(state.results, text) end,
      on_finish = function()
        state.finishes = state.finishes + 1
        state.results_at_finish = vim.deepcopy(state.results)
      end,
    })
    callback(state)
  end, debug.traceback)
  oneshot.abort_all()
  rpc.new, util.notify = original_new, original_notify
  assert(ok, error_message)
end

describe("vimgentic.ops.oneshot completion", function()
  it("passes the operation's tool allowlist to pi and finishes after the result callback", function()
    fixture(function(state)
      eq({ "pi", "--mode", "rpc", "--tools", "read,grep,find,ls" }, state.argv)
      eq(0, state.finishes)
      state.event({ type = "agent_settled" })
      eq({ "return total" }, state.results)
      eq({ "return total" }, state.results_at_finish)
      eq(1, state.finishes)
      eq(1, state.stops)
      eq(1, state.closes)
      eq(true, state.unsubscribed)
    end)
  end)

  it("finishes failed requests without producing a replacement", function()
    fixture(function(state)
      state.event({ type = "process_exit", code = 1, stderr = "pi startup failed" })
      eq({}, state.results)
      eq({ "pi startup failed" }, state.notices)
      eq(1, state.finishes)
      eq(1, state.stops)
      eq(1, state.closes)
      state.event({ type = "process_exit", code = 1 })
      eq(1, state.finishes)
    end)
  end)

  it("finishes aborted requests once and ignores a late settled response", function()
    fixture(function(state)
      oneshot.abort_all()
      eq({ { type = "abort" } }, state.writes)
      eq({}, state.results)
      eq(1, state.finishes)
      eq(1, state.stops)
      eq(1, state.closes)
      state.event({ type = "agent_settled" })
      eq({}, state.results)
      eq(1, state.finishes)
    end)
  end)
end)
