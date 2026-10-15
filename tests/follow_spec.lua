local Follow = require("vimgentic.chat.follow").Follow
local config = require("vimgentic.config")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  directory = assert(vim.uv.fs_realpath(directory))
  local original_window = vim.api.nvim_get_current_win()
  vim.cmd("new")
  local editor = vim.api.nvim_get_current_win()
  local original_buffer = vim.api.nvim_get_current_buf()
  local first, second = directory .. "/first.lua", directory .. "/second.lua"
  vim.fn.writefile({ "first", "second", "third" }, first)
  vim.fn.writefile({ "other" }, second)
  vim.cmd("vnew")
  local chat_window = vim.api.nvim_get_current_win()
  local chat_buffer = vim.api.nvim_get_current_buf()
  local control_path, request_path = directory .. "/control.json", directory .. "/request.json"
  local follow = Follow.new({
    enabled = false,
    control_path = control_path,
    request_path = request_path,
    editor_window = function() return editor end,
  })
  local function state() return vim.json.decode(table.concat(vim.fn.readfile(control_path), "\n")) end
  local serial = 0
  local function request(values)
    serial = serial + 1
    local value = vim.tbl_extend("force", { token = state().token, id = tostring(serial), path = first, line = 2 }, values or {})
    vim.fn.writefile({ vim.json.encode(value) }, request_path .. ".tmp")
    assert(vim.uv.fs_rename(request_path .. ".tmp", request_path))
  end
  local function settle() vim.wait(250, function() return false end, 10) end
  local ok, error_message = xpcall(function()
    callback({
      follow = follow, editor = editor, chat_window = chat_window, original_buffer = original_buffer,
      first = first, second = second, state = state, request = request, settle = settle,
      control_path = control_path, request_path = request_path,
      name = function() return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor)) end,
    })
  end, debug.traceback)
  follow:stop()
  for _, window in ipairs({ chat_window, editor }) do
    if vim.api.nvim_win_is_valid(window) then vim.api.nvim_win_close(window, true) end
  end
  if vim.api.nvim_win_is_valid(original_window) then vim.api.nvim_set_current_win(original_window) end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buffer)
    if name:sub(1, #directory) == directory or buffer == original_buffer or buffer == chat_buffer then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.chat.follow", function()
  it("defaults to off and rejects a non-boolean startup setting", function()
    eq(false, config.defaults().chat.follow)
    eq(true, config.setup({ chat = { follow = true } }).chat.follow)
    local ok, error_message = pcall(config.setup, { chat = { follow = "yes" } })
    config.setup()
    eq(false, ok)
    truthy(error_message:find("vimgentic: chat.follow must be a boolean", 1, true))
  end)

  it("an explicit request changes the adjacent file and line without taking focus", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      eq(false, state.state().enabled)
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      eq(true, state.follow:toggle())
      eq(true, state.state().enabled)
      state.request()
      wait_for(function() return state.name() == state.first end)
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(state.editor))
      eq(state.chat_window, vim.api.nvim_get_current_win())
      state.request({ path = state.second, line = 999 })
      wait_for(function() return state.name() == state.second end)
      eq({ 1, 0 }, vim.api.nvim_win_get_cursor(state.editor))
      eq(state.chat_window, vim.api.nvim_get_current_win())
    end)
  end)

  it("a toggle before startup applies when the terminal starts", function()
    fixture(function(state)
      state.follow:toggle()
      eq(nil, vim.uv.fs_stat(state.control_path))
      state.follow:set_visible(true)
      state.follow:start()
      eq(true, state.state().enabled)
      eq(384, bit.band(vim.uv.fs_stat(state.control_path).mode, 511))
      state.request()
      wait_for(function() return state.name() == state.first end)
    end)
  end)

  it("off-on toggles and hidden sidebars reject stale requests rather than replaying them", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      local old_token = state.state().token
      state.follow:toggle()
      state.follow:toggle()
      state.request({ token = old_token })
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      state.follow:set_visible(false)
      eq(false, state.state().enabled)
      local hidden_token = state.state().token
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      state.follow:set_visible(true)
      eq(true, state.state().enabled)
      state.request({ token = hidden_token })
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      state.request()
      wait_for(function() return state.name() == state.first end)
    end)
  end)

  it("unsaved edits in the current editor prevent navigation and preserve its text", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      vim.api.nvim_buf_set_lines(state.original_buffer, 0, -1, false, { "unsaved work" })
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      eq({ "unsaved work" }, vim.api.nvim_buf_get_lines(state.original_buffer, 0, -1, false))
      eq(true, vim.bo[state.original_buffer].modified)
    end)
  end)

  it("an unsaved target buffer stays untouched and the editor does not switch to it", function()
    fixture(function(state)
      local target = vim.fn.bufadd(state.first)
      vim.fn.bufload(target)
      vim.api.nvim_buf_set_lines(target, 0, -1, false, { "local changes" })
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      eq({ "local changes" }, vim.api.nvim_buf_get_lines(target, 0, -1, false))
    end)
  end)

  it("a shown unmodified buffer reloads Pi's disk edits without changing its autoread setting", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      state.request()
      wait_for(function() return state.name() == state.first end)
      local buffer = vim.api.nvim_win_get_buf(state.editor)
      vim.bo[buffer].autoread = false
      vim.fn.writefile({ "updated by Pi", "another line", "last line", "new line" }, state.first)
      state.request({ line = 4 })
      wait_for(function() return vim.api.nvim_win_get_cursor(state.editor)[1] == 4 end)
      eq({ "updated by Pi", "another line", "last line", "new line" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      eq(false, vim.bo[buffer].autoread)
      eq(false, vim.bo[buffer].modified)
      eq(state.chat_window, vim.api.nvim_get_current_win())
    end)
  end)

  it("special buffers and windows in another tab stay untouched", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      vim.bo[state.original_buffer].buftype = "nofile"
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      vim.bo[state.original_buffer].buftype = ""
      vim.cmd("tabnew")
      state.request()
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      vim.cmd("tabclose")
      state.request()
      wait_for(function() return state.name() == state.first end)
    end)
  end)

  it("malformed, relative, missing, and non-file requests leave the editor untouched", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      for _, contents in ipairs({ "{broken", "null", string.rep("x", 65537) }) do
        vim.fn.writefile({ contents }, state.request_path)
        state.settle()
        eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      end
      for _, request in ipairs({
        { path = "relative.lua" }, { path = "/missing/vimgentic-file" }, { path = vim.fs.dirname(state.first) },
        { path = "bad\npath" }, { line = -1 }, { line = 1.5 }, { line = "2" }, { token = false }, { id = false },
      }) do
        state.request(request)
        state.settle()
        eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      end
      state.request()
      wait_for(function() return state.name() == state.first end)
    end)
  end)

  it("a repeated request never moves the cursor back after the user scrolls", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      state.request({ id = "same-choice" })
      wait_for(function() return state.name() == state.first end)
      vim.api.nvim_win_set_cursor(state.editor, { 3, 0 })
      state.request({ id = "same-choice", line = 1 })
      state.settle()
      eq({ 3, 0 }, vim.api.nvim_win_get_cursor(state.editor))
    end)
  end)

  it("stopping removes the bridge and restarting rejects requests from the earlier process", function()
    fixture(function(state)
      state.follow:start()
      state.follow:set_visible(true)
      state.follow:toggle()
      local token = state.state().token
      state.follow:stop()
      state.follow:stop()
      eq(nil, vim.uv.fs_stat(state.control_path))
      eq(nil, vim.uv.fs_stat(state.request_path))
      state.follow:start()
      state.request({ token = token })
      state.settle()
      eq(state.original_buffer, vim.api.nvim_win_get_buf(state.editor))
      state.request()
      wait_for(function() return state.name() == state.first end)
    end)
  end)
end)
