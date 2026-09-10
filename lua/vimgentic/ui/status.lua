local M = {}
local namespace = vim.api.nvim_create_namespace("vimgentic.status")
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local Status = {}
Status.__index = Status

function Status:_text()
  local activity = self.activity and self.activity ~= "" and ("  " .. self.activity) or ""
  return frames[self.frame] .. " vimgentic" .. activity
end

function Status:_draw()
  if self.stopped then
    return
  end
  if self.kind == "command" then
    vim.api.nvim_echo({ { self:_text(), "DiagnosticInfo" } }, false, {})
    return
  end
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    self:stop()
    return
  end
  local position = vim.api.nvim_buf_get_extmark_by_id(self.buffer, namespace, self.start_mark, {})
  if #position == 0 then
    self:stop()
    return
  end
  local ok = pcall(vim.api.nvim_buf_set_extmark, self.buffer, namespace, position[1], position[2], {
    id = self.start_mark,
    strict = false,
    right_gravity = false,
    virt_lines = { { { self:_text(), "DiagnosticInfo" } } },
    virt_lines_above = true,
  })
  if not ok then
    self:stop()
  end
end

function Status:set_activity(text)
  self.activity = text
  self:_draw()
end

function Status:get_range()
  if self.kind ~= "range" or not vim.api.nvim_buf_is_valid(self.buffer) then
    return nil
  end
  local start_position = vim.api.nvim_buf_get_extmark_by_id(self.buffer, namespace, self.start_mark, {})
  local end_position = vim.api.nvim_buf_get_extmark_by_id(self.buffer, namespace, self.end_mark, {})
  if #start_position == 0 or #end_position == 0 then
    return nil
  end
  return start_position[1], end_position[1]
end

function Status:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
  end
  if self.kind == "command" then
    vim.api.nvim_echo({ { "" } }, false, {})
  elseif vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_del_extmark(self.buffer, namespace, self.start_mark)
    vim.api.nvim_buf_del_extmark(self.buffer, namespace, self.end_mark)
  end
end

local function start(status)
  status.frame = 1
  status.timer = vim.uv.new_timer()
  status.timer:start(120, 120, function()
    vim.schedule(function()
      if status.stopped then
        return
      end
      status.frame = (status.frame % #frames) + 1
      status:_draw()
    end)
  end)
  status:_draw()
  return status
end

function M.command()
  return start(setmetatable({ kind = "command", stopped = false }, Status))
end

function M.range(buffer, start_line, end_line)
  local start_row = start_line - 1
  local finish_row = end_line
  local start_mark = vim.api.nvim_buf_set_extmark(buffer, namespace, start_row, 0, {
    strict = false,
    right_gravity = false,
  })
  local end_mark = vim.api.nvim_buf_set_extmark(buffer, namespace, finish_row, 0, {
    strict = false,
    right_gravity = true,
  })
  return start(setmetatable({
    kind = "range",
    buffer = buffer,
    start_row = start_row,
    start_mark = start_mark,
    end_mark = end_mark,
    stopped = false,
  }, Status))
end

return M
