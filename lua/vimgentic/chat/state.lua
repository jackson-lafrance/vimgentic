local M = {}

function M.read(path, token, callback)
  local function finish(error_message, state)
    vim.schedule(function() callback(error_message, state) end)
  end
  vim.uv.fs_open(path, "r", 384, function(open_error, descriptor)
    if open_error then
      if tostring(open_error):match("ENOENT") then finish() else finish(open_error) end
      return
    end
    vim.uv.fs_read(descriptor, 65537, 0, function(read_error, contents)
      vim.uv.fs_close(descriptor)
      if read_error then finish(read_error); return end
      contents = contents or ""
      local ok, state = pcall(vim.json.decode, contents)
      if not ok or #contents > 65536 or type(state) ~= "table"
        or type(state.path) ~= "string" or state.path == ""
        or type(state.cwd) ~= "string" or state.cwd == ""
        or type(state.id) ~= "string" or state.id == "" then
        finish("Invalid pi terminal session state: " .. path)
      elseif state.token == token then
        finish(nil, state)
      else
        finish()
      end
    end)
  end)
end

return M
