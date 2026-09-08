local sessions = require("vimgentic.pi.sessions")

describe("vimgentic.pi.sessions", function()
  it("find_by_id returns the session file for the current working directory", function()
    local original_root = vim.env.PI_CODING_AGENT_SESSION_DIR
    local root = vim.fn.tempname()
    local cwd = "/tmp/vimgentic-project"
    local directory = root .. "/--" .. cwd:gsub("/", "-") .. "--"
    local session_id = "session-id"
    local path = directory .. "/timestamp_" .. session_id .. ".jsonl"
    vim.fn.mkdir(directory, "p")
    vim.fn.writefile({ "{}" }, path)
    vim.env.PI_CODING_AGENT_SESSION_DIR = root
    local done, failure, found = false, nil, nil
    sessions.find_by_id(cwd, session_id, function(error_message, result)
      failure = error_message
      found = result
      done = true
    end)
    wait_for(function() return done end)
    eq(nil, failure)
    eq(path, found)
    vim.env.PI_CODING_AGENT_SESSION_DIR = original_root
    vim.fn.delete(root, "rf")
  end)
end)
