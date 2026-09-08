local rpc = require("vimgentic.pi.rpc")

describe("vimgentic.pi.rpc framing", function()
  it("keeps a record split across chunks", function()
    local lines = {}
    local framer = rpc.Framer.new(function(line) table.insert(lines, line) end)
    framer:feed('{"type":"agent_')
    framer:feed('start"}\n')
    eq({ '{"type":"agent_start"}' }, lines)
  end)

  it("accepts CRLF records", function()
    local lines = {}
    local framer = rpc.Framer.new(function(line) table.insert(lines, line) end)
    framer:feed("one\r\ntwo\r\n")
    eq({ "one", "two" }, lines)
  end)

  it("emits multiple records from one chunk", function()
    local lines = {}
    local framer = rpc.Framer.new(function(line) table.insert(lines, line) end)
    framer:feed("one\ntwo\nthree\n")
    eq({ "one", "two", "three" }, lines)
  end)

  it("does not split on a Unicode line separator", function()
    local lines = {}
    local separator = vim.fn.nr2char(0x2028)
    local framer = rpc.Framer.new(function(line) table.insert(lines, line) end)
    framer:feed('{"value":"left' .. separator .. 'right"}\n')
    eq(1, #lines)
    eq("left" .. separator .. "right", vim.json.decode(lines[1]).value)
  end)

  it("correlates responses by id and dispatches events", function()
    local writes = {}
    local response
    local events = {}
    local client = rpc._new_for_test({
      schedule = function(callback) callback() end,
      write = function(data) table.insert(writes, data) end,
    })
    client:on_event(function(event) table.insert(events, event) end)
    client:send({ type = "get_state" }, function(value) response = value end)
    local command = vim.json.decode(writes[1])
    client:feed(vim.json.encode({ type = "agent_start" }) .. "\n")
    client:feed(vim.json.encode({ type = "response", id = command.id, command = "get_state", success = true }) .. "\n")
    eq("get_state", response.command)
    eq({ { type = "agent_start" } }, events)
  end)

  it("dispatches bash events with ids instead of treating them as responses", function()
    local events = {}
    local client = rpc._new_for_test({ schedule = function(callback) callback() end })
    client:on_event(function(event) table.insert(events, event) end)
    client:feed('{"type":"bash_execution_update","id":1,"delta":"ok"}\n')
    eq("bash_execution_update", events[1].type)
  end)
end)
