local util = require("vimgentic.util")

local M = {}
local Follow = {}
Follow.__index = Follow

local function read_request(path)
  local descriptor = vim.uv.fs_open(path, "r", 384)
  if not descriptor then return end
  local contents = vim.uv.fs_read(descriptor, 65537, 0)
  vim.uv.fs_close(descriptor)
  if not contents or #contents > 65536 then return end
  local ok, request = pcall(vim.json.decode, contents)
  if ok and type(request) == "table" then return request end
end

local function safe_buffer(buffer)
  return vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == "" and not vim.bo[buffer].modified
end

function Follow.new(options)
  return setmetatable({
    enabled = options.enabled == true,
    control_path = options.control_path or vim.fn.tempname(),
    request_path = options.request_path or vim.fn.tempname(),
    editor_window = options.editor_window,
    visible = false,
  }, Follow)
end

function Follow:_publish()
  self.token = util.uuid()
  self.last_id = nil
  if not self.running then return end
  local temporary = self.control_path .. ".tmp"
  local descriptor, open_error = vim.uv.fs_open(temporary, "w", 384)
  if not descriptor then error(open_error) end
  local contents = vim.json.encode({ token = self.token, enabled = self.enabled and self.visible })
  local written, write_error = vim.uv.fs_write(descriptor, contents, 0)
  vim.uv.fs_close(descriptor)
  if written ~= #contents then error(write_error or "Could not write follow state") end
  local renamed, rename_error = vim.uv.fs_rename(temporary, self.control_path)
  if not renamed then error(rename_error) end
end

function Follow:set_visible(visible)
  if self.visible == visible then return end
  self.visible = visible
  self:_publish()
end

function Follow:toggle()
  self.enabled = not self.enabled
  self:_publish()
  util.notify("Pi follow: " .. (self.enabled and "on" or "off"))
  return self.enabled
end

function Follow:_receive()
  if not self.running then return end
  local request = read_request(self.request_path)
  if not request or request.token ~= self.token or type(request.id) ~= "string" or request.id == self.last_id then return end
  self.last_id = request.id
  if not self.enabled or not self.visible then return end
  if type(request.path) ~= "string" or request.path:sub(1, 1) ~= "/" or request.path:find("[%z\1-\31\127]")
    or type(request.line) ~= "number" or request.line < 1 or request.line % 1 ~= 0 then return end
  local window = self.editor_window()
  if not window or not vim.api.nvim_win_is_valid(window)
    or vim.api.nvim_win_get_tabpage(window) ~= vim.api.nvim_get_current_tabpage()
    or vim.api.nvim_win_get_config(window).relative ~= ""
    or not safe_buffer(vim.api.nvim_win_get_buf(window)) then return end
  local stat = vim.uv.fs_stat(request.path)
  if not stat or stat.type ~= "file" then return end
  local buffer = vim.fn.bufadd(request.path)
  if not safe_buffer(buffer) then return end
  vim.fn.bufload(buffer)
  if not safe_buffer(buffer) then return end
  local autoread = vim.bo[buffer].autoread
  vim.bo[buffer].autoread = true
  local checked, error_message = pcall(vim.cmd, "silent checktime " .. buffer)
  vim.bo[buffer].autoread = autoread
  if not checked then error(error_message) end
  if not vim.api.nvim_win_is_valid(window) or not safe_buffer(vim.api.nvim_win_get_buf(window)) or not safe_buffer(buffer) then return end
  vim.api.nvim_win_set_buf(window, buffer)
  local line = math.min(request.line, vim.api.nvim_buf_line_count(buffer))
  vim.api.nvim_win_set_cursor(window, { line, 0 })
end

function Follow:start()
  self:stop()
  self.running = true
  self:_publish()
  self.watcher = vim.uv.new_fs_poll()
  self.watcher:start(self.request_path, 100, function(error_message)
    if error_message then return end
    vim.schedule(function()
      local ok, receive_error = pcall(self._receive, self)
      if not ok then util.notify("Pi follow: " .. tostring(receive_error), vim.log.levels.WARN) end
    end)
  end)
end

function Follow:stop()
  self.running = false
  self.token = nil
  if self.watcher then
    self.watcher:stop()
    self.watcher:close()
    self.watcher = nil
  end
  vim.uv.fs_unlink(self.control_path)
  vim.uv.fs_unlink(self.request_path)
end

M.Follow = Follow
return M
