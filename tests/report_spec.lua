local report = require("vimgentic.ui.report")
local qf = require("vimgentic.ui.qf")
local util = require("vimgentic.util")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  directory = assert(vim.uv.fs_realpath(directory))
  vim.fn.writefile({ "entry", "call()", "continue()", "done" }, directory .. "/z.lua")
  vim.fn.writefile({ "callee", "return total", "end" }, directory .. "/a.lua")
  local original_notify = util.notify
  local notices = {}
  util.notify = function(message) table.insert(notices, message) end
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.edit(vim.fn.fnameescape(directory .. "/z.lua"))
  local result = {
    kind = "tour", cwd = directory, prompt = "Trace the request", report = "# Request flow\nThree transitions",
    locations = {
      { path = directory .. "/z.lua", lnum = 2, col = 1, count = 1, notes = "Start with the caller", source = "working tree", anchor = "call()" },
      { path = directory .. "/a.lua", lnum = 2, col = 8, count = 1, notes = "Return the value\nThen finish", source = "working tree", anchor = "return total" },
      { path = directory .. "/z.lua", lnum = 4, col = 1, count = 1, notes = "Finish the request", source = "working tree", anchor = "done" },
    },
  }
  local ok, error_message = xpcall(function() callback(result, notices) end, debug.traceback)
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buffer):find(directory, 1, true) == 1 then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end
  util.notify = original_notify
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

describe("vimgentic.ui.report", function()
  it("opens a readonly report and follows stops in narrative order across files", function()
    fixture(function(result, notices)
      local editor = vim.api.nvim_get_current_win()
      local buffer = report.open(result)
      eq(false, vim.bo[buffer].modifiable)
      eq("markdown", vim.bo[buffer].filetype)
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      local body = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
      truthy(body:find("Return the value\nThen finish", 1, true))
      truthy(body:find("Jumps use current buffers", 1, true))
      report.move(result, 1)
      eq(editor, vim.api.nvim_get_current_win())
      eq(result.locations[1].path, vim.api.nvim_buf_get_name(0))
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
      report.move(result, 1)
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({ 2, 7 }, vim.api.nvim_win_get_cursor(0))
      report.move(result, 1)
      eq(result.locations[3].path, vim.api.nvim_buf_get_name(0))
      eq({ 4, 0 }, vim.api.nvim_win_get_cursor(0))
      report.move(result, -1)
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({}, notices)
    end)
  end)

  it("Enter jumps from an explanation section and leaves both report and source visible", function()
    fixture(function(result, notices)
      report.open(result)
      vim.fn.maparg("<CR>", "n", false, true).callback()
      eq({ "Place the cursor in a location section to jump" }, notices)
      vim.api.nvim_win_set_cursor(0, { result.rows[2] + 2, 0 })
      vim.fn.maparg("<CR>", "n", false, true).callback()
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({ 2, 7 }, vim.api.nvim_win_get_cursor(0))
      eq(2, result.position)
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
    end)
  end)

  it("closing and reopening a report preserves the stop without leaving stale mappings", function()
    fixture(function(result)
      report.move(result, 1)
      report.open(result)
      local old_buffer = result.buffer
      vim.fn.maparg("q", "n", false, true).callback()
      eq(false, vim.api.nvim_buf_is_valid(old_buffer))
      local buffer = report.open(result)
      truthy(buffer ~= old_buffer)
      eq({ result.rows[1], 0 }, vim.api.nvim_win_get_cursor(0))
      vim.fn.maparg("]t", "n", false, true).callback()
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
    end)
  end)

  it("stale coordinates warn and clamp without replacing unsaved source text", function()
    fixture(function(result, notices)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })
      result.locations[1].col = 500
      report.jump(result, 1)
      eq({ "edited" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      eq(true, vim.bo.modified)
      eq({ 1, 5 }, vim.api.nvim_win_get_cursor(0))
      eq({ "Location may be stale; check the current code against the report." }, notices)
      eq({ "entry", "call()", "continue()", "done" }, vim.fn.readfile(result.locations[1].path))
    end)
  end)

  it("a jump to another file retains unsaved edits in the original buffer", function()
    fixture(function(result)
      local original = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(original, 1, 2, false, { "unsaved_call()" })
      report.move(result, 1)
      report.move(result, 1)
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({ "entry", "unsaved_call()", "continue()", "done" }, vim.api.nvim_buf_get_lines(original, 0, -1, false))
      eq(true, vim.bo[original].modified)
      eq({ "entry", "call()", "continue()", "done" }, vim.fn.readfile(result.locations[1].path))
    end)
  end)

  it("index and revision jumps explicitly identify the live-buffer mismatch", function()
    fixture(function(result, notices)
      for _, source in ipairs({ "index", "revision" }) do
        result.locations[1].source = source
        report.jump(result, 1)
      end
      eq({
        "This location refers to index; the jump uses the current buffer, not that version.",
        "This location refers to revision; the jump uses the current buffer, not that version.",
      }, notices)
    end)
  end)

  it("missing files do not change focus or the current source buffer", function()
    fixture(function(result, notices)
      local editor, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      result.locations[1].path = result.cwd .. "/missing.lua"
      report.jump(result, 1)
      eq(editor, vim.api.nvim_get_current_win())
      eq(buffer, vim.api.nvim_get_current_buf())
      eq(nil, result.position)
      eq({ "Location is unavailable in the working tree: " .. result.locations[1].path }, notices)
    end)
  end)

  it("quickfix preserves tour order, provenance, and the last search list", function()
    fixture(function(result)
      qf.open({ { path = result.locations[1].path, lnum = 1, col = 1, count = 1, notes = "Search result" } }, "Search")
      local search = qf.last()
      report.quickfix(result)
      local items = vim.fn.getqflist()
      eq({ result.locations[1].path, result.locations[2].path, result.locations[3].path }, vim.tbl_map(function(item)
        return vim.api.nvim_buf_get_name(item.bufnr)
      end, items))
      truthy(items[2].text:find("[working tree; live-buffer jump]", 1, true))
      eq(search, qf.last())
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.fn.maparg("<CR>", "n", false, true).callback()
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({ 2, 7 }, vim.api.nvim_win_get_cursor(0))
      qf.reopen()
      eq("Search result", vim.fn.getqflist()[1].text)
    end)
  end)

  it("native quickfix history does not reuse another report's jump callback", function()
    fixture(function(result)
      qf.open({ { path = result.locations[2].path, lnum = 1, col = 1, count = 1, notes = "Earlier search" } }, "Search")
      report.quickfix(result)
      vim.cmd("colder")
      vim.fn.maparg("<CR>", "n", false, true).callback()
      eq(result.locations[2].path, vim.api.nvim_buf_get_name(0))
      eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    end)
  end)

  it("empty reports do not invent locations or replace quickfix", function()
    fixture(function(result, notices)
      result.locations = {}
      local before = vim.fn.getqflist()
      report.move(result, 1)
      report.quickfix(result)
      eq(before, vim.fn.getqflist())
      eq({ "This tour has no jump locations", "This tour has no jump locations" }, notices)
      report.open(result)
      eq(false, vim.bo.modifiable)
    end)
  end)

  it("navigation stops at the ends without wrapping or changing focus", function()
    fixture(function(result, notices)
      local editor = vim.api.nvim_get_current_win()
      report.move(result, -1)
      eq(editor, vim.api.nvim_get_current_win())
      report.jump(result, 3)
      report.move(result, 1)
      eq(3, result.position)
      eq({ "Start of locations", "End of locations" }, notices)
    end)
  end)
end)
