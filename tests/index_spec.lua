local Index = require("vimgentic.pi.index").Index

local function fixture()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local session_one = directory .. "/one.jsonl"
  local session_two = directory .. "/two.jsonl"
  vim.fn.writefile({ "{}" }, session_one)
  vim.fn.writefile({ "{}" }, session_two)
  return {
    directory = directory,
    index = Index.new({ path = directory .. "/sessions.json" }),
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
end)
