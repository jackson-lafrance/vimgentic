local report = require("vimgentic.ui.report")
local util = require("vimgentic.util")

local M = {}
local active = {}
local namespace = vim.api.nvim_create_namespace("vimgentic.tour")

local function buffer_mapping(buffer, key)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, "n")) do
    if mapping.lhs == key then return mapping end
  end
end

local function restore_keys(state)
  local bindings = state.bindings
  state.bindings = nil
  if not bindings or not vim.api.nvim_buf_is_valid(bindings.buffer) then return end
  for key, saved in pairs(bindings.keys) do
    local current = buffer_mapping(bindings.buffer, key)
    -- Do not replace a mapping the user changes during the tour.
    if current and current.callback == saved.callback then
      vim.keymap.del("n", key, { buffer = bindings.buffer })
      if saved.original then
        vim.api.nvim_buf_call(bindings.buffer, function()
          vim.fn.mapset("n", false, saved.original)
        end)
      end
    end
  end
end

local function clear_highlight(state)
  if state.mark and vim.api.nvim_buf_is_valid(state.buffer) then
    vim.api.nvim_buf_del_extmark(state.buffer, namespace, state.mark)
  end
  state.mark = nil
end

local function close(state, defer_windows)
  if state.closed then return end
  state.closed = true
  if active[state.tab] == state then active[state.tab] = nil end
  if state.group then vim.api.nvim_del_augroup_by_id(state.group) end
  restore_keys(state)
  clear_highlight(state)
  local function remove_panel()
    if state.panel_window and vim.api.nvim_win_is_valid(state.panel_window)
      and vim.api.nvim_win_get_buf(state.panel_window) == state.panel_buffer then
      local closed = pcall(vim.api.nvim_win_close, state.panel_window, true)
      if not closed then
        -- A user can close the source window and leave the panel as the last window.
        vim.api.nvim_win_set_buf(state.panel_window, vim.api.nvim_create_buf(true, false))
      end
    end
    if state.panel_buffer and vim.api.nvim_buf_is_valid(state.panel_buffer) then
      vim.api.nvim_buf_delete(state.panel_buffer, { force = true })
    end
  end
  -- Closing another window inside WinClosed can abort the user's :close.
  if defer_windows then vim.schedule(remove_panel) else remove_panel() end
end

local function install_keys(state)
  if state.bindings then return end
  state.bindings = { buffer = state.buffer, keys = {} }
  local actions = {
    ["<Right>"] = function() M.move(1) end,
    ["<Left>"] = function() M.move(-1) end,
    ["<Esc>"] = function() close(state) end,
  }
  for key, callback in pairs(actions) do
    state.bindings.keys[key] = { original = buffer_mapping(state.buffer, key), callback = callback }
    vim.keymap.set("n", key, callback, { buffer = state.buffer, nowait = true, silent = true, desc = "Vimgentic tour" })
  end
end

local function render(state)
  local result, position = state.result, state.position
  local location = result.locations[position]
  local lines = {
    string.format("# Tour · Step %d of %d", position, #result.locations), "",
    "← previous · next → · Esc: exit", "g?: overview · gq: quickfix · q: exit", "",
    util.truncate(result.prompt, 100), "",
  }
  if state.overview then
    table.insert(lines, "## Overview")
    table.insert(lines, "")
    vim.list_extend(lines, util.split_lines(result.report))
  else
    table.insert(lines, string.format("%s:%d-%d", util.relative_path(location.path, result.cwd), location.lnum, location.lnum + location.count - 1))
    table.insert(lines, "Source: " .. location.source .. "; current buffer")
    table.insert(lines, "")
    if state.warning then vim.list_extend(lines, { "> " .. state.warning, "" }) end
    if result.warning then vim.list_extend(lines, { "> " .. result.warning, "" }) end
    vim.list_extend(lines, util.split_lines(location.notes))
    if position == #result.locations then vim.list_extend(lines, { "", "End of tour. Press Esc to exit." }) end
  end
  util.set_buffer_lines(state.panel_buffer, 0, -1, lines)
  vim.api.nvim_win_set_cursor(state.panel_window, { 1, 0 })
end

local function show_stop(state, position)
  if position < 1 or position > #state.result.locations then
    util.notify(position < 1 and "Start of tour" or "End of tour")
    return false
  end
  state.updating = true
  restore_keys(state)
  local ok, location = pcall(report.jump, state.result, position, { window = state.source_window, notify = false })
  if not ok or not location then
    state.updating = false
    if not ok then util.notify(tostring(location), vim.log.levels.ERROR) end
    if state.buffer and vim.api.nvim_get_current_win() == state.source_window then install_keys(state) end
    return false
  end
  clear_highlight(state)
  state.source_window, state.buffer = location.window, location.buffer
  state.position, state.warning, state.overview = position, location.warning, false
  vim.api.nvim_set_hl(0, "VimgenticTourRange", { default = true, link = "Visual" })
  state.mark = vim.api.nvim_buf_set_extmark(state.buffer, namespace, location.first - 1, 0, {
    end_row = location.last, end_col = 0, hl_group = "VimgenticTourRange", hl_eol = true,
  })
  if state.panel_buffer then render(state) end
  install_keys(state)
  state.updating = false
  return true
end

local function watch(state)
  state.group = vim.api.nvim_create_augroup("vimgentic.tour." .. state.tab, { clear = true })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = state.group,
    callback = function()
      if state.updating or state.closed then return end
      state.updating = true
      restore_keys(state)
      state.updating = false
    end,
  })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = state.group,
    callback = function()
      if state.updating or state.closed then return end
      if vim.api.nvim_get_current_win() == state.source_window and vim.api.nvim_get_current_buf() == state.buffer then
        install_keys(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.group,
    callback = function(event)
      local window = tonumber(event.match)
      if window == state.source_window or window == state.panel_window then close(state, true) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    callback = function(event)
      if event.buf == state.buffer or event.buf == state.panel_buffer then close(state, true) end
    end,
  })
end

function M.open(result, position)
  local tab = vim.api.nvim_get_current_tabpage()
  local current = active[tab]
  if current and current.result == result then
    show_stop(current, position or current.position)
    return current.panel_buffer
  end
  if current then close(current) end
  if #result.locations == 0 then return report.open(result) end
  local window = vim.api.nvim_get_current_win()
  local source = vim.bo.buftype == "" and vim.api.nvim_win_get_config(window).relative == "" and window or nil
  local state = { tab = tab, result = result, source_window = source }
  if not show_stop(state, position or result.position or 1) then
    close(state)
    return
  end
  local ok, error_message = pcall(function()
    local buffer = vim.api.nvim_create_buf(false, true)
    state.panel_buffer = buffer
    vim.api.nvim_buf_set_name(buffer, "vimgentic://tour-player/" .. buffer)
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = "markdown"
    vim.bo[buffer].modifiable = false
    vim.cmd("botright vsplit")
    state.panel_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.panel_window, buffer)
    vim.api.nvim_win_set_width(state.panel_window, math.max(20, math.min(60, math.floor(vim.o.columns * 0.35))))
    vim.wo[state.panel_window].winfixwidth = true
    vim.wo[state.panel_window].wrap = true
    vim.wo[state.panel_window].linebreak = true
    vim.wo[state.panel_window].number = false
    vim.wo[state.panel_window].relativenumber = false
    vim.wo[state.panel_window].signcolumn = "no"
    vim.wo[state.panel_window].foldcolumn = "0"
    for _, key in ipairs({ "<Right>", "]t" }) do
      vim.keymap.set("n", key, function() M.move(1) end, { buffer = buffer, nowait = true })
    end
    for _, key in ipairs({ "<Left>", "[t" }) do
      vim.keymap.set("n", key, function() M.move(-1) end, { buffer = buffer, nowait = true })
    end
    for _, key in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", key, function() close(state) end, { buffer = buffer, nowait = true })
    end
    vim.keymap.set("n", "g?", function()
      state.overview = not state.overview
      render(state)
    end, { buffer = buffer })
    vim.keymap.set("n", "gq", function()
      close(state)
      report.quickfix(result)
    end, { buffer = buffer })
    render(state)
    active[tab] = state
    watch(state)
    vim.api.nvim_set_current_win(state.source_window)
  end)
  if not ok then
    close(state)
    util.notify(tostring(error_message), vim.log.levels.ERROR)
    return
  end
  return state.panel_buffer
end

function M.move(delta)
  local state = active[vim.api.nvim_get_current_tabpage()]
  if not state then return false end
  show_stop(state, state.position + delta)
  return true
end

function M.close()
  local state = active[vim.api.nvim_get_current_tabpage()]
  if state then close(state) end
end

return M
