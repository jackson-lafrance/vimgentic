local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}
local Window = {}
Window.__index = Window
local widget_namespace = vim.api.nvim_create_namespace("vimgentic.widget")

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function configure_buffer(buffer, name, filetype, modifiable)
  vim.api.nvim_buf_set_name(buffer, name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = filetype
  vim.bo[buffer].modifiable = modifiable
end

function Window.new()
  local transcript_buffer = vim.api.nvim_create_buf(false, true)
  local input_buffer = vim.api.nvim_create_buf(false, true)
  configure_buffer(transcript_buffer, "vimgentic://chat", "markdown", false)
  configure_buffer(input_buffer, "vimgentic://input", "markdown", true)
  vim.api.nvim_buf_set_lines(input_buffer, 0, -1, false, { "" })
  local self = setmetatable({
    transcript_buffer = transcript_buffer,
    input_buffer = input_buffer,
    widgets = {},
  }, Window)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = input_buffer,
    callback = function() self:resize_input() end,
  })
  return self
end

function Window:is_sidebar(window)
  if not valid_window(window) then
    return false
  end
  local buffer = vim.api.nvim_win_get_buf(window)
  return buffer == self.transcript_buffer or buffer == self.input_buffer or buffer == self.terminal_buffer
end

function Window:_remember_editor()
  local current = vim.api.nvim_get_current_win()
  if not self:is_sidebar(current) then
    self.previous_window = current
  end
end

function Window:open()
  if valid_window(self.transcript_window) and valid_window(self.input_window) then
    return
  end
  self:_remember_editor()
  vim.cmd("botright vsplit")
  self.transcript_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.transcript_window, self.transcript_buffer)
  local chat_config = config.get().chat
  local maximum = math.max(20, vim.o.columns - 20)
  local width = math.min(maximum, math.max(chat_config.min_width, math.floor(vim.o.columns * chat_config.width)))
  vim.api.nvim_win_set_width(self.transcript_window, width)
  vim.wo[self.transcript_window].wrap = true
  vim.wo[self.transcript_window].linebreak = true
  vim.wo[self.transcript_window].conceallevel = 2
  vim.wo[self.transcript_window].number = false
  vim.wo[self.transcript_window].relativenumber = false
  vim.wo[self.transcript_window].signcolumn = "no"
  vim.wo[self.transcript_window].winfixwidth = true
  vim.cmd("belowright split")
  self.input_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.input_window, self.input_buffer)
  vim.wo[self.input_window].wrap = true
  vim.wo[self.input_window].linebreak = true
  vim.wo[self.input_window].number = false
  vim.wo[self.input_window].relativenumber = false
  vim.wo[self.input_window].signcolumn = "no"
  self:resize_input()
  self:update_winbar()
  if self.handlers and not self.input_configured then
    require("vimgentic.chat.input").setup(self.input_buffer, self.handlers)
    self.input_configured = true
  end
end

function Window:show()
  self:open()
  self:focus_input()
end

function Window:focus_input()
  self:open()
  if valid_window(self.input_window) then
    vim.api.nvim_set_current_win(self.input_window)
    vim.cmd("startinsert")
  end
end

function Window:focus_flip()
  local current = vim.api.nvim_get_current_win()
  if self:is_sidebar(current) then
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
    return
  end
  self.previous_window = current
  self:focus_input()
end

function Window:close()
  self:_remember_editor()
  if valid_window(self.input_window) then
    vim.api.nvim_win_close(self.input_window, true)
  end
  if valid_window(self.transcript_window) then
    vim.api.nvim_win_close(self.transcript_window, true)
  end
  self.input_window = nil
  self.transcript_window = nil
end

function Window:resize_input()
  if not valid_window(self.input_window) then
    return
  end
  local chat_config = config.get().chat
  local lines = vim.api.nvim_buf_line_count(self.input_buffer)
  local widget_lines = 0
  for _, widget in pairs(self.widgets) do
    widget_lines = widget_lines + #widget
  end
  local height = math.max(chat_config.input_height, math.min(chat_config.input_max_height, lines + widget_lines + 1))
  pcall(vim.api.nvim_win_set_height, self.input_window, height)
end

function Window:set_handlers(handlers)
  self.handlers = handlers
  if not self.input_configured then
    require("vimgentic.chat.input").setup(self.input_buffer, handlers)
    self.input_configured = true
  end
  vim.keymap.set("n", "q", function() self:close() end, { buffer = self.transcript_buffer, nowait = true })
  vim.keymap.set("n", "<Tab>", function()
    pcall(vim.cmd, "normal! za")
  end, { buffer = self.transcript_buffer, desc = "Toggle vimgentic block" })
  vim.keymap.set({ "n", "i" }, "<C-c>", handlers.abort, { buffer = self.transcript_buffer })
  vim.keymap.set({ "n", "i" }, "<C-c>", handlers.abort, { buffer = self.input_buffer })
end

function Window:set_winbar_provider(provider)
  self.winbar_provider = provider
  self:update_winbar()
end

function Window:update_winbar()
  if valid_window(self.transcript_window) then
    vim.wo[self.transcript_window].winbar = self.winbar_provider and self.winbar_provider() or " vimgentic "
  end
end

function Window:set_widget(key, lines)
  if lines and #lines > 0 then
    self.widgets[key] = lines
  else
    self.widgets[key] = nil
  end
  if not vim.api.nvim_buf_is_valid(self.input_buffer) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.input_buffer, widget_namespace, 0, -1)
  local virtual_lines = {}
  local keys = vim.tbl_keys(self.widgets)
  table.sort(keys)
  for _, widget_key in ipairs(keys) do
    for _, line in ipairs(self.widgets[widget_key]) do
      table.insert(virtual_lines, { { line, "Comment" } })
    end
  end
  if #virtual_lines > 0 then
    vim.api.nvim_buf_set_extmark(self.input_buffer, widget_namespace, 0, 0, {
      virt_lines = virtual_lines,
      virt_lines_above = true,
    })
  end
  self:resize_input()
end

function Window:get_input()
  return table.concat(vim.api.nvim_buf_get_lines(self.input_buffer, 0, -1, false), "\n")
end

function Window:set_input(text)
  util.set_buffer_lines(self.input_buffer, 0, -1, util.split_lines(text or ""))
  if valid_window(self.input_window) then
    local count = vim.api.nvim_buf_line_count(self.input_buffer)
    pcall(vim.api.nvim_win_set_cursor, self.input_window, { count, #vim.api.nvim_buf_get_lines(self.input_buffer, count - 1, count, false)[1] })
  end
  self:resize_input()
end

function Window:append_input(text)
  local current = self:get_input()
  if current:match("^%s*$") then
    self:set_input(text)
  else
    self:set_input(current .. "\n" .. text)
  end
end

function Window:use_transcript_buffer()
  if valid_window(self.transcript_window) then
    vim.api.nvim_win_set_buf(self.transcript_window, self.transcript_buffer)
  end
  self.terminal_buffer = nil
end

function Window:use_terminal_buffer(buffer)
  self.terminal_buffer = buffer
  if valid_window(self.transcript_window) then
    vim.api.nvim_win_set_buf(self.transcript_window, buffer)
  end
end

M.Window = Window
return M
