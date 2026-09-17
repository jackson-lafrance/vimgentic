local oneshot = require("vimgentic.ops.oneshot")
local rpc = require("vimgentic.pi.rpc")
local util = require("vimgentic.util")

local function fixture(callback, options)
  local original_new, original_notify = rpc.new, util.notify
  local state = { results = {}, commands = {}, writes = {}, notices = {}, activities = {}, finishes = 0, closes = 0, stops = 0 }
  local client = {
    on_event = function(_, listener)
      state.event = listener
      return function() state.unsubscribed = true end
    end,
    send = function(_, command, on_response)
      table.insert(state.commands, command)
      if command.type == "get_commands" then
        state.skills_response = on_response
      elseif command.type == "get_last_assistant_text" then
        on_response({ success = true, data = { text = "return total" } })
      else
        on_response({ success = true })
      end
    end,
    write = function(_, command) table.insert(state.writes, command) end,
    close = function() state.closes = state.closes + 1 end,
  }
  rpc.new = function(options)
    state.argv, state.cwd = options.argv, options.cwd
    return client
  end
  util.notify = function(message) table.insert(state.notices, message) end
  local ok, error_message = xpcall(function()
    oneshot.run(vim.tbl_extend("force", {
      kind = "visual",
      user_prompt = "Use total",
      prompt = "Return replacement code",
      tools = { "read", "grep", "find", "ls" },
      status = {
        stop = function() state.stops = state.stops + 1 end,
        set_activity = function(_, text) table.insert(state.activities, text) end,
      },
      on_result = function(text) table.insert(state.results, text) end,
      on_finish = function()
        state.finishes = state.finishes + 1
        state.results_at_finish = vim.deepcopy(state.results)
      end,
    }, options or {}))
    callback(state)
  end, debug.traceback)
  oneshot.abort_all()
  rpc.new, util.notify = original_new, original_notify
  assert(ok, error_message)
end

describe("vimgentic.ops.oneshot completion", function()
  it("a review loads the requested skill before submitting and keeps the captured directory", function()
    fixture(function(state)
      eq("/captured/project", state.cwd)
      eq({ "pi", "--mode", "rpc", "--skill", "/bundled/SKILL.md" }, state.argv)
      eq({ { type = "get_state" }, { type = "get_commands" } }, state.commands)
      state.skills_response({ success = true, data = { commands = {
        { name = "skill:review-local", source = "skill", sourceInfo = { path = "/bundled/SKILL.md" } },
      } } })
      eq({ type = "prompt", message = "/skill:review-local Review the file" }, state.commands[3])
      state.event({ type = "tool_execution_start", toolName = "bash", args = { command = "git diff --no-ext-diff --no-textconv" } })
      eq({ "git diff --no-ext-diff --no-textconv" }, state.activities)
      state.event({ type = "agent_settled" })
      eq({ "return total" }, state.results)
    end, {
      kind = "review", cwd = "/captured/project", tools = false,
      skill = { name = "review-local", path = "/bundled/SKILL.md" },
      prompt = "/skill:review-local Review the file",
    })
  end)

  it("a missing or shadowed skill fails without submitting a review", function()
    for _, commands in ipairs({ {}, {
      { name = "skill:review-local", source = "skill", sourceInfo = { path = "/another/SKILL.md" } },
    }, {
      { name = "skill:review-local", source = "extension", sourceInfo = { path = "/bundled/SKILL.md" } },
    } }) do
      fixture(function(state)
        state.skills_response({ success = true, data = { commands = commands } })
        eq({ { type = "get_state" }, { type = "get_commands" } }, state.commands)
        eq({}, state.results)
        truthy(state.notices[1]:find("Pi did not load the bundled skill", 1, true))
        eq(1, state.finishes)
      end, { skill = { name = "review-local", path = "/bundled/SKILL.md" } })
    end
  end)

  it("aborting a skill check prevents a delayed response from starting work", function()
    fixture(function(state)
      oneshot.abort_all()
      state.skills_response({ success = true, data = { commands = {
        { name = "skill:review-local", source = "skill", path = "/bundled/SKILL.md" },
      } } })
      eq({ { type = "get_state" }, { type = "get_commands" } }, state.commands)
      eq(1, state.finishes)
      eq({}, state.results)
    end, { skill = { name = "review-local", path = "/bundled/SKILL.md" } })
  end)

  it("skill command errors and expansion errors finish without a result", function()
    fixture(function(state)
      state.skills_response({ success = false, error = "skill registry failed" })
      eq({ "skill registry failed" }, state.notices)
      eq({}, state.results)
      eq(1, state.finishes)
    end, { skill = { name = "review-local", path = "/bundled/SKILL.md" } })
    fixture(function(state)
      state.skills_response({ success = true, data = { commands = {
        { name = "skill:review-local", source = "skill", path = "/bundled/SKILL.md" },
      } } })
      state.event({ type = "extension_error", event = "skill_expansion", error = "skill file disappeared" })
      state.event({ type = "agent_settled" })
      eq({ "skill file disappeared" }, state.notices)
      eq({}, state.results)
      eq(1, state.finishes)
    end, { skill = { name = "review-local", path = "/bundled/SKILL.md" } })
  end)

  it("a background dialog is cancelled without a UI or an automatic approval", function()
    for _, method in ipairs({ "select", "confirm", "input", "editor" }) do
      fixture(function(state)
        state.event({ type = "extension_ui_request", method = method, id = "dialog", title = "Allow a command?" })
        eq({ { type = "extension_ui_response", id = "dialog", cancelled = true } }, state.writes)
        eq({ "Background review needs interactive input: Allow a command?" }, state.notices)
        eq({}, state.results)
        eq(1, state.finishes)
      end, { kind = "review", background = true })
    end
  end)

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
