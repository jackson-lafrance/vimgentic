local util = require("vimgentic.util")

local M = {}

function M.open(options)
  options = options or {}
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "vimgentic://prompt/" .. buffer)
  local width = math.max(40, math.min(90, vim.o.columns - 8))
  local height = math.max(3, math.min(10, vim.o.lines - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (options.title or "vimgentic") .. " (:w to submit) ",
    title_pos = "center",
  })
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "markdown"
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  local prefill = options.prefill or ""
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, util.split_lines(prefill))
  vim.api.nvim_win_set_cursor(window, { vim.api.nvim_buf_line_count(buffer), 0 })

  local closed = false
  local function close(cancelled)
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    elseif vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    if cancelled and options.on_cancel then
      options.on_cancel()
    end
  end

  local function submit()
    if closed or not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    local prompt = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    if prompt:match("^%s*$") then
      util.notify("Enter a prompt before submitting", vim.log.levels.WARN)
      return
    end
    close(false)
    options.on_submit(prompt)
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      if not closed then
        closed = true
        if options.on_cancel then options.on_cancel() end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buffer,
    once = false,
    callback = submit,
  })
  vim.keymap.set("n", "q", function() close(true) end, { buffer = buffer, nowait = true })
  vim.cmd("startinsert")

  return {
    buffer = buffer,
    window = window,
    close = function() close(true) end,
    submit = submit,
  }
end

return M
