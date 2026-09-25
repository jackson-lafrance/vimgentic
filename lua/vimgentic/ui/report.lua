local qf = require("vimgentic.ui.qf")
local util = require("vimgentic.util")

local M = {}

local function source_window()
  local best, area = nil, 0
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buffer = vim.api.nvim_win_get_buf(window)
    local floating = vim.api.nvim_win_get_config(window).relative ~= ""
    local size = vim.api.nvim_win_get_width(window) * vim.api.nvim_win_get_height(window)
    if not floating and vim.bo[buffer].buftype == "" and size > area then
      best, area = window, size
    end
  end
  return best
end

local function target_window(window)
  local target = window or source_window()
  if not target then
    vim.cmd("aboveleft vnew")
    target = vim.api.nvim_get_current_win()
  end
  return target
end

local function visible_window(result)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(window) == result.buffer then return window end
  end
end

function M.jump(result, position, options)
  options = options or {}
  local location = result.locations[position]
  if not location then
    util.notify("No location at this position")
    return
  end
  local function unavailable(message)
    if options.notify ~= false then util.notify(message, vim.log.levels.WARN) end
    if not options.allow_missing then return end
    local target = target_window(options.window)
    vim.api.nvim_set_current_win(target)
    result.position = position
    return {
      window = target, buffer = vim.api.nvim_win_get_buf(target), unavailable = true,
      warning = message .. " The source pane is unchanged; continue to the next stop.",
    }
  end
  local buffer = vim.fn.bufnr(location.path)
  if buffer < 0 or not vim.api.nvim_buf_is_loaded(buffer) then
    local stat = vim.uv.fs_stat(location.path)
    if not stat or stat.type ~= "file" then
      return unavailable("Location is unavailable in the working tree: " .. location.path)
    end
    buffer = vim.fn.bufadd(location.path)
    local loaded, load_error = pcall(vim.fn.bufload, buffer)
    if not loaded then
      return unavailable(tostring(load_error))
    end
  end
  local row = math.min(location.lnum, vim.api.nvim_buf_line_count(buffer))
  local line = vim.api.nvim_buf_get_lines(buffer, row - 1, row, false)[1] or ""
  local warning
  if location.source == "index" or location.source == "revision" then
    warning = "This location refers to " .. location.source .. "; the jump uses the current buffer, not that version."
  elseif row ~= location.lnum or not location.anchor or line ~= location.anchor then
    warning = "Location may be stale; check the current code against the report."
  end
  if warning and options.notify ~= false then util.notify(warning, vim.log.levels.WARN) end
  local target = target_window(options.window)
  local changed, change_error = pcall(vim.api.nvim_win_set_buf, target, buffer)
  if not changed then
    util.notify(tostring(change_error), vim.log.levels.ERROR)
    return
  end
  local column = math.min(location.col - 1, math.max(0, #line - 1))
  vim.api.nvim_set_current_win(target)
  vim.api.nvim_win_set_cursor(target, { row, column })
  vim.cmd("normal! zvzz")
  result.position = position
  local report_window = visible_window(result)
  if report_window and result.rows then
    vim.api.nvim_win_set_cursor(report_window, { result.rows[position], 0 })
  end
  return {
    window = target, buffer = buffer, first = row,
    last = math.min(location.lnum + location.count - 1, vim.api.nvim_buf_line_count(buffer)),
    warning = warning,
  }
end

function M.move(result, delta)
  if #result.locations == 0 then
    util.notify("This " .. result.kind .. " has no jump locations")
    return
  end
  local position = (result.position or 0) + delta
  if position < 1 or position > #result.locations then
    util.notify(delta > 0 and "End of locations" or "Start of locations")
    return
  end
  M.open(result)
  M.jump(result, position)
end

function M.quickfix(result)
  if #result.locations == 0 then
    util.notify("This " .. result.kind .. " has no jump locations")
    return
  end
  local locations = vim.deepcopy(result.locations)
  for _, location in ipairs(locations) do
    location.notes = "[" .. location.source .. "; live-buffer jump] " .. util.truncate(location.notes, 240)
  end
  qf.open(locations, "vimgentic " .. result.kind .. ": " .. util.truncate(result.prompt, 80), {
    remember = false,
    on_jump = function(position) M.jump(result, position) end,
  })
end

function M.open(result)
  local window = visible_window(result)
  if window then
    vim.api.nvim_set_current_win(window)
    return result.buffer
  end
  if not result.buffer or not vim.api.nvim_buf_is_valid(result.buffer) then
    local buffer = vim.api.nvim_create_buf(false, true)
    result.buffer = buffer
    vim.api.nvim_buf_set_name(buffer, "vimgentic://" .. result.kind .. "/" .. buffer)
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "markdown"
    local lines = {
      "# Vimgentic " .. result.kind, "", "Project: " .. result.cwd,
      "Request: " .. util.truncate(result.prompt, 200), "",
      "<CR>: jump from a location | ]t / [t: next / previous | gq: quickfix | q: close",
      "Jumps use current buffers. Reported versions and line numbers can differ from the current code.", "",
    }
    if result.warning then vim.list_extend(lines, { result.warning, "" }) end
    vim.list_extend(lines, util.split_lines(result.report))
    vim.list_extend(lines, { "", "## Locations", "" })
    result.rows = {}
    for position, location in ipairs(result.locations) do
      result.rows[position] = #lines + 1
      table.insert(lines, string.format("### %d. %s:%d:%d (%s)", position, location.path, location.lnum, location.col, location.source))
      table.insert(lines, "")
      vim.list_extend(lines, util.split_lines(location.notes))
      table.insert(lines, "")
    end
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      for position = #result.rows, 1, -1 do
        if row >= result.rows[position] then
          M.jump(result, position)
          return
        end
      end
      util.notify("Place the cursor in a location section to jump")
    end, { buffer = buffer, nowait = true })
    vim.keymap.set("n", "]t", function() M.move(result, 1) end, { buffer = buffer })
    vim.keymap.set("n", "[t", function() M.move(result, -1) end, { buffer = buffer })
    vim.keymap.set("n", "gq", function() M.quickfix(result) end, { buffer = buffer })
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(0, true) end, { buffer = buffer, nowait = true })
  end
  vim.cmd("botright vsplit")
  window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, result.buffer)
  vim.wo[window].wrap = true
  vim.wo[window].linebreak = true
  if result.position and result.rows[result.position] then
    vim.api.nvim_win_set_cursor(window, { result.rows[result.position], 0 })
  end
  return result.buffer
end

return M
