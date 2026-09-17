local state = require("vimgentic.chat.state")

local function fixture(contents, callback)
  local path = vim.fn.tempname()
  if contents then vim.fn.writefile({ contents }, path) end
  local done, failure, result = false, nil, nil
  state.read(path, "current", function(error_message, value)
    failure, result, done = error_message, value, true
  end)
  wait_for(function() return done end)
  vim.fn.delete(path)
  callback(failure, result, path)
end

describe("vimgentic.chat.state", function()
  it("a current terminal report returns the session file and directory", function()
    local report = { path = "/sessions/fork.jsonl", cwd = "/project", id = "fork-id", token = "current" }
    fixture(vim.json.encode(report), function(error_message, result)
      eq(nil, error_message)
      eq(report, result)
    end)
  end)

  it("a report from an earlier process cannot change the current session", function()
    fixture(vim.json.encode({ path = "/sessions/old.jsonl", cwd = "/project", id = "old-id", token = "old" }), function(error_message, result)
      eq(nil, error_message)
      eq(nil, result)
    end)
  end)

  it("a missing report leaves the startup session unchanged", function()
    fixture(nil, function(error_message, result)
      eq(nil, error_message)
      eq(nil, result)
    end)
  end)

  it("a malformed report returns an error rather than a session", function()
    for _, contents in ipairs({ "invalid", "[]", "42", '{"token":"current","path":"/session"}', string.rep("x", 65537) }) do
      fixture(contents, function(error_message, result, path)
        eq("Invalid pi terminal session state: " .. path, error_message)
        eq(nil, result)
      end)
    end
  end)
end)
