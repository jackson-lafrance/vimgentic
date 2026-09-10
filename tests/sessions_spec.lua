local sessions = require("vimgentic.pi.sessions")

local function with_session_root(root, callback)
  local original_root = vim.env.PI_CODING_AGENT_SESSION_DIR
  vim.env.PI_CODING_AGENT_SESSION_DIR = root
  local ok, error_message = xpcall(callback, debug.traceback)
  vim.env.PI_CODING_AGENT_SESSION_DIR = original_root
  vim.fn.delete(root, "rf")
  if not ok then
    error(error_message)
  end
end

local function write_session(path, session_id, cwd, name)
  local lines = {
    vim.json.encode({ type = "session", version = 3, id = session_id, timestamp = "2026-09-10T17:08:32.668Z", cwd = cwd }),
    vim.json.encode({ type = "message", id = "a1b2c3d4", parentId = vim.NIL, timestamp = "2026-09-10T17:08:33.000Z", message = { role = "user", content = "hello" } }),
  }
  if name then
    table.insert(lines, vim.json.encode({ type = "session_info", id = "b2c3d4e5", parentId = "a1b2c3d4", timestamp = "2026-09-10T17:08:34.000Z", name = name }))
  end
  vim.fn.writefile(lines, path)
end

describe("vimgentic.pi.sessions", function()
  it("encodes the working directory the way pi does, without an extra leading dash", function()
    local original_root = vim.env.PI_CODING_AGENT_SESSION_DIR
    vim.env.PI_CODING_AGENT_SESSION_DIR = "/tmp/vimgenic-root"
    eq("/tmp/vimgenic-root/--Users-jackson-project--", sessions.cwd_directory("/Users/jackson/project"))
    eq("/tmp/vimgenic-root/--tmp-project--", sessions.cwd_directory("/tmp/project"))
    eq("/tmp/vimgenic-root/--project--", sessions.cwd_directory("project"))
    vim.env.PI_CODING_AGENT_SESSION_DIR = original_root
  end)

  it("find_by_id returns the session file for the current working directory", function()
    local root = vim.fn.tempname()
    local directory = root .. "/--tmp-vimgentic-project--"
    local session_id = "session-id"
    local path = directory .. "/timestamp_" .. session_id .. ".jsonl"
    vim.fn.mkdir(directory, "p")
    vim.fn.writefile({ "{}" }, path)
    with_session_root(root, function()
      local done, failure, found = false, nil, nil
      sessions.find_by_id("/tmp/vimgentic-project", session_id, function(error_message, result)
        failure = error_message
        found = result
        done = true
      end)
      wait_for(function() return done end)
      eq(nil, failure)
      eq(path, found)
    end)
  end)

  it("read_metadata returns the header cwd, session name, and creation time", function()
    local root = vim.fn.tempname()
    local directory = root .. "/--tmp-project--"
    local session_id = "01a08c4a-e11b-75f8-8b38-1aa76be2fe7f"
    local path = directory .. "/2026-09-10T17-08-32-668Z_" .. session_id .. ".jsonl"
    vim.fn.mkdir(directory, "p")
    write_session(path, session_id, "/tmp/project", "chat: project")
    with_session_root(root, function()
      local done, failure, metadata = false, nil, nil
      sessions.read_metadata(path, function(error_message, result)
        failure = error_message
        metadata = result
        done = true
      end)
      wait_for(function() return done end)
      eq(nil, failure)
      eq(session_id, metadata.session_id)
      eq("/tmp/project", metadata.cwd)
      eq("chat: project", metadata.prompt)
      eq(os.time({ year = 2026, month = 9, day = 10, hour = 17, min = 8, sec = 32 }), metadata.created)
    end)
  end)
end)
