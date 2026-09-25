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

local function listed(options)
  local done, failure, entries = false, nil, nil
  sessions.list(options, function(error_message, result)
    failure, entries, done = error_message, result, true
  end)
  wait_for(function() return done end)
  eq(nil, failure)
  return entries
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

  it("a project without a native session directory returns an empty history instead of an error", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    with_session_root(root, function()
      eq({}, listed({ cwd = "/project-with-no-sessions" }))
    end)
  end)

  it("all-project history sees new sessions inside an existing project directory", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/--tmp-project--", "p")
    with_session_root(root, function()
      local first, second = root .. "/--tmp-project--/first.jsonl", root .. "/--tmp-project--/second.jsonl"
      write_session(first, "first", "/tmp/project", "First chat")
      eq(first, listed({ all_projects = true })[1].path)
      write_session(second, "second", "/tmp/project", "Second chat")
      local paths = vim.tbl_map(function(entry) return entry.path end, listed({ all_projects = true }))
      table.sort(paths)
      eq({ first, second }, paths)
    end)
  end)

  it("history refreshes session names when the file changes without a directory change", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/--tmp-project--", "p")
    with_session_root(root, function()
      local path = root .. "/--tmp-project--/session.jsonl"
      write_session(path, "session", "/tmp/project", "Old name")
      eq("Old name", listed({ cwd = "/tmp/project" })[1].name)
      vim.fn.writefile({ vim.json.encode({ type = "session_info", name = "Updated session name" }) }, path, "a")
      eq("Updated session name", listed({ cwd = "/tmp/project" })[1].name)
      eq("Updated session name", listed({ cwd = "/tmp/project" })[1].name)
    end)
  end)

  it("report recovery skips follow-up replies and failed responses while preserving a large original tour", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    with_session_root(root, function()
      local path = root .. "/tour.jsonl"
      local report = vim.json.encode({ report = "Original tour", locations = {
        { path = "/tmp/code.lua", lnum = 1, notes = string.rep("Detailed explanation. ", 4000), source = "working tree" },
      } })
      local failed = vim.json.encode({ report = "Aborted replacement", locations = {} })
      local function message(text, reason)
        return vim.json.encode({ type = "message", message = { role = "assistant", stopReason = reason,
          content = { { type = "thinking", thinking = "Working notes before the final answer" }, { type = "text", text = text } } } })
      end
      vim.fn.writefile({ message(report, "stop"), message("A follow-up explanation", "stop"), message(failed, "aborted") }, path)
      local done, failure, recovered = false, nil, nil
      sessions.last_report(path, function(error_message, text)
        failure, recovered, done = error_message, text, true
      end)
      wait_for(function() return done end)
      eq(nil, failure)
      eq(report, recovered)
    end)
  end)

  it("saved assistant text excludes reasoning blocks before the final answer", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    with_session_root(root, function()
      local path = root .. "/thinking.jsonl"
      vim.fn.writefile({ vim.json.encode({ type = "message", message = { role = "assistant", content = {
        { type = "thinking", thinking = "Working notes" }, { type = "text", text = "The final answer" },
      } } }) }, path)
      local done, failure, recovered = false, nil, nil
      sessions.last_assistant(path, function(error_message, text)
        failure, recovered, done = error_message, text, true
      end)
      wait_for(function() return done end)
      eq(nil, failure)
      eq("The final answer", recovered)
    end)
  end)

  it("report recovery returns no result for an unfinished or unstructured session", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    with_session_root(root, function()
      local path = root .. "/unfinished.jsonl"
      write_session(path, "unfinished", "/tmp/project")
      vim.fn.writefile({ vim.json.encode({ type = "message", message = { role = "assistant", content = "Still inspecting" } }) }, path, "a")
      local done, failure, recovered = false, nil, "not called"
      sessions.last_report(path, function(error_message, text)
        failure, recovered, done = error_message, text, true
      end)
      wait_for(function() return done end)
      eq(nil, failure)
      eq(nil, recovered)
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
