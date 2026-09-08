local config = require("vimgentic.config")
local log = require("vimgentic.log")

local M = {}

local Framer = {}
Framer.__index = Framer

function Framer.new(on_line)
  return setmetatable({ partial = "", on_line = on_line }, Framer)
end

function Framer:feed(chunk)
  if not chunk or chunk == "" then
    return
  end
  self.partial = self.partial .. chunk
  while true do
    local newline = self.partial:find("\n", 1, true)
    if not newline then
      return
    end
    local line = self.partial:sub(1, newline - 1)
    self.partial = self.partial:sub(newline + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line ~= "" then
      self.on_line(line)
    end
  end
end

function Framer:finish()
  if self.partial == "" then
    return
  end
  local line = self.partial
  self.partial = ""
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if line ~= "" then
    self.on_line(line)
  end
end

M.Framer = Framer

local Client = {}
Client.__index = Client

local function callback_error(command, error_message)
  return {
    type = "response",
    command = command,
    success = false,
    error = error_message,
  }
end

function Client:_schedule(callback)
  self.schedule(callback)
end

function Client:_dispatch_line(line)
  self:_schedule(function()
    local ok, message = pcall(vim.json.decode, line)
    if not ok then
      log.append(self.log_id, "decode_error", line .. "\n" .. tostring(message))
      for _, subscriber in pairs(self.subscribers) do
        subscriber({ type = "protocol_error", error = tostring(message), line = line })
      end
      return
    end
    if message.type == "response" and message.id ~= nil then
      local pending = self.pending[tostring(message.id)]
      if pending then
        self.pending[tostring(message.id)] = nil
        pending.callback(message)
        return
      end
    end
    for _, subscriber in pairs(self.subscribers) do
      subscriber(message)
    end
  end)
end

function Client:_write(encoded)
  if not self.alive then
    return false
  end
  local ok, error_message = pcall(self.writer, encoded)
  if not ok then
    log.append(self.log_id, "write_error", tostring(error_message))
    return false
  end
  return true
end

function Client:write(message)
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    return false, encoded
  end
  return self:_write(encoded .. "\n")
end

function Client:send(command, callback, timeout)
  callback = callback or function() end
  if not self.alive then
    self:_schedule(function()
      callback(callback_error(command.type, "pi RPC process is not running"))
    end)
    return nil
  end
  self.next_id = self.next_id + 1
  local id = command.id or self.next_id
  local payload = vim.deepcopy(command)
  payload.id = id
  self.pending[tostring(id)] = { callback = callback, command = command.type }
  local wrote, write_error = self:write(payload)
  if not wrote then
    self.pending[tostring(id)] = nil
    self:_schedule(function()
      callback(callback_error(command.type, "failed to write pi RPC command: " .. tostring(write_error or "closed stdin")))
    end)
    return nil
  end
  if not self.disable_timeouts then
    local timeout_ms = timeout or config.get().timeout.command
    vim.defer_fn(function()
      local pending = self.pending[tostring(id)]
      if not pending then
        return
      end
      self.pending[tostring(id)] = nil
      pending.callback(callback_error(command.type, string.format("pi RPC command timed out after %dms", timeout_ms)))
    end, timeout_ms)
  end
  return id
end

function Client:on_event(callback)
  self.next_subscriber = self.next_subscriber + 1
  local id = self.next_subscriber
  self.subscribers[id] = callback
  return function()
    self.subscribers[id] = nil
  end
end

function Client:is_alive()
  return self.alive
end

function Client:feed(chunk)
  self.framer:feed(chunk)
end

function Client:_exited(code, signal)
  if not self.alive and self.exit_emitted then
    return
  end
  self.alive = false
  self.exit_emitted = true
  self.framer:finish()
  self:_schedule(function()
    for id, pending in pairs(self.pending) do
      self.pending[id] = nil
      pending.callback(callback_error(pending.command, string.format("pi RPC process exited with code %s", tostring(code))))
    end
    local event = {
      type = "process_exit",
      code = code,
      signal = signal,
      stderr = table.concat(self.stderr),
    }
    for _, subscriber in pairs(self.subscribers) do
      subscriber(event)
    end
    for _, callback in ipairs(self.close_callbacks) do
      callback(event)
    end
    self.close_callbacks = {}
  end)
end

function Client:kill(signal)
  if self.process and self.alive then
    pcall(self.process.kill, self.process, signal or 15)
  elseif self.alive then
    self:_exited(0, signal or 15)
  end
end

function Client:close(callback)
  if not self.alive then
    if callback then
      self:_schedule(function()
        callback({ type = "process_exit", code = 0, signal = 0, stderr = table.concat(self.stderr) })
      end)
    end
    return
  end
  if callback then
    table.insert(self.close_callbacks, callback)
  end
  self:write({ type = "abort" })
  if self.process then
    pcall(self.process.write, self.process, nil)
    vim.defer_fn(function()
      if self.alive then
        self:kill(15)
      end
    end, 250)
  else
    self:_exited(0, 0)
  end
end

local function create(options)
  local client = setmetatable({
    alive = true,
    close_callbacks = {},
    disable_timeouts = options.disable_timeouts,
    exit_emitted = false,
    log_id = options.log_id or "rpc",
    next_id = 0,
    next_subscriber = 0,
    pending = {},
    schedule = options.schedule or vim.schedule,
    stderr = {},
    subscribers = {},
  }, Client)
  client.framer = Framer.new(function(line)
    client:_dispatch_line(line)
  end)
  return client
end

function M.new(options)
  options = options or {}
  local client = create(options)
  local argv = assert(options.argv, "vimgentic: rpc argv is required")
  local process
  process = vim.system(argv, {
    cwd = options.cwd,
    stdin = true,
    stdout = function(error_message, data)
      if error_message then
        log.append(client.log_id, "stdout_error", error_message)
      end
      if data then
        client.framer:feed(data)
      else
        client.framer:finish()
      end
    end,
    stderr = function(error_message, data)
      if error_message then
        log.append(client.log_id, "stderr_error", error_message)
      end
      if data and data ~= "" then
        table.insert(client.stderr, data)
        log.append(client.log_id, "stderr", data)
      end
    end,
  }, function(result)
    client:_exited(result.code, result.signal)
  end)
  client.process = process
  client.writer = function(data)
    process:write(data)
  end
  return client
end

function M._new_for_test(options)
  options = options or {}
  options.disable_timeouts = true
  local client = create(options)
  client.writer = options.write or function() end
  return client
end

return M
