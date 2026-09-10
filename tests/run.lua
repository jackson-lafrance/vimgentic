local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local failures = 0
local tests = 0

local function format(value)
  return vim.inspect(value)
end

_G.describe = function(name, callback)
  io.write(name .. "\n")
  callback()
end

_G.it = function(name, callback)
  tests = tests + 1
  local ok, error_message = xpcall(callback, debug.traceback)
  if ok then
    io.write("  ✓ " .. name .. "\n")
  else
    failures = failures + 1
    io.stderr:write("  ✗ " .. name .. "\n" .. error_message .. "\n")
  end
end

_G.eq = function(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error("expected:\n" .. format(expected) .. "\nactual:\n" .. format(actual), 2)
  end
end

_G.truthy = function(value, message)
  if not value then
    error(message or ("expected truthy value, got " .. format(value)), 2)
  end
end

_G.wait_for = function(predicate, timeout)
  truthy(vim.wait(timeout or 1000, predicate, 5), "timed out waiting for asynchronous operation")
end

require("parse_spec")
require("rpc_framing_spec")
require("index_spec")
require("sessions_spec")
require("terminal_sidebar_spec")
require("selection_spec")
require("replacement_spec")
require("pair_spec")
require("cli_spec")
require("visual_spec")
require("prompt_spec")
require("oneshot_spec")
require("status_spec")

io.write(string.format("\n%d tests, %d failures\n", tests, failures))
if failures > 0 then
  os.exit(1)
end
