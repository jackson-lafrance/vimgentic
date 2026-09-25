local root, directory, operation, identifier = unpack(arg)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

if operation == "hold" then
  require("vimgentic.pi.lock").acquire(directory .. "/sessions.json.lock", 5000, function(error_message)
    assert(not error_message, error_message)
    io.write("locked\n")
    io.flush()
  end)
  vim.wait(30000, function() return false end, 10)
  os.exit(1)
end

local index = require("vimgentic.pi.index").Index.new({ path = directory .. "/sessions.json" })
local remaining, failure = 24, nil
for number = 1, 12 do
  local path = directory .. "/" .. identifier .. "-" .. number .. ".jsonl"
  vim.fn.writefile({ "{}" }, path)
  index:add({ path = path, cwd = directory, kind = "search", prompt = identifier .. "-" .. number }, function(error_message)
    failure = failure or error_message
    remaining = remaining - 1
  end)
  index:list({}, function(error_message)
    failure = failure or error_message
    remaining = remaining - 1
  end)
end
assert(vim.wait(15000, function() return remaining == 0 end, 5), "index worker timed out")
assert(not failure, failure)
