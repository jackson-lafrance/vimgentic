local vimgentic = require("vimgentic")
local oneshot = require("vimgentic.ops.oneshot")
local prompt_ui = require("vimgentic.ui.prompt")
local sessions = require("vimgentic.pi.sessions")
local util = require("vimgentic.util")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fixture(callback)
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  directory = assert(vim.uv.fs_realpath(directory))
  local path = directory .. "/code.lua"
  vim.fn.writefile({ "before", "return total", "after" }, path)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.edit(vim.fn.fnameescape(path))
  local buffer = vim.api.nvim_get_current_buf()
  local original_run, original_open = oneshot.run, prompt_ui.open
  local original_notify, original_cwd = util.notify, util.cwd
  local original_history = sessions.last_assistant
  local original_module = package.loaded["vimgentic.ops.background"]
  package.loaded["vimgentic.ops.background"] = nil
  local state = { cwd = directory, requests = {}, notices = {} }
  util.cwd = function() return state.cwd end
  util.notify = function(message) table.insert(state.notices, message) end
  oneshot.run = function(options) table.insert(state.requests, options) end
  prompt_ui.open = function(options) state.prompt = options end
  local ok, error_message = xpcall(function() callback(buffer, state) end, debug.traceback)
  for _, request in ipairs(state.requests) do request.status:stop() end
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  if vim.api.nvim_buf_is_valid(buffer) then vim.api.nvim_buf_delete(buffer, { force = true }) end
  oneshot.run, prompt_ui.open = original_run, original_open
  util.notify, util.cwd, sessions.last_assistant = original_notify, original_cwd, original_history
  package.loaded["vimgentic.ops.background"] = original_module
  vim.fn.delete(directory, "rf")
  assert(ok, error_message)
end

local function response(text, path)
  return vim.json.encode({ report = text, locations = path and {
    { path = path, lnum = 2, col = 1, count = 1, notes = "Explain the return", source = "working tree", anchor = "return total" },
  } or {} })
end

local function body(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer or 0, 0, -1, false), "\n")
end

describe("vimgentic background review and tour", function()
  it("review invokes the bundled skill with normal tools and never opens results on completion", function()
    fixture(function(buffer, state)
      local editor, quickfix = vim.api.nvim_get_current_win(), vim.fn.getqflist()
      vimgentic.review({ prompt = "Review code.lua for lifecycle races" })
      local request = state.requests[1]
      eq("review", request.kind)
      eq(nil, request.tools)
      eq(true, request.background)
      eq({ name = "review-local", path = root .. "/skills/review-local/SKILL.md" }, request.skill)
      truthy(request.prompt:find("/skill:review-local ", 1, true) == 1)
      truthy(request.prompt:find("Review code.lua for lifecycle races", 1, true))
      request.on_result(response("No actionable findings in the reviewed scope"))
      eq(editor, vim.api.nvim_get_current_win())
      eq(buffer, vim.api.nvim_get_current_buf())
      eq(quickfix, vim.fn.getqflist())
      truthy(state.notices[1]:find("Review ready (0 locations): :VimgenticReviewOpen", 1, true))
      vimgentic.review_open()
      truthy(body():find("No actionable findings in the reviewed scope", 1, true))
      eq(false, vim.bo.modifiable)
    end)
  end)

  it("tour requests an ordered explanation without invoking a review skill", function()
    fixture(function(buffer, state)
      vimgentic.tour({ prompt = "Trace the return flow in code.lua" })
      local request = state.requests[1]
      eq("tour", request.kind)
      eq(nil, request.skill)
      eq(nil, request.tools)
      truthy(request.prompt:find("not by filename", 1, true))
      truthy(request.prompt:find("full explanation", 1, true))
      local path = vim.api.nvim_buf_get_name(buffer)
      request.on_result(response("Tour overview", path))
      eq(buffer, vim.api.nvim_get_current_buf())
      vimgentic.tour_next()
      eq(path, vim.api.nvim_buf_get_name(0))
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
      local panel = vimgentic.tour_open()
      eq(buffer, vim.api.nvim_get_current_buf())
      truthy(body(panel):find("Step 1 of 1", 1, true))
      truthy(body(panel):find("Explain the return", 1, true))
    end)
  end)

  it("a newly completed tour does not replace the tour the user currently walks", function()
    fixture(function(buffer, state)
      local path = vim.api.nvim_buf_get_name(buffer)
      vimgentic.tour({ prompt = "First tour" })
      local first = vim.json.decode(response("First overview", path))
      first.locations[2] = { path = path, lnum = 3, col = 1, count = 1, notes = "Finish the first tour", source = "working tree", anchor = "after" }
      state.requests[1].on_result(vim.json.encode(first))
      local panel = vimgentic.tour_open()
      vimgentic.tour({ prompt = "Second tour" })
      state.requests[2].on_result(response("Second overview", path))
      eq(buffer, vim.api.nvim_get_current_buf())
      vimgentic.tour_next()
      eq({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
      truthy(body(panel):find("Finish the first tour", 1, true))
      vimgentic.tour_prev()
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
      local next_panel = vimgentic.tour_open()
      eq(false, vim.api.nvim_buf_is_valid(panel))
      truthy(body(next_panel):find("Second tour", 1, true))
      truthy(body(next_panel):find("Step 1 of 1", 1, true))
    end)
  end)

  it("restoring a tour from another project's history enters the player and the close command exits it", function()
    fixture(function(buffer)
      local path = vim.api.nvim_buf_get_name(buffer)
      sessions.last_assistant = function(_, callback) callback(nil, response("Saved tour", path)) end
      require("vimgentic.ops.background").from_history({ kind = "tour", cwd = "/original/project", path = "/tour.jsonl", prompt = "Saved request" })
      eq(buffer, vim.api.nvim_get_current_buf())
      eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
      eq("Vimgentic tour", vim.fn.maparg("<Right>", "n", false, true).desc)
      dofile(root .. "/plugin/vimgentic.lua")
      vim.cmd("VimgenticTourClose")
      eq(nil, vim.fn.maparg("<Right>", "n", false, true).desc)
    end)
  end)

  it("prompt submission uses the original project and selection despite later edits and directory changes", function()
    fixture(function(buffer, state)
      local original_cwd = state.cwd
      vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "return unsaved" })
      vimgentic.review({ first = 2, last = 2 })
      eq({}, state.requests)
      vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "return changed_again" })
      state.cwd = "/different/project"
      state.prompt.on_submit("Review this selection")
      local request = state.requests[1]
      eq(original_cwd, request.cwd)
      truthy(request.prompt:find("return unsaved", 1, true))
      truthy(request.prompt:find("live buffer with unsaved changes", 1, true))
      eq(nil, request.prompt:find("return changed_again", 1, true))
      request.on_result(response("Selection review"))
      vimgentic.review_open()
      eq(buffer, vim.api.nvim_get_current_buf())
      eq("No completed review for this project; use :VimgenticHistory for older results", state.notices[2])
      state.cwd = original_cwd
      vimgentic.review_open()
      truthy(body():find("Selection review", 1, true))
    end)
  end)

  it("normal review labels unsaved buffers as unavailable instead of claiming a snapshot", function()
    fixture(function(buffer, state)
      vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "unsaved content" })
      vimgentic.review({ prompt = "Review this file" })
      local request = state.requests[1]
      truthy(request.prompt:find(vim.api.nvim_buf_get_name(buffer), 1, true))
      truthy(request.prompt:find("no buffer text is supplied", 1, true))
      eq(nil, request.prompt:find("unsaved content", 1, true))
    end)
  end)

  it("command ranges capture explicit source lines for both operation kinds", function()
    fixture(function(buffer, state)
      dofile(root .. "/plugin/vimgentic.lua")
      vim.api.nvim_buf_set_mark(buffer, "<", 1, 0, {})
      vim.api.nvim_buf_set_mark(buffer, ">", 1, 0, {})
      vim.cmd("2,3VimgenticReview Check the selection")
      vim.cmd("2,2VimgenticTour Explain this return")
      eq("review", state.requests[1].kind)
      truthy(state.requests[1].prompt:find("Lines: 2-3", 1, true))
      eq("tour", state.requests[2].kind)
      truthy(state.requests[2].prompt:find("Lines: 2-2", 1, true))
    end)
  end)

  it("a source selection in a scratch buffer is rejected before a request starts", function()
    fixture(function(buffer, state)
      vim.bo[buffer].buftype = "nofile"
      vimgentic.review({ first = 1, last = 1, prompt = "Review this" })
      eq({}, state.requests)
      eq({ "Vimgentic needs a source buffer" }, state.notices)
    end)
  end)

  it("an unstructured answer stays readable and does not overwrite an already open report", function()
    fixture(function(_, state)
      vimgentic.review({ prompt = "Review code.lua" })
      state.requests[1].on_result(response("First report"))
      local first = vimgentic.review_open()
      vimgentic.review({ prompt = "Review code.lua again" })
      state.requests[2].on_result("Review needs scope: which revision?")
      eq(first, vim.api.nvim_get_current_buf())
      truthy(body(first):find("First report", 1, true))
      vimgentic.review_open()
      truthy(body():find("Review needs scope: which revision?", 1, true))
      truthy(body():find("jump locations are unavailable", 1, true))
    end)
  end)

  it("restoring history uses its recorded project and retains the full report", function()
    fixture(function(_, state)
      local before = state.cwd
      local entry = { kind = "review", cwd = "/original/project", path = "/session.jsonl", prompt = "Review the original code" }
      local requested_path
      sessions.last_assistant = function(path, callback)
        requested_path = path
        callback(nil, response("Historical evidence and confidence"))
      end
      require("vimgentic.ops.background").from_history(entry)
      eq(entry.path, requested_path)
      truthy(body():find("Project: /original/project", 1, true))
      truthy(body():find("Historical evidence and confidence", 1, true))
      eq(before, state.cwd)
    end)
  end)

  it("a delayed history read cannot replace a newer report choice", function()
    fixture(function(_, state)
      local pending = {}
      sessions.last_assistant = function(path, callback) pending[path] = callback end
      local background = require("vimgentic.ops.background")
      background.from_history({ kind = "review", cwd = state.cwd, path = "/older.jsonl" })
      background.from_history({ kind = "tour", cwd = state.cwd, path = "/newer.jsonl" })
      pending["/newer.jsonl"](nil, response("Newer choice"))
      local chosen = vim.api.nvim_get_current_buf()
      pending["/older.jsonl"](nil, response("Older choice"))
      eq(chosen, vim.api.nvim_get_current_buf())
      truthy(body():find("Newer choice", 1, true))
      eq(nil, body():find("Older choice", 1, true))
    end)
  end)

  it("opening the latest result cancels a pending history read", function()
    fixture(function(_, state)
      vimgentic.review({ prompt = "Review code.lua" })
      state.requests[1].on_result(response("Latest result"))
      local pending
      sessions.last_assistant = function(_, callback) pending = callback end
      require("vimgentic.ops.background").from_history({ kind = "review", cwd = state.cwd, path = "/older.jsonl" })
      local chosen = vimgentic.review_open()
      pending(nil, response("Older result"))
      eq(chosen, vim.api.nvim_get_current_buf())
      truthy(body():find("Latest result", 1, true))
    end)
  end)

  it("history read errors leave the editor untouched", function()
    fixture(function(buffer, state)
      sessions.last_assistant = function(_, callback) callback("session is unavailable") end
      require("vimgentic.ops.background").from_history({ kind = "tour", path = "/gone.jsonl" })
      eq(buffer, vim.api.nvim_get_current_buf())
      eq({ "session is unavailable" }, state.notices)
    end)
  end)
end)
