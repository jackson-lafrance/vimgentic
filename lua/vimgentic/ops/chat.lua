local cli = require("vimgentic.pi.cli")
local commands = require("vimgentic.chat.commands")
local config = require("vimgentic.config")
local extui = require("vimgentic.chat.extui")
local index = require("vimgentic.pi.index")
local models = require("vimgentic.pi.models")
local rpc = require("vimgentic.pi.rpc")
local Transcript = require("vimgentic.chat.transcript").Transcript
local util = require("vimgentic.util")
local Window = require("vimgentic.chat.window").Window

local M = {}
local Chat = {}
Chat.__index = Chat
local instance

local function assistant_error(event)
  for message_index = #(event.messages or {}), 1, -1 do
    local message = event.messages[message_index]
    if message.role == "assistant" and message.stopReason == "error" then
      return message.errorMessage or "pi agent stopped with an error"
    end
  end
end

function Chat.new()
  local window = Window.new()
  local self = setmetatable({
    command_names = {},
    context_percent = nil,
    disconnected = false,
    extension_statuses = {},
    follow_up_count = 0,
    queue_count = 0,
    session_id = cli.session_id(),
    streaming = false,
    thinking_level = nil,
    window = window,
  }, Chat)
  self.transcript = Transcript.new(window.transcript_buffer, { show_thinking = config.get().chat.show_thinking })
  window:set_handlers({
    abort = function() self:abort() end,
    commands = function() return self.command_names end,
    submit = function(text, behavior) self:submit(text, behavior) end,
  })
  window:set_winbar_provider(function() return self:winbar() end)
  return self
end

function Chat:update_winbar()
  self.window:update_winbar()
end

function Chat:winbar()
  local parts = {
    " " .. (self.session_name or ("chat: " .. util.basename(util.cwd()))),
    self.model or "pi default",
    "thinking:" .. (self.thinking_level or "default"),
    "context:" .. (self.context_percent and (tostring(math.floor(self.context_percent)) .. "%") or "?"),
  }
  if self.queue_count > 0 or self.follow_up_count > 0 then
    table.insert(parts, string.format("queue:%d/%d", self.queue_count, self.follow_up_count))
  end
  if self.streaming then
    table.insert(parts, "[streaming]")
  elseif self.disconnected then
    table.insert(parts, "[disconnected]")
  end
  local status_keys = vim.tbl_keys(self.extension_statuses)
  table.sort(status_keys)
  for _, key in ipairs(status_keys) do
    table.insert(parts, self.extension_statuses[key])
  end
  return table.concat(parts, "  ") .. " "
end

function Chat:add_system(text, title)
  self.transcript:add_system(tostring(text or ""), title)
end

function Chat:_register_state(state)
  local old_path = self.session_path
  self.session_path = state.sessionFile or self.session_path
  self.session_name = state.sessionName or self.session_name
  self.thinking_level = state.thinkingLevel or self.thinking_level
  self.streaming = state.isStreaming or false
  if state.model then
    self.model = state.model.provider .. "/" .. state.model.id
  end
  self:update_winbar()
  if self.session_path and self.session_path ~= old_path then
    index.add({
      path = self.session_path,
      kind = "chat",
      cwd = util.cwd(),
      prompt = self.session_name or ("chat: " .. util.basename(util.cwd())),
    }, index.report_error)
  end
end

function Chat:refresh_state(register, callback)
  self:send({ type = "get_state" }, function(response)
    if response.success and response.data then
      if register then
        self.session_path = nil
      end
      self:_register_state(response.data)
    else
      self:add_system(response.error or "Could not read pi session state", "error")
    end
    if callback then callback(response) end
  end)
end

function Chat:_refresh_stats()
  if not self.rpc_client then
    return
  end
  self.rpc_client:send({ type = "get_session_stats" }, function(response)
    if response.success and response.data and response.data.contextUsage then
      self.context_percent = response.data.contextUsage.percent
      self:update_winbar()
    end
  end)
end

function Chat:_load_messages(callback)
  self:send({ type = "get_messages" }, function(response)
    if response.success then
      self.transcript:render_messages(response.data and response.data.messages or {})
    else
      self:add_system(response.error or "Could not load session messages", "error")
    end
    if callback then callback(response) end
  end)
end

function Chat:_load_commands()
  self:send({ type = "get_commands" }, function(response)
    if not response.success then
      return
    end
    local names = {}
    for _, command in ipairs(response.data and response.data.commands or {}) do
      table.insert(names, "/" .. command.name)
    end
    self.command_names = names
  end)
end

function Chat:_handle_event(client, event)
  if event.type == "extension_ui_request" then
    extui.handle(client, event, {
      window = self.window,
      set_status = function(key, value)
        self.extension_statuses[key] = value
        self:update_winbar()
      end,
    })
    return
  end
  if event.type == "agent_start" then
    self.streaming = true
    self:update_winbar()
  elseif event.type == "agent_settled" then
    self.streaming = false
    self:update_winbar()
    self:_refresh_stats()
  elseif event.type == "queue_update" then
    self.queue_count = #(event.steering or {})
    self.follow_up_count = #(event.followUp or {})
    self:update_winbar()
  elseif event.type == "agent_end" then
    local error_message = assistant_error(event)
    if error_message and not event.willRetry then
      self:add_system(error_message, "error")
    end
  elseif event.type == "auto_retry_start" then
    self:add_system(event.errorMessage or "Automatic retry started", "retry")
  elseif event.type == "auto_retry_end" and not event.success then
    self:add_system(event.finalError or "Automatic retry failed", "retry")
  elseif event.type == "extension_error" then
    self:add_system(event.error or "Pi extension error", "extension error")
  elseif event.type == "process_exit" then
    if self.rpc_client == client then
      self.rpc_client = nil
    end
    if not self.terminal_active then
      self.disconnected = true
      local message = event.stderr ~= "" and event.stderr or string.format("pi RPC process exited with code %s", tostring(event.code))
      self:add_system(message, "disconnected")
    end
    self:update_winbar()
  elseif event.type == "bash_execution_update" then
    local bash = self.bash_requests and self.bash_requests[tostring(event.id)]
    if bash then
      bash.output = bash.output .. (event.delta or "")
      self.transcript:update_bash(bash.block, bash.output, "running")
    end
  end
  if event.type:match("^message_") or event.type:match("^tool_execution_") or event.type:match("^compaction_") then
    self.transcript:feed_event(event)
  end
end

function Chat:_spawn(session_path, callback)
  if self.rpc_client and self.rpc_client:is_alive() then
    if callback then callback() end
    return
  end
  local client = rpc.new({
    argv = cli.build({
      model = models.get("chat"),
      session_path = session_path,
      session_id = session_path and nil or self.session_id,
      name = session_path and nil or ("chat: " .. util.basename(util.cwd())),
    }),
    cwd = util.cwd(),
    log_id = "chat",
  })
  self.rpc_client = client
  self.disconnected = false
  client:on_event(function(event) self:_handle_event(client, event) end)
  client:send({ type = "get_state" }, function(response)
    if not response.success then
      self:add_system(response.error or "Could not start pi", "error")
      if callback then callback(response.error) end
      return
    end
    self:_register_state(response.data or {})
    self:_load_commands()
    if session_path then
      self:_load_messages(function() if callback then callback() end end)
    elseif callback then
      callback()
    end
  end)
end

function Chat:ensure_rpc(callback)
  if self.rpc_client and self.rpc_client:is_alive() then
    callback()
    return
  end
  self:_spawn(self.session_path, callback)
end

function Chat:send(command, callback, timeout)
  callback = callback or function() end
  self:ensure_rpc(function(error_message)
    if error_message then
      callback({ type = "response", command = command.type, success = false, error = error_message })
      return
    end
    self.rpc_client:send(command, callback, timeout)
  end)
end

function Chat:_bash(command)
  local block = self.transcript:add_bash(command)
  self.bash_requests = self.bash_requests or {}
  self:ensure_rpc(function(error_message)
    if error_message then
      self.transcript:update_bash(block, error_message, "error")
      return
    end
    local request = { block = block, output = "" }
    local id = self.rpc_client:send({ type = "bash", command = command }, function(response)
      local data = response.data or {}
      local output = data.output or request.output
      local status = response.success and (data.cancelled and "aborted" or (data.exitCode == 0 and "done" or "error")) or "error"
      if not response.success then output = response.error or output end
      self.transcript:update_bash(block, output, status)
      self.bash_requests[tostring(id)] = nil
    end, config.get().timeout.operation)
    if id then
      self.bash_requests[tostring(id)] = request
    end
  end)
end

function Chat:submit(text, behavior)
  text = text:gsub("%s+$", "")
  if text == "" then
    return
  end
  self.window:set_input("")
  if text:sub(1, 1) == "!" then
    self:_bash(text:sub(2))
    return
  end
  if text:sub(1, 1) == "/" and commands.execute(self, text) then
    return
  end
  local command_type = "prompt"
  if behavior == "followUp" then
    command_type = "follow_up"
  elseif self.streaming and text:sub(1, 1) ~= "/" then
    command_type = "steer"
  end
  self:ensure_rpc(function(error_message)
    if error_message then
      self:add_system(error_message, "error")
      return
    end
    self.transcript:add_user(text)
    self.rpc_client:send({ type = command_type, message = text }, function(response)
      if not response.success then
        self:add_system(response.error or "Pi rejected the message", "error")
      end
    end)
  end)
end

function Chat:set_model(model)
  local provider, model_id = util.model_parts(model)
  if not provider then
    self:add_system("Invalid model id: " .. tostring(model), "model")
    return
  end
  self:send({ type = "set_model", provider = provider, modelId = model_id }, function(response)
    if not response.success then
      self:add_system(response.error or "Could not change model", "model")
      return
    end
    self.model = model
    models.set("chat", model, function(error_message)
      if error_message then self:add_system(tostring(error_message), "model") end
    end)
    self:add_system("Model: " .. model, "model")
    self:update_winbar()
  end)
end

function Chat:abort()
  if self.rpc_client and self.rpc_client:is_alive() then
    self.rpc_client:write({ type = "abort" })
  end
end

function Chat:switch_session(path)
  self.window:open()
  self:ensure_rpc(function(error_message)
    if error_message then
      self:add_system(error_message, "error")
      return
    end
    self.rpc_client:send({ type = "switch_session", sessionPath = path }, function(response)
      if not response.success then
        self:add_system(response.error or "Could not switch session", "error")
        return
      end
      if response.data and response.data.cancelled then
        return
      end
      self.session_path = path
      self:_load_messages()
      self:refresh_state(true)
      self.window:focus_input()
    end)
  end)
end

function Chat:terminal()
  if not self.session_path then
    self:refresh_state(false, function(response)
      if response.success and self.session_path then
        self:terminal()
      else
        self:add_system(response.error or "The current chat has no session file", "terminal")
      end
    end)
    return
  end
  self.window:open()
  local path = self.session_path
  local function open_terminal()
    self.terminal_active = true
    local buffer = vim.api.nvim_create_buf(false, true)
    self.window:use_terminal_buffer(buffer)
    vim.api.nvim_set_current_win(self.window.transcript_window)
    vim.api.nvim_set_current_buf(buffer)
    vim.fn.termopen({ config.get().pi.command, "--session", path }, {
      cwd = util.cwd(),
      on_exit = function()
        vim.schedule(function()
          self.terminal_active = false
          if vim.api.nvim_buf_is_valid(buffer) then
            pcall(vim.api.nvim_buf_delete, buffer, { force = true })
          end
          self.window:use_transcript_buffer()
          self:_spawn(path)
        end)
      end,
    })
    vim.cmd("startinsert")
  end
  if self.rpc_client then
    local client = self.rpc_client
    self.rpc_client = nil
    self.terminal_active = true
    client:close(open_terminal)
  else
    open_terminal()
  end
end

function Chat:toggle()
  self.window:focus_flip()
  self:ensure_rpc(function(error_message)
    if error_message then self:add_system(error_message, "error") end
  end)
end

function Chat:close()
  self.window:close()
end

function Chat:selection_to_input()
  local buffer = vim.api.nvim_get_current_buf()
  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]
  if first > last then first, last = last, first end
  local path = vim.api.nvim_buf_get_name(buffer)
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, first - 1, last, false), "\n")
  local filetype = vim.bo[buffer].filetype
  local reference = string.format("@%s:%d-%d", util.relative_path(path), first, last)
  self.window:append_input(table.concat({ reference, "```" .. filetype, text, "```" }, "\n"))
  self.window:focus_input()
  self:ensure_rpc(function(error_message)
    if error_message then self:add_system(error_message, "error") end
  end)
end

function Chat:shutdown()
  if self.rpc_client then
    self.rpc_client:close()
    self.rpc_client = nil
  end
end

local function get()
  instance = instance or Chat.new()
  return instance
end

function M.toggle() get():toggle() end
function M.close() get():close() end
function M.abort() get():abort() end
function M.switch_session(path) get():switch_session(path) end
function M.selection_to_input() get():selection_to_input() end
function M.terminal() get():terminal() end
function M.shutdown() if instance then instance:shutdown() end end
function M.set_model(model) if instance then instance:set_model(model) end end
function M.instance() return get() end

return M
