local util = require("vimgentic.util")

local M = {}

local function respond(client, request, fields)
  local response = vim.tbl_extend("force", {
    type = "extension_ui_response",
    id = request.id,
  }, fields)
  client:write(response)
end

local function editor(client, request)
  local buffer = vim.api.nvim_create_buf(false, true)
  local width = math.max(40, math.min(100, vim.o.columns - 8))
  local height = math.max(6, math.min(20, vim.o.lines - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (request.title or "Pi extension editor") .. " (:w to submit) ",
    title_pos = "center",
  })
  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, util.split_lines(request.prefill or ""))
  vim.wo[window].wrap = true
  local finished = false
  local function done(value)
    if finished then
      return
    end
    finished = true
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
    if value == nil then
      respond(client, request, { cancelled = true })
    else
      respond(client, request, { value = value })
    end
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buffer,
    callback = function()
      done(table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"))
    end,
  })
  vim.keymap.set("n", "q", function() done(nil) end, { buffer = buffer, nowait = true })
  vim.keymap.set({ "n", "i" }, "<Esc>", function() done(nil) end, { buffer = buffer })
  vim.cmd("startinsert")
end

function M.handle(client, request, context)
  if request.type ~= "extension_ui_request" then
    return false
  end
  if request.method == "select" then
    vim.ui.select(request.options or {}, { prompt = request.title or "Select" }, function(choice)
      respond(client, request, choice == nil and { cancelled = true } or { value = choice })
    end)
  elseif request.method == "confirm" then
    local title = request.title or "Confirm"
    if request.message and request.message ~= "" then
      title = title .. ": " .. request.message
    end
    vim.ui.select({ "Yes", "No" }, { prompt = title }, function(choice)
      if choice == nil then
        respond(client, request, { cancelled = true })
      else
        respond(client, request, { confirmed = choice == "Yes" })
      end
    end)
  elseif request.method == "input" then
    vim.ui.input({ prompt = request.title or "Input", default = request.prefill }, function(value)
      respond(client, request, value == nil and { cancelled = true } or { value = value })
    end)
  elseif request.method == "editor" then
    editor(client, request)
  elseif request.method == "notify" then
    local levels = { info = vim.log.levels.INFO, warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
    util.notify(request.message or "", levels[request.notifyType] or vim.log.levels.INFO)
  elseif request.method == "setStatus" then
    if context and context.set_status then
      context.set_status(request.statusKey, request.statusText)
    end
  elseif request.method == "setWidget" then
    if context and context.window then
      context.window:set_widget(request.widgetKey, request.widgetLines)
    end
  elseif request.method == "set_editor_text" then
    if context and context.window then
      context.window:set_input(request.text or "")
    end
  elseif request.method == "setTitle" then
    return true
  else
    return false
  end
  return true
end

return M
