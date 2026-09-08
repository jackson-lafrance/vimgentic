local cli = require("vimgentic.pi.cli")
local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}
local Terminal = {}
Terminal.__index = Terminal

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function default_start(_, command, cwd, on_exit)
  return vim.fn.termopen(command, {
    cwd = cwd,
    on_exit = function(_, code) on_exit(code) end,
  })
end

local function default_stop(job_id)
  vim.fn.jobstop(job_id)
end

local function default_send(job_id, text)
  vim.api.nvim_chan_send(job_id, text)
end

function Terminal.new(options)
  options = options or {}
  return setmetatable({
    cwd = options.cwd or util.cwd(),
    enter_insert = options.enter_insert ~= false,
    model = options.model,
    on_start = options.on_start,
    schedule = options.schedule or vim.schedule,
    send = options.send or default_send,
    session_id = options.session_id or cli.session_id(),
    session_path = options.session_path,
    start_job = options.start_job or default_start,
    stop_job = options.stop_job or default_stop,
  }, Terminal)
end

function Terminal:_create_buffer()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  self.buffer = buffer
  self:_set_keymaps(buffer)
  return buffer
end

function Terminal:_set_keymaps(buffer)
  vim.keymap.set("n", "q", function() self:close() end, { buffer = buffer, nowait = true, desc = "Hide pi sidebar" })
  vim.keymap.set("n", "<leader>9c", function() self:focus_flip() end, { buffer = buffer, desc = "Focus editor" })
  vim.keymap.set("n", "<leader>9C", function() self:close() end, { buffer = buffer, desc = "Hide pi sidebar" })
  vim.keymap.set("n", "<leader>9x", function() self:abort() end, { buffer = buffer, desc = "Abort pi" })
  vim.keymap.set("t", "<leader>9c", function() self:focus_editor() end, { buffer = buffer, desc = "Focus editor" })
  vim.keymap.set("t", "<leader>9C", function() self:close() end, { buffer = buffer, desc = "Hide pi sidebar" })
  vim.keymap.set("t", "<leader>9x", function() self:abort() end, { buffer = buffer, desc = "Abort pi" })
end

function Terminal:is_sidebar(window)
  return valid_window(window) and vim.api.nvim_win_get_buf(window) == self.buffer
end

function Terminal:_remember_editor()
  local current = vim.api.nvim_get_current_win()
  if not self:is_sidebar(current) then
    self.previous_window = current
  end
end

function Terminal:_open_window()
  if valid_window(self.window) then
    vim.api.nvim_set_current_win(self.window)
    return
  end
  self:_remember_editor()
  if not valid_buffer(self.buffer) then
    self:_create_buffer()
  end
  vim.cmd("botright vsplit")
  self.window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.window, self.buffer)
  local chat_config = config.get().chat
  local maximum = math.max(20, vim.o.columns - 20)
  local width = math.min(maximum, math.max(chat_config.min_width, math.floor(vim.o.columns * chat_config.width)))
  vim.api.nvim_win_set_width(self.window, width)
  vim.wo[self.window].number = false
  vim.wo[self.window].relativenumber = false
  vim.wo[self.window].signcolumn = "no"
  vim.wo[self.window].winfixwidth = true
end

function Terminal:command()
  local options = {
    model = self.model,
    session_path = self.session_path,
    session_id = self.session_id,
  }
  if not self.session_path then
    options.name = "chat: " .. util.basename(self.cwd)
  end
  return cli.interactive(options)
end

function Terminal:_replace_buffer()
  local old_buffer = self.buffer
  local buffer = self:_create_buffer()
  if valid_window(self.window) then
    vim.api.nvim_win_set_buf(self.window, buffer)
  end
  if valid_buffer(old_buffer) then
    pcall(vim.api.nvim_buf_delete, old_buffer, { force = true })
  end
end

function Terminal:_handle_exit(token, code)
  if token ~= self.job_token then
    return
  end
  self.job_id = nil
  self.exit_code = code
  local restart = self.restart_after_exit
  self.restart_after_exit = nil
  if restart and not self.shutting_down then
    self:_replace_buffer()
    self:_start()
  end
end

function Terminal:_start()
  if self.job_id then
    return
  end
  if valid_buffer(self.buffer) and vim.bo[self.buffer].buftype == "terminal" then
    self:_replace_buffer()
  elseif not valid_buffer(self.buffer) then
    self:_create_buffer()
    if valid_window(self.window) then
      vim.api.nvim_win_set_buf(self.window, self.buffer)
    end
  end
  if valid_window(self.window) then
    vim.api.nvim_set_current_win(self.window)
    vim.api.nvim_win_set_buf(self.window, self.buffer)
  end
  self.job_token = (self.job_token or 0) + 1
  local token = self.job_token
  local command = self:command()
  local job_id = self.start_job(self.buffer, command, self.cwd, function(code)
    self.schedule(function() self:_handle_exit(token, code) end)
  end)
  if not job_id or job_id <= 0 then
    self.job_id = nil
    util.notify("Could not start pi terminal: " .. tostring(job_id), vim.log.levels.ERROR)
    return
  end
  self.job_id = job_id
  self.exit_code = nil
  if self.on_start then
    self.on_start(self.session_path, self.session_id)
  end
end

function Terminal:open()
  self.shutting_down = false
  self:_open_window()
  self:_start()
  if self.enter_insert and self.job_id then
    vim.cmd("startinsert")
  end
end

function Terminal:focus_editor()
  if valid_window(self.previous_window) then
    vim.api.nvim_set_current_win(self.previous_window)
    return
  end
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if not self:is_sidebar(window) then
      self.previous_window = window
      vim.api.nvim_set_current_win(window)
      return
    end
  end
end

function Terminal:focus_flip()
  local current = vim.api.nvim_get_current_win()
  if self:is_sidebar(current) then
    self:focus_editor()
  else
    self.previous_window = current
    self:open()
  end
end

function Terminal:close()
  self:_remember_editor()
  if valid_window(self.window) then
    vim.api.nvim_win_close(self.window, true)
  end
  self.window = nil
end

function Terminal:_restart()
  local running = self.job_id ~= nil
  self:open()
  if not running or not self.job_id then
    return
  end
  self.restart_after_exit = true
  self.stop_job(self.job_id)
end

function Terminal:switch_session(path)
  self.session_path = path
  self.session_id = nil
  self:_restart()
end

function Terminal:set_model(model)
  self.model = model
  if self.job_id and model then
    self.send(self.job_id, "/model " .. model .. "\r")
  end
end

function Terminal:send_text(text)
  self:open()
  if not self.job_id then
    return false
  end
  self.send(self.job_id, "\27[200~" .. text .. "\27[201~")
  return true
end

function Terminal:abort()
  if self.job_id then
    self.send(self.job_id, "\003")
  end
end

function Terminal:shutdown()
  self.shutting_down = true
  self.restart_after_exit = nil
  if self.job_id then
    self.stop_job(self.job_id)
  end
end

M.Terminal = Terminal
return M
