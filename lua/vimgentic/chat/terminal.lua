local cli = require("vimgentic.pi.cli")
local config = require("vimgentic.config")
local session_state = require("vimgentic.chat.state")
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

local function default_start(_, command, cwd, on_exit, env)
  return vim.fn.termopen(command, {
    cwd = cwd,
    env = env,
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
    current_cwd = options.current_cwd or util.cwd,
    read_state = options.read_state or session_state.read,
    session_state = options.session_state or vim.fn.tempname(),
    on_session = options.on_session,
    enter_insert = options.enter_insert ~= false,
    model = options.model,
    on_start = options.on_start,
    schedule = options.schedule or vim.schedule,
    send = options.send or default_send,
    session_id = options.session_id or cli.session_id(),
    session_log = options.session_log or (vim.fn.stdpath("data") .. "/vimgentic/session-log.jsonl"),
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
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { buffer = buffer, remap = false, desc = "Enter normal mode" })
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

function Terminal:_sync_session(callback)
  callback = callback or function() end
  local token = self.job_token
  if not token then callback(); return end
  self.state_read = (self.state_read or 0) + 1
  local reading = self.state_read
  self.read_state(self.session_state, tostring(token), function(error_message, state)
    if token == self.job_token and reading == self.state_read then
      if error_message and error_message ~= self.state_error then
        util.notify(error_message, vim.log.levels.ERROR)
      end
      self.state_error = error_message
      if state then
        local changed = self.session_path ~= state.path or self.cwd ~= state.cwd
        self.session_path, self.session_id, self.cwd = state.path, state.id, state.cwd
        if changed and self.on_session then self.on_session(state) end
      end
    end
    callback(error_message)
  end)
end

function Terminal:_stop_watcher()
  if self.state_watcher then
    self.state_watcher:stop()
    self.state_watcher:close()
    self.state_watcher = nil
  end
end

function Terminal:_handle_exit(token, code)
  if token ~= self.job_token or self.exiting then return end
  self.job_id = nil
  self.exit_code = code
  self.exiting = true
  self:_stop_watcher()
  self:_sync_session(function()
    if token ~= self.job_token then return end
    self.exiting = false
    local restart = self.restart_after_exit
    self.restart_after_exit = nil
    if restart and not self.shutting_down then
      self.cwd, self.session_path, self.session_id = restart.cwd, restart.path, restart.id
      self:_replace_buffer()
      self:_show(restart.callback)
    end
  end)
end

function Terminal:_start()
  if self.job_id or self.exiting then
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
  local env = {
    VIMGENTIC_SESSION_LOG = self.session_log,
    VIMGENTIC_SESSION_STATE = self.session_state,
    VIMGENTIC_SESSION_TOKEN = tostring(token),
  }
  local command = self:command()
  local ok, job_id = pcall(self.start_job, self.buffer, command, self.cwd, function(code)
    self.schedule(function() self:_handle_exit(token, code) end)
  end, env)
  if not ok or not job_id or job_id <= 0 then
    self.job_id = nil
    util.notify("Could not start pi terminal: " .. tostring(job_id), vim.log.levels.ERROR)
    return
  end
  self.job_id = job_id
  self.exit_code = nil
  self:_stop_watcher()
  self.state_watcher = vim.uv.new_fs_poll()
  self.state_watcher:start(self.session_state, 250, function(error_message)
    if not error_message then
      self.schedule(function()
        if token == self.job_token and self.job_id and not self.exiting and not self.action_pending then self:_sync_session() end
      end)
    end
  end)
  if self.on_start then self.on_start(self.session_path, self.session_id, self.cwd) end
end

function Terminal:_show(callback)
  self:_open_window()
  self:_start()
  if self.enter_insert and self.job_id then vim.cmd("startinsert") end
  if callback then callback(self.job_id ~= nil) end
end

function Terminal:_with_project(action)
  if self.action_pending or self.exiting then
    util.notify("A chat switch is already pending; try again after it finishes", vim.log.levels.WARN)
    return false
  end
  self.shutting_down = false
  self.action_pending = true
  self.action_serial = (self.action_serial or 0) + 1
  local serial = self.action_serial
  local cwd = self.current_cwd()
  local function finish() if serial == self.action_serial then self.action_pending = false end end
  local function current()
    if serial ~= self.action_serial or self.shutting_down then return false end
    if self.exiting then
      util.notify("Pi is stopping; retry the chat action", vim.log.levels.WARN)
      finish()
      return false
    end
    if self.current_cwd() ~= cwd then
      util.notify("The editor directory changed; retry the chat action", vim.log.levels.WARN)
      finish()
      return false
    end
    return true
  end
  if not self.job_token and not self.session_path then self.cwd = cwd end
  self:_sync_session(function(error_message)
    if not current() then return end
    if error_message then finish(); return end
    if self.cwd == cwd then action(finish); return end
    vim.ui.select({ "Switch project", "Keep current chat", "Cancel" }, {
      prompt = string.format("Chat uses %s. Switch to %s? This stops Pi and starts a new chat; unsent input is lost.", self.cwd, cwd),
    }, function(choice)
      if not current() then return end
      if choice == "Switch project" then
        self:_restart({ cwd = cwd, id = cli.session_id() }, function(started)
          if started then action(finish) else finish() end
        end)
      elseif choice == "Keep current chat" then
        action(finish)
      else
        finish()
      end
    end)
  end)
  return true
end

function Terminal:open()
  return self:_with_project(function(finish) self:_show(finish) end)
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

function Terminal:_restart(target, callback)
  target.callback = callback
  self:_open_window()
  if not self.job_id then
    self.cwd, self.session_path, self.session_id = target.cwd, target.path, target.id
    self:_show(callback)
    return
  end
  self.restart_after_exit = target
  self.stop_job(self.job_id)
end

function Terminal:switch_session(path, cwd)
  if self.action_pending or self.exiting then
    util.notify("A chat switch is already pending; try again after it finishes", vim.log.levels.WARN)
    return false
  end
  self.shutting_down = false
  self.action_pending = true
  self:_restart({ path = path, cwd = cwd or self.cwd }, function() self.action_pending = false end)
  return true
end

function Terminal:set_model(model)
  if not self.job_id or not model then self.model = model; return end
  self:_with_project(function(finish)
    self.model = model
    if self.job_id then self.send(self.job_id, "/model " .. model .. "\r") end
    finish()
  end)
end

function Terminal:send_text(text)
  if text:find("[%z\1-\8\11-\31\127]") then
    util.notify("The draft contains terminal control characters; nothing was sent", vim.log.levels.WARN)
    return false
  end
  return self:_with_project(function(finish)
    self:_show(function(started)
      if started then self.send(self.job_id, "\27[200~" .. text .. "\27[201~") end
      finish()
    end)
  end)
end

function Terminal:abort()
  if self.job_id then
    self.send(self.job_id, "\003")
  end
end

function Terminal:shutdown()
  self.shutting_down = true
  self.action_serial = (self.action_serial or 0) + 1
  self.action_pending = false
  self:_stop_watcher()
  self.restart_after_exit = nil
  if self.job_id then
    self.stop_job(self.job_id)
  end
end

M.Terminal = Terminal
return M
