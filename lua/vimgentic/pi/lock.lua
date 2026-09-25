local util = require("vimgentic.util")

local M = {}
local available, ffi = pcall(require, "ffi")
if available and (ffi.os == "OSX" or ffi.os == "Linux") then
  ffi.cdef("int flock(int fd, int operation); char *strerror(int errnum);")
else
  available = false
end

function M.acquire(path, timeout, callback)
  if not available then
    vim.schedule(function() callback("Session index locking requires LuaJIT on macOS or Linux") end)
    return
  end
  util.mkdir_p(vim.fs.dirname(path), function(directory_error)
    if directory_error then callback(directory_error); return end
    -- Keep this file: unlinking it allows two processes to lock different inodes.
    vim.uv.fs_open(path, "a", 384, function(open_error, descriptor)
      if open_error then callback(open_error); return end
      local deadline = vim.uv.hrtime() + timeout * 1000000
      local function fail(message)
        vim.uv.fs_close(descriptor, function() callback(message) end)
      end
      local function attempt()
        -- LOCK_EX | LOCK_NB: contention must never block Neovim's main thread.
        if ffi.C.flock(descriptor, 6) == 0 then
          local released = false
          callback(nil, function(on_release)
            if released then return end
            released = true
            -- Closing the descriptor also releases the lock after a process crash.
            vim.uv.fs_close(descriptor, on_release)
          end)
          return
        end
        local number = ffi.errno()
        local would_block = ffi.os == "OSX" and 35 or 11
        if number ~= would_block and number ~= 4 then
          fail("Could not lock " .. path .. ": " .. ffi.string(ffi.C.strerror(number)))
        elseif vim.uv.hrtime() >= deadline then
          fail(string.format("Session index lock timed out after %dms: %s", timeout, path))
        else
          vim.schedule(function() vim.defer_fn(attempt, 20) end)
        end
      end
      attempt()
    end)
  end)
end

return M
