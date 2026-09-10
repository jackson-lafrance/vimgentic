local cli = require("vimgentic.pi.cli")
local config = require("vimgentic.config")
local index = require("vimgentic.pi.index")
local log = require("vimgentic.log")
local models = require("vimgentic.pi.models")
local rpc = require("vimgentic.pi.rpc")
local util = require("vimgentic.util")

local M = {}
local active = {}

local function tool_summary(event)
  local args = event.args or {}
  if event.toolName == "bash" and args.command then
    return args.command
  end
  if args.path then
    return event.toolName .. " " .. args.path
  end
  if args.query then
    return event.toolName .. " " .. args.query
  end
  return event.toolName or "tool"
end

local function agent_error(event)
  for index = #(event.messages or {}), 1, -1 do
    local message = event.messages[index]
    if message.role == "assistant" and message.stopReason == "error" then
      return message.errorMessage or "pi agent stopped with an error"
    end
  end
end

function M.run(options)
  local cwd = util.cwd()
  local request_id = log.request(options.kind, options.user_prompt)
  local client = rpc.new({
    argv = cli.build({
      model = models.get(options.kind),
      name = options.name,
      tools = options.tools,
    }),
    cwd = cwd,
    log_id = request_id,
  })
  local request = { client = client, status = options.status, done = false, on_finish = options.on_finish }
  active[request_id] = request
  local unsubscribe

  local function cleanup()
    active[request_id] = nil
    if unsubscribe then
      unsubscribe()
    end
    options.status:stop()
    client:close()
    if request.on_finish then
      request.on_finish()
    end
  end

  local function finish(text, error_message)
    if request.done then
      return
    end
    request.done = true
    if error_message then
      log.append(request_id, "error", error_message)
      cleanup()
      util.notify(error_message, vim.log.levels.ERROR)
      if options.on_error then
        options.on_error(error_message)
      end
      return
    end
    log.append(request_id, "assistant", text or "")
    local ok, callback_error = pcall(options.on_result, text or "")
    cleanup()
    if not ok then
      util.notify("vimgentic " .. options.kind .. ": " .. tostring(callback_error), vim.log.levels.ERROR)
    end
  end

  unsubscribe = client:on_event(function(event)
    if event.type == "tool_execution_start" then
      local summary = tool_summary(event)
      options.status:set_activity(util.truncate(summary, 120))
      log.append(request_id, "tool", summary)
    elseif event.type == "agent_settled" then
      client:send({ type = "get_last_assistant_text" }, function(response)
        if not response.success then
          finish(nil, response.error or "Could not read pi's response")
          return
        end
        finish(response.data and response.data.text or "")
      end)
    elseif event.type == "agent_end" then
      local error_message = agent_error(event)
      if error_message and not event.willRetry then
        finish(nil, error_message)
      end
    elseif event.type == "auto_retry_start" then
      options.status:set_activity("retry " .. tostring(event.attempt or ""))
      log.append(request_id, "retry", event.errorMessage or "")
    elseif event.type == "extension_error" then
      log.append(request_id, "extension_error", event.error or "")
    elseif event.type == "process_exit" and not request.done then
      local stderr = event.stderr or ""
      local message = stderr ~= "" and stderr or string.format("pi RPC process exited with code %s", tostring(event.code))
      finish(nil, message)
    end
  end)

  client:send({ type = "get_state" }, function(response)
    if not response.success or not response.data or not response.data.sessionFile then
      log.append(request_id, "index", response.error or "session file unavailable")
      return
    end
    local entry = vim.tbl_extend("force", vim.deepcopy(options.metadata or {}), {
      path = response.data.sessionFile,
      kind = options.kind,
      cwd = cwd,
      prompt = options.user_prompt,
    })
    index.add(entry, index.report_error)
  end)

  client:send({ type = "prompt", message = options.prompt }, function(response)
    if not response.success then
      finish(nil, response.error or "pi rejected the prompt")
    end
  end)

  vim.defer_fn(function()
    if request.done then
      return
    end
    client:write({ type = "abort" })
    finish(nil, string.format("vimgentic %s timed out after %dms", options.kind, config.get().timeout.operation))
  end, config.get().timeout.operation)

  return request_id
end

function M.abort_all()
  for _, request in pairs(active) do
    if not request.done then
      request.done = true
      request.client:write({ type = "abort" })
      request.status:stop()
      request.client:close()
      if request.on_finish then
        request.on_finish()
      end
    end
  end
  active = {}
end

return M
