local util = require("vimgentic.util")

local M = {}

M.names = {
  "/model", "/thinking", "/compact", "/new", "/name", "/session", "/fork", "/clone",
  "/export", "/resume", "/tree", "/abort", "/terminal",
}

local function response_error(chat, response)
  if response.success then
    return false
  end
  chat:add_system(response.error or (response.command .. " failed"), "error")
  return true
end

local function pick(title, entries, callback)
  require("fzf-lua").fzf_exec(entries, {
    prompt = title .. "> ",
    actions = {
      ["enter"] = function(selected)
        if selected[1] then
          callback(selected[1])
        end
      end,
    },
  })
end

local function model_command(chat, pattern)
  chat:send({ type = "get_available_models" }, function(response)
    if response_error(chat, response) then
      return
    end
    local models = response.data and response.data.models or {}
    local entries = {}
    local lookup = {}
    for _, model in ipairs(models) do
      local id = model.provider .. "/" .. model.id
      if pattern == "" or id:lower():find(pattern:lower(), 1, true) then
        local line = id .. (model.name and ("  " .. model.name) or "")
        table.insert(entries, line)
        lookup[line] = id
      end
    end
    if #entries == 0 then
      chat:add_system("No model matched: " .. pattern, "model")
      return
    end
    pick("Model", entries, function(selected)
      chat:set_model(lookup[selected])
    end)
  end)
end

local function thinking_command(chat, requested)
  if requested ~= "" then
    chat:send({ type = "set_thinking_level", level = requested }, function(response)
      if not response_error(chat, response) then
        chat.thinking_level = requested
        chat:add_system("Thinking level: " .. requested, "thinking")
        chat:update_winbar()
      end
    end)
    return
  end
  chat:send({ type = "get_available_thinking_levels" }, function(response)
    if response_error(chat, response) then
      return
    end
    pick("Thinking", response.data and response.data.levels or {}, function(level)
      thinking_command(chat, level)
    end)
  end)
end

local function stats_command(chat)
  chat:send({ type = "get_session_stats" }, function(response)
    if response_error(chat, response) then
      return
    end
    local stats = response.data or {}
    local context = stats.contextUsage or {}
    local tokens = stats.tokens or {}
    chat:add_system(table.concat({
      string.format("Session: %s", stats.sessionFile or "unknown"),
      string.format("Messages: %s user, %s assistant, %s tool calls", stats.userMessages or 0, stats.assistantMessages or 0, stats.toolCalls or 0),
      string.format("Tokens: %s", tokens.total or 0),
      string.format("Cost: $%.4f", stats.cost or 0),
      string.format("Context: %s/%s (%s%%)", context.tokens or "?", context.contextWindow or "?", context.percent or "?"),
    }, "\n"), "session")
    chat.context_percent = context.percent
    chat:update_winbar()
  end)
end

local function fork_command(chat)
  chat:send({ type = "get_fork_messages" }, function(response)
    if response_error(chat, response) then
      return
    end
    local lookup = {}
    local entries = {}
    for index, message in ipairs(response.data and response.data.messages or {}) do
      local line = string.format("%03d  %s", index, util.truncate(message.text, 120))
      lookup[line] = message
      table.insert(entries, line)
    end
    pick("Fork", entries, function(selected)
      local message = lookup[selected]
      if not message then
        return
      end
      chat:send({ type = "fork", entryId = message.entryId }, function(fork_response)
        if response_error(chat, fork_response) then
          return
        end
        chat.window:set_input(fork_response.data and fork_response.data.text or message.text)
        chat:refresh_state(true)
      end)
    end)
  end)
end

local function entry_summary(entry)
  if entry.type == "message" and entry.message then
    local role = entry.message.role or "message"
    return role .. ": " .. util.truncate(util.message_text(entry.message.content), 100), role
  end
  if entry.type == "compaction" then
    return "compaction: " .. util.truncate(entry.summary, 100), "compaction"
  end
  return entry.type or "entry", entry.type
end

local function tree_command(chat)
  chat:send({ type = "get_tree" }, function(response)
    if response_error(chat, response) then
      return
    end
    local lines = {}
    local rows = {}
    local function walk(nodes, depth)
      for _, node in ipairs(nodes or {}) do
        local summary, role = entry_summary(node.entry)
        table.insert(lines, string.rep("  ", depth) .. "• " .. summary)
        rows[#lines] = { entry = node.entry, role = role }
        walk(node.children, depth + 1)
      end
    end
    walk(response.data and response.data.tree or {}, 0)
    if #lines == 0 then
      lines = { "Empty session" }
    end
    local buffer = vim.api.nvim_create_buf(false, true)
    local width = math.max(50, math.min(110, vim.o.columns - 8))
    local height = math.max(8, math.min(#lines + 2, vim.o.lines - 8))
    local window = vim.api.nvim_open_win(buffer, true, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " Pi session tree — <CR> forks a user message ",
      title_pos = "center",
    })
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].modifiable = false
    vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, window, true) end, { buffer = buffer, nowait = true })
    vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, window, true) end, { buffer = buffer })
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(window)[1]
      local selected = rows[row]
      if not selected or selected.role ~= "user" then
        return
      end
      pcall(vim.api.nvim_win_close, window, true)
      chat:send({ type = "fork", entryId = selected.entry.id }, function(fork_response)
        if not response_error(chat, fork_response) then
          chat.window:set_input(fork_response.data and fork_response.data.text or util.message_text(selected.entry.message.content))
          chat:refresh_state(true)
          chat.window:focus_input()
        end
      end)
    end, { buffer = buffer })
  end)
end

function M.execute(chat, text)
  local command, arguments = text:match("^(%S+)%s*(.-)%s*$")
  if command == "/model" then
    model_command(chat, arguments)
  elseif command == "/thinking" then
    thinking_command(chat, arguments)
  elseif command == "/compact" then
    local payload = { type = "compact" }
    if arguments ~= "" then payload.customInstructions = arguments end
    chat:send(payload, function(response)
      if not response_error(chat, response) then chat:add_system("Compaction complete", "compact") end
    end, 600000)
  elseif command == "/new" then
    chat:send({ type = "new_session" }, function(response)
      if not response_error(chat, response) and not (response.data and response.data.cancelled) then
        chat.transcript:render_messages({})
        chat:refresh_state(true)
      end
    end)
  elseif command == "/name" then
    if arguments == "" then
      chat:add_system("Usage: /name <name>", "name")
    else
      chat:send({ type = "set_session_name", name = arguments }, function(response)
        if not response_error(chat, response) then
          chat.session_name = arguments
          chat:update_winbar()
        end
      end)
    end
  elseif command == "/session" then
    stats_command(chat)
  elseif command == "/fork" then
    fork_command(chat)
  elseif command == "/clone" then
    chat:send({ type = "clone" }, function(response)
      if not response_error(chat, response) and not (response.data and response.data.cancelled) then chat:refresh_state(true) end
    end)
  elseif command == "/export" then
    local payload = { type = "export_html" }
    if arguments ~= "" then payload.outputPath = vim.fn.expand(arguments) end
    chat:send(payload, function(response)
      if not response_error(chat, response) then chat:add_system("Exported to " .. tostring(response.data.path), "export") end
    end)
  elseif command == "/resume" then
    require("vimgentic.ui.picker").history()
  elseif command == "/tree" then
    tree_command(chat)
  elseif command == "/abort" then
    chat:abort()
  elseif command == "/terminal" then
    chat:terminal()
  else
    return false
  end
  return true
end

return M
