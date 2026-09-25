local lock = require("vimgentic.pi.lock")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fixture(callback)
  local directory = vim.fn.tempname()
  local releases, children = {}, {}
  local function acquire(timeout)
    local done, failure, unlock = false, nil, nil
    lock.acquire(directory .. "/sessions.json.lock", timeout or 1000, function(error_message, release)
      failure, unlock, done = error_message, release, true
      if release then table.insert(releases, release) end
    end)
    wait_for(function() return done end, 2000)
    return failure, unlock
  end
  local ok, error_message = xpcall(function() callback(directory, acquire, children) end, debug.traceback)
  for _, child in ipairs(children) do child:kill(9); child:wait() end
  for _, release in ipairs(releases) do release(function() end) end
  vim.wait(20, function() return false end, 5)
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.pi.lock", function()
  it("a held lock times out without preventing the next acquisition after release", function()
    fixture(function(directory, acquire)
      local failure, release = acquire()
      eq(nil, failure)
      local timeout_error = acquire(40)
      eq("Session index lock timed out after 40ms: " .. directory .. "/sessions.json.lock", timeout_error)
      local closed = false
      release(function(error_message)
        eq(nil, error_message)
        closed = true
      end)
      wait_for(function() return closed end)
      eq(nil, acquire())
      eq("file", vim.uv.fs_stat(directory .. "/sessions.json.lock").type)
    end)
  end)

  it("a waiting writer acquires the lock only after the previous writer releases it", function()
    fixture(function(directory, acquire)
      local failure, release = acquire()
      eq(nil, failure)
      local acquired, second_release = false, nil
      lock.acquire(directory .. "/sessions.json.lock", 1000, function(error_message, unlock)
        eq(nil, error_message)
        acquired, second_release = true, unlock
      end)
      eq(false, vim.wait(50, function() return acquired end, 5))
      release(function() end)
      wait_for(function() return acquired end)
      local closed = false
      second_release(function() closed = true end)
      wait_for(function() return closed end)
    end)
  end)

  it("a killed Neovim process releases its lock without stale-file deletion", function()
    fixture(function(directory, acquire, children)
      local ready, output = false, ""
      local child = vim.system({ vim.v.progpath, "-u", "NONE", "-l", root .. "/tests/fixtures/index_worker.lua", root, directory, "hold" }, {
        stdout = function(_, data)
          output = output .. (data or "")
          if output:find("locked\n", 1, true) then ready = true end
        end,
      })
      table.insert(children, child)
      wait_for(function() return ready end, 5000)
      eq("Session index lock timed out after 40ms: " .. directory .. "/sessions.json.lock", acquire(40))
      child:kill(9)
      child:wait()
      table.remove(children)
      eq(nil, acquire())
    end)
  end)

  it("an invalid parent directory reports an error without granting a lock", function()
    fixture(function(directory)
      vim.fn.writefile({ "not a directory" }, directory)
      local done, failure, unlock = false, nil, nil
      lock.acquire(directory .. "/sessions.json.lock", 40, function(error_message, release)
        failure, unlock, done = error_message, release, true
      end)
      wait_for(function() return done end)
      truthy(failure:find("ENOTDIR", 1, true))
      eq(nil, unlock)
    end)
  end)
end)
