local index_module = require("vimgentic.pi.index")
local Index = index_module.Index

local function fixture()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local session_one = directory .. "/one.jsonl"
  local session_two = directory .. "/two.jsonl"
  vim.fn.writefile({ "{}" }, session_one)
  vim.fn.writefile({ "{}" }, session_two)
  return {
    directory = directory,
    index = Index.new({ path = directory .. "/sessions.json", log = directory .. "/session-log.jsonl" }),
    session_one = session_one,
    session_two = session_two,
  }
end

local function add(index, entry)
  local done, failure = false, nil
  index:add(entry, function(error_message)
    failure = error_message
    done = true
  end)
  wait_for(function() return done end)
  eq(nil, failure)
end

local function list(index, options)
  local done, failure, entries = false, nil, nil
  index:list(options or {}, function(error_message, result)
    failure = error_message
    entries = result
    done = true
  end)
  wait_for(function() return done end)
  eq(nil, failure)
  return entries
end

describe("vimgentic.pi.index", function()
  it("adds an entry and preserves it through a JSON round trip", function()
    local context = fixture()
    add(context.index, { path = context.session_one, kind = "search", cwd = "/one", prompt = "find value", created = 10 })
    local entries = list(context.index)
    eq(1, #entries)
    eq("find value", entries[1].prompt)
    eq("search", entries[1].kind)
    vim.fn.delete(context.directory, "rf")
  end)

  it("prunes entries whose session file is missing", function()
    local context = fixture()
    add(context.index, { path = context.session_one, kind = "search", cwd = "/one", prompt = "one" })
    vim.fn.delete(context.session_one)
    eq({}, list(context.index))
    vim.fn.delete(context.directory, "rf")
  end)

  it("filters entries by cwd", function()
    local context = fixture()
    add(context.index, { path = context.session_one, kind = "chat", cwd = "/one", prompt = "one", created = 1 })
    add(context.index, { path = context.session_two, kind = "visual", cwd = "/two", prompt = "two", created = 2 })
    local entries = list(context.index, { cwd = "/two" })
    eq(1, #entries)
    eq("/two", entries[1].cwd)
    vim.fn.delete(context.directory, "rf")
  end)

  it("indexes forked and new sessions recorded by the chat terminal log", function()
    local context = fixture()
    local forked = context.directory .. "/forked.jsonl"
    vim.fn.writefile({
      vim.json.encode({ type = "session", version = 3, id = "forked-id", timestamp = "2026-09-10T17:08:32.668Z", cwd = "/tmp/project" }),
      vim.json.encode({ type = "session_info", id = "info-id", parentId = "msg-id", timestamp = "2026-09-10T17:08:34.000Z", name = "chat: project" }),
    }, forked)
    vim.fn.writefile({
      vim.json.encode({ cwd = "/tmp/project", path = forked }),
      vim.json.encode({ cwd = "/tmp/project", path = forked }),
      vim.json.encode({ cwd = "/tmp/project", path = context.directory .. "/missing.jsonl" }),
      vim.json.encode({ cwd = "/tmp/project", path = context.session_one }),
    }, context.index.log)
    local done, failure = false, nil
    context.index:sync_from_log(function(error_message)
      failure = error_message
      done = true
    end)
    wait_for(function() return done end)
    eq(nil, failure)
    local entries = list(context.index, { cwd = "/tmp/project" })
    eq(1, #entries)
    eq("chat", entries[1].kind)
    eq(forked, entries[1].path)
    eq("chat: project", entries[1].prompt)
    vim.fn.delete(context.directory, "rf")
  end)

  it("concurrent Neovim writers preserve every session while history prunes missing files", function()
    local context = fixture()
    add(context.index, { path = context.session_one, kind = "chat", cwd = context.directory, prompt = "missing" })
    vim.fn.delete(context.session_one)
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local children, expected = {}, {}
    for worker = 1, 3 do
      local identifier = "writer-" .. worker
      table.insert(children, vim.system({ vim.v.progpath, "-u", "NONE", "-l", root .. "/tests/fixtures/index_worker.lua", root, context.directory, "write", identifier }, { text = true }))
      for number = 1, 12 do table.insert(expected, identifier .. "-" .. number) end
    end
    local results = {}
    for _, child in ipairs(children) do table.insert(results, child:wait(20000)) end
    for _, result in ipairs(results) do eq(0, result.code); eq("", result.stderr) end
    local actual = {}
    for _, entry in ipairs(list(context.index)) do table.insert(actual, entry.prompt) end
    table.sort(expected)
    table.sort(actual)
    eq(expected, actual)
    vim.fn.delete(context.directory, "rf")
  end)

  it("an invalid index releases the lock so a later update can succeed", function()
    local context = fixture()
    vim.fn.writefile({ "invalid json" }, context.index.path)
    local done, failure = false, nil
    context.index:add({ path = context.session_one }, function(error_message)
      failure, done = error_message, true
    end)
    wait_for(function() return done end)
    truthy(failure:find("invalid vimgentic session index:", 1, true))
    vim.fn.writefile({ "[]" }, context.index.path)
    add(context.index, { path = context.session_two, prompt = "recovered" })
    local entries = list(context.index)
    eq(context.session_two, entries[1].path)
    eq("recovered", entries[1].prompt)
    vim.fn.delete(context.directory, "rf")
  end)

  it("pruning waits for the same lock as an index update", function()
    local context = fixture()
    add(context.index, { path = context.session_one, prompt = "missing" })
    vim.fn.delete(context.session_one)
    local release
    require("vimgentic.pi.lock").acquire(context.index.path .. ".lock", 1000, function(error_message, unlock)
      eq(nil, error_message)
      release = unlock
    end)
    wait_for(function() return release ~= nil end)
    local finished, result, failure = false, nil, nil
    context.index:list({}, function(error_message, entries)
      failure, result, finished = error_message, entries, true
    end)
    local premature = vim.wait(50, function() return finished end, 5)
    release(function() end)
    wait_for(function() return finished end)
    eq(false, premature)
    eq(nil, failure)
    eq({}, result)
    eq({}, vim.json.decode(table.concat(vim.fn.readfile(context.index.path), "\n")))
    vim.fn.delete(context.directory, "rf")
  end)

  it("a short filesystem write still saves the complete session entry", function()
    local context = fixture()
    local original_write = vim.uv.fs_write
    vim.uv.fs_write = function(descriptor, contents, offset, callback)
      return original_write(descriptor, contents:sub(1, 7), offset, callback)
    end
    local ok, error_message = xpcall(function()
      add(context.index, { path = context.session_one, prompt = "complete session metadata", kind = "visual", cwd = "/project" })
    end, debug.traceback)
    vim.uv.fs_write = original_write
    local entries = list(context.index)
    vim.fn.delete(context.directory, "rf")
    assert(ok, error_message)
    eq(context.session_one, entries[1].path)
    eq("complete session metadata", entries[1].prompt)
    eq("visual", entries[1].kind)
    eq("/project", entries[1].cwd)
  end)

  it("a failed write preserves the index and releases the lock for the next writer", function()
    local context = fixture()
    add(context.index, { path = context.session_one, prompt = "original" })
    local original_write = vim.uv.fs_write
    local done, failure = false, nil
    vim.uv.fs_write = function(_, _, _, callback) callback("EIO: injected write failure") end
    context.index:add({ path = context.session_two, prompt = "failed update" }, function(error_message)
      failure, done = error_message, true
    end)
    local completed = vim.wait(1000, function() return done end, 5)
    vim.uv.fs_write = original_write
    eq(true, completed)
    eq("EIO: injected write failure", failure)
    local entries = list(context.index)
    eq(1, #entries)
    eq("original", entries[1].prompt)
    add(context.index, { path = context.session_two, prompt = "retry succeeded" })
    local prompts = {}
    for _, entry in ipairs(list(context.index)) do table.insert(prompts, entry.prompt) end
    table.sort(prompts)
    eq({ "original", "retry succeeded" }, prompts)
    eq({}, vim.fn.glob(context.index.path .. ".tmp-*", false, true))
    vim.fn.delete(context.directory, "rf")
  end)

  it("a session stat error preserves the index rather than pruning an inaccessible session", function()
    local context = fixture()
    add(context.index, { path = context.session_one, prompt = "keep this session" })
    local original_stat = vim.uv.fs_stat
    local done, failure = false, nil
    vim.uv.fs_stat = function(path, callback)
      if path == context.session_one then callback("EACCES: injected stat failure"); return end
      return original_stat(path, callback)
    end
    context.index:list({}, function(error_message) failure, done = error_message, true end)
    local completed = vim.wait(1000, function() return done end, 5)
    vim.uv.fs_stat = original_stat
    eq(true, completed)
    eq("EACCES: injected stat failure", failure)
    local entries = list(context.index)
    eq(context.session_one, entries[1].path)
    eq("keep this session", entries[1].prompt)
    vim.fn.delete(context.directory, "rf")
  end)

  it("leaves the index untouched when the log has nothing new", function()
    local context = fixture()
    add(context.index, { path = context.session_one, kind = "chat", cwd = "/one", prompt = "one" })
    local done, failure = false, nil
    context.index:sync_from_log(function(error_message)
      failure = error_message
      done = true
    end)
    wait_for(function() return done end)
    eq(nil, failure)
    eq(1, #list(context.index))
    vim.fn.delete(context.directory, "rf")
  end)
end)
