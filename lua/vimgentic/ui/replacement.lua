local util = require("vimgentic.util")

local M = {}
local namespace = vim.api.nvim_create_namespace("vimgentic.replacement")
local Replacement = {}
Replacement.__index = Replacement

function M.capture(context, options)
  local self = setmetatable({
    source = context.buffer,
    path = context.path,
    first = context.first,
    last = context.last,
    original = vim.deepcopy(context.lines),
    on_close = options and options.on_close,
  }, Replacement)
  self.mark = vim.api.nvim_buf_set_extmark(self.source, namespace, context.first - 1, 0, {
    end_row = context.last,
    end_col = 0,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
    undo_restore = false,
    strict = false,
  })
  self.source_autocmd = vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    buffer = self.source,
    once = true,
    callback = function() self:discard() end,
  })
  return self
end

function Replacement:check()
  if self.closed or not vim.api.nvim_buf_is_valid(self.source) or not vim.api.nvim_buf_is_loaded(self.source) then
    return nil, "The source buffer no longer exists; no text was replaced"
  end
  if vim.api.nvim_buf_get_name(self.source) ~= self.path then
    return nil, "The source buffer changed its name; no text was replaced"
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(self.source, namespace, self.mark, { details = true })
  if #mark == 0 or mark[3].invalid or not mark[3].end_row or mark[3].end_row <= mark[1] then
    return nil, "The selected range no longer exists; no text was replaced"
  end
  local first, last = mark[1], mark[3].end_row
  local current = vim.api.nvim_buf_get_lines(self.source, first, last, false)
  if not vim.deep_equal(current, self.original) then
    return nil, "The selected text changed; no text was replaced. Request a new replacement."
  end
  if not vim.bo[self.source].modifiable or vim.bo[self.source].readonly then
    return nil, "The source buffer is not writable; no text was replaced"
  end
  return first, last
end

function Replacement:propose(text)
  if self.closed then
    return false
  end
  self.replacement = util.split_lines(text)
  if vim.deep_equal(self.original, self.replacement) then
    self:discard()
    return false, "Pi returned unchanged code; no text was replaced"
  end
  self.ready = true
  return true
end

function Replacement:accept()
  if not self.ready or self.closed then
    return false, "No replacement is ready"
  end
  local first, last = self:check()
  if not first then
    return false, last
  end
  local ok, error_message = pcall(vim.api.nvim_buf_set_lines, self.source, first, last, false, self.replacement)
  if not ok then
    return false, tostring(error_message)
  end
  self:discard()
  return true
end

function Replacement:discard()
  if self.closed then
    return
  end
  self.closed = true
  if self.source_autocmd then
    pcall(vim.api.nvim_del_autocmd, self.source_autocmd)
  end
  if vim.api.nvim_buf_is_valid(self.source) and vim.api.nvim_buf_is_loaded(self.source) then
    vim.api.nvim_buf_del_extmark(self.source, namespace, self.mark)
  end
  local return_focus = self.window and vim.api.nvim_get_current_win() == self.window
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_win_close(self.window, true)
  end
  if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
  if return_focus and self.editor_window and vim.api.nvim_win_is_valid(self.editor_window) then
    vim.api.nvim_set_current_win(self.editor_window)
  end
  if self.on_close then
    self.on_close()
  end
end

function Replacement:open()
  if not self.ready or self.closed then
    return false
  end
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_set_current_win(self.window)
    return true
  end
  local diff = vim.diff(table.concat(self.original, "\n") .. "\n", table.concat(self.replacement, "\n") .. "\n", {
    result_type = "unified",
    ctxlen = 3,
  })
  local path = self.path ~= "" and self.path or "[No Name]"
  local lines = {
    string.format("--- %s (selected lines %d-%d)", path, self.first, self.last),
    "+++ proposed replacement",
  }
  vim.list_extend(lines, util.split_lines(diff))
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buffer].bufhidden = "wipe"
  vim.bo[self.buffer].swapfile = false
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, lines)
  vim.bo[self.buffer].filetype = "diff"
  vim.bo[self.buffer].modifiable = false
  vim.bo[self.buffer].readonly = true
  local width = math.max(1, math.min(110, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 6))
  self.editor_window = vim.api.nvim_get_current_win()
  self.window = vim.api.nvim_open_win(self.buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Replacement: Enter accepts, q/Esc discards ",
    title_pos = "center",
  })
  vim.wo[self.window].wrap = false
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = self.buffer,
    once = true,
    callback = function()
      if not self.closed then
        self.window = nil
        self.buffer = nil
        self:discard()
      end
    end,
  })
  vim.keymap.set("n", "<CR>", function()
    local applied, error_message = self:accept()
    if applied then
      util.notify("Replaced the selected lines in the buffer; use :write to save")
    else
      util.notify(error_message, vim.log.levels.ERROR)
    end
  end, { buffer = self.buffer, desc = "Accept replacement" })
  vim.keymap.set("n", "q", function() self:discard() end, { buffer = self.buffer, nowait = true, desc = "Discard replacement" })
  vim.keymap.set("n", "<Esc>", function() self:discard() end, { buffer = self.buffer, desc = "Discard replacement" })
  vim.cmd("stopinsert")
  return true
end

return M
