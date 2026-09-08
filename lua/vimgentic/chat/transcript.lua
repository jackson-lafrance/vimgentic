local util = require("vimgentic.util")

local M = {}
local Transcript = {}
Transcript.__index = Transcript

local function compact_json(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  return ok and encoded or tostring(value or "")
end

local function tool_detail(block)
  local args = block.meta.args or {}
  if block.kind == "bash" then
    return block.meta.command or ""
  end
  if block.meta.name == "bash" and args.command then
    return args.command
  end
  if args.path then
    return args.path
  end
  if args.query then
    return args.query
  end
  if block.meta.arguments_text and block.meta.arguments_text ~= "" then
    return block.meta.arguments_text
  end
  if next(args) then
    return compact_json(args)
  end
  return ""
end

local function block_lines(block)
  local lines = {}
  if block.kind == "user" then
    lines = { "## You" }
    vim.list_extend(lines, util.split_lines(block.text))
  elseif block.kind == "assistant_text" then
    lines = { "## Pi" }
    vim.list_extend(lines, util.split_lines(block.text))
  elseif block.kind == "thinking" then
    lines = { "▸ Thinking" }
    vim.list_extend(lines, util.split_lines(block.text))
  elseif block.kind == "tool" or block.kind == "bash" then
    local detail = tool_detail(block)
    local result_lines = block.text ~= "" and util.split_lines(block.text) or {}
    local status = block.meta.status or "running"
    local count = #result_lines > 0 and string.format(", %d lines", #result_lines) or ""
    local summary = string.format("▸ %s%s  (%s%s)", block.meta.name or block.kind, detail ~= "" and ("  " .. detail) or "", status, count)
    lines = { summary }
    vim.list_extend(lines, result_lines)
  elseif block.kind == "compaction" then
    lines = { "## Compaction" }
    vim.list_extend(lines, util.split_lines(block.text))
  else
    lines = { "> " .. (block.meta.title or "vimgentic") }
    vim.list_extend(lines, util.split_lines(block.text))
  end
  table.insert(lines, "")
  return lines
end

local function content_blocks(message)
  local blocks = {}
  for _, content in ipairs(message.content or {}) do
    if content.type == "text" then
      table.insert(blocks, { kind = "assistant_text", text = content.text or "", meta = {} })
    elseif content.type == "thinking" then
      table.insert(blocks, { kind = "thinking", text = content.thinking or "", meta = {} })
    elseif content.type == "toolCall" then
      table.insert(blocks, {
        kind = "tool",
        text = "",
        meta = {
          id = content.id,
          name = content.name,
          args = content.arguments or {},
          status = "running",
        },
      })
    end
  end
  return blocks
end

function Transcript.new(buffer, options)
  options = options or {}
  return setmetatable({
    buffer = buffer,
    blocks = {},
    content_indexes = {},
    render_count = 0,
    render_scheduled = false,
    schedule = options.schedule or vim.schedule,
    show_thinking = options.show_thinking or false,
    streaming_start = nil,
  }, Transcript)
end

function Transcript:_windows()
  local windows = {}
  for _, window in ipairs(vim.fn.win_findbuf(self.buffer)) do
    if vim.api.nvim_win_is_valid(window) then
      table.insert(windows, window)
    end
  end
  return windows
end

function Transcript:_apply_folds()
  for _, window in ipairs(self:_windows()) do
    vim.api.nvim_win_call(window, function()
      vim.wo.foldmethod = "manual"
      vim.cmd("silent! normal! zE")
      for _, block in ipairs(self.blocks) do
        local fold_start
        local fold_end
        if block.kind == "thinking" and not self.show_thinking then
          fold_start = block.first_line + 1
          fold_end = block.last_line - 1
        elseif (block.kind == "tool" or block.kind == "bash") and block.text ~= "" then
          fold_start = block.first_line + 1
          fold_end = block.last_line - 1
        end
        if fold_start and fold_end and fold_end > fold_start then
          vim.cmd(string.format("silent! %d,%dfold", fold_start, fold_end))
          vim.cmd(string.format("silent! %dfoldclose", fold_start))
        end
      end
    end)
  end
end

function Transcript:_render_from(block_index)
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    return
  end
  block_index = math.max(1, math.min(block_index, math.max(1, #self.blocks)))
  local start_line = 0
  if block_index > 1 then
    start_line = self.blocks[block_index - 1].last_line
  elseif self.blocks[block_index] and self.blocks[block_index].first_line then
    start_line = self.blocks[block_index].first_line - 1
  end
  local old_line_count = vim.api.nvim_buf_line_count(self.buffer)
  local follow = {}
  for _, window in ipairs(self:_windows()) do
    local cursor = vim.api.nvim_win_get_cursor(window)
    follow[window] = cursor[1] >= old_line_count
  end
  local rendered = {}
  local next_line = start_line + 1
  for index = block_index, #self.blocks do
    local lines = block_lines(self.blocks[index])
    self.blocks[index].first_line = next_line
    self.blocks[index].last_line = next_line + #lines - 1
    next_line = next_line + #lines
    vim.list_extend(rendered, lines)
  end
  local modifiable = vim.bo[self.buffer].modifiable
  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, start_line, -1, false, rendered)
  vim.bo[self.buffer].modifiable = modifiable
  self.render_count = self.render_count + 1
  self.last_render_from = block_index
  self:_apply_folds()
  local new_line_count = vim.api.nvim_buf_line_count(self.buffer)
  for window, should_follow in pairs(follow) do
    if should_follow and vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_set_cursor, window, { new_line_count, 0 })
    end
  end
end

function Transcript:_queue_render(block_index)
  self.pending_render_from = math.min(self.pending_render_from or block_index, block_index)
  if self.render_scheduled then
    return
  end
  self.render_scheduled = true
  self.schedule(function()
    self.render_scheduled = false
    local from = self.pending_render_from or 1
    self.pending_render_from = nil
    self:_render_from(from)
  end)
end

function Transcript:add(block)
  block.text = block.text or ""
  block.meta = block.meta or {}
  table.insert(self.blocks, block)
  self:_queue_render(#self.blocks)
  return #self.blocks
end

function Transcript:add_user(text)
  return self:add({ kind = "user", text = text, meta = {} })
end

function Transcript:add_system(text, title)
  return self:add({ kind = "system", text = text, meta = { title = title or "vimgentic" } })
end

function Transcript:add_bash(command)
  return self:add({ kind = "bash", text = "", meta = { name = "bash", command = command, status = "running" } })
end

function Transcript:update_bash(index, text, status)
  local block = self.blocks[index]
  if not block then
    return
  end
  block.text = text or block.text
  block.meta.status = status or block.meta.status
  self:_queue_render(index)
end

function Transcript:_find_tool(id)
  if not id then
    return nil
  end
  for index = #self.blocks, 1, -1 do
    if self.blocks[index].meta and self.blocks[index].meta.id == id then
      return index, self.blocks[index]
    end
  end
end

function Transcript:_authoritative(message)
  local start = self.streaming_start or (#self.blocks + 1)
  local previous = {}
  for index = start, #self.blocks do
    local block = self.blocks[index]
    if block.meta and block.meta.id then
      previous[block.meta.id] = block
    end
  end
  for index = #self.blocks, start, -1 do
    table.remove(self.blocks, index)
  end
  local rebuilt = content_blocks(message)
  for _, block in ipairs(rebuilt) do
    local old = block.meta.id and previous[block.meta.id]
    if old and old.text ~= "" then
      block.text = old.text
      block.meta.status = old.meta.status
    end
    table.insert(self.blocks, block)
  end
  self.content_indexes = {}
  self.streaming_start = nil
  self:_queue_render(math.max(1, start))
end

function Transcript:feed_event(event)
  if event.type == "message_start" and event.message and event.message.role == "assistant" then
    self.streaming_start = #self.blocks + 1
    self.content_indexes = {}
    return
  end
  if event.type == "message_update" then
    local delta = event.assistantMessageEvent or {}
    local content_index = tostring(delta.contentIndex or 0)
    local block_index = self.content_indexes[content_index]
    if delta.type == "text_start" or delta.type == "thinking_start" or delta.type == "toolcall_start" then
      local kind = delta.type == "text_start" and "assistant_text" or (delta.type == "thinking_start" and "thinking" or "tool")
      block_index = self:add({
        kind = kind,
        text = "",
        meta = kind == "tool" and { id = delta.id, name = delta.toolName, arguments_text = "", status = "running" } or {},
      })
      self.content_indexes[content_index] = block_index
    end
    local block = block_index and self.blocks[block_index]
    if not block then
      return
    end
    if delta.type == "text_delta" or delta.type == "thinking_delta" then
      block.text = block.text .. (delta.delta or "")
    elseif delta.type == "toolcall_delta" then
      block.meta.arguments_text = (block.meta.arguments_text or "") .. (delta.delta or "")
    elseif delta.type == "toolcall_end" and delta.toolCall then
      block.meta.id = delta.toolCall.id or block.meta.id
      block.meta.name = delta.toolCall.name or block.meta.name
      block.meta.args = delta.toolCall.arguments or block.meta.args
    end
    self:_queue_render(block_index)
    return
  end
  if event.type == "message_end" and event.message then
    if event.message.role == "assistant" then
      self:_authoritative(event.message)
    elseif event.message.role == "toolResult" then
      local index, block = self:_find_tool(event.message.toolCallId)
      if block then
        block.text = util.message_text(event.message.content)
        block.meta.status = event.message.isError and "error" or "done"
        self:_queue_render(index)
      end
    end
    return
  end
  if event.type == "tool_execution_start" then
    local index, block = self:_find_tool(event.toolCallId)
    if not block then
      index = self:add({ kind = "tool", text = "", meta = { id = event.toolCallId, name = event.toolName, status = "running" } })
      block = self.blocks[index]
    end
    block.meta.name = event.toolName or block.meta.name
    block.meta.args = event.args or block.meta.args
    block.meta.status = "running"
    self:_queue_render(index)
    return
  end
  if event.type == "tool_execution_update" then
    local index, block = self:_find_tool(event.toolCallId)
    if block then
      block.text = util.result_text(event.partialResult)
      self:_queue_render(index)
    end
    return
  end
  if event.type == "tool_execution_end" then
    local index, block = self:_find_tool(event.toolCallId)
    if block then
      block.text = util.result_text(event.result)
      block.meta.status = event.isError and "error" or "done"
      self:_queue_render(index)
    end
    return
  end
  if event.type == "compaction_start" then
    self:add({ kind = "compaction", text = "Compaction started: " .. tostring(event.reason or "manual"), meta = {} })
  elseif event.type == "compaction_end" then
    local text = event.errorMessage or (event.aborted and "Compaction aborted" or "Compaction complete")
    self:add({ kind = "compaction", text = text, meta = {} })
  end
end

function Transcript:render_messages(messages)
  self.blocks = {}
  self.content_indexes = {}
  self.streaming_start = nil
  for _, message in ipairs(messages or {}) do
    if message.role == "user" then
      table.insert(self.blocks, { kind = "user", text = util.message_text(message.content), meta = {} })
    elseif message.role == "assistant" then
      vim.list_extend(self.blocks, content_blocks(message))
    elseif message.role == "toolResult" then
      local _, block = self:_find_tool(message.toolCallId)
      if block then
        block.text = util.message_text(message.content)
        block.meta.status = message.isError and "error" or "done"
      end
    elseif message.role == "bashExecution" then
      table.insert(self.blocks, {
        kind = "bash",
        text = message.output or "",
        meta = { name = "bash", command = message.command, status = message.cancelled and "aborted" or "done" },
      })
    elseif message.role == "compactionSummary" or message.role == "branchSummary" then
      table.insert(self.blocks, { kind = "compaction", text = message.summary or "", meta = {} })
    elseif message.role == "custom" and message.display then
      table.insert(self.blocks, { kind = "system", text = util.message_text(message.content), meta = { title = message.customType } })
    end
  end
  self:_queue_render(1)
end

function Transcript:get_blocks()
  return self.blocks
end

M.Transcript = Transcript

return M
