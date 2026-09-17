local Terminal = require("vimgentic.chat.terminal").Terminal
local cli = require("vimgentic.pi.cli")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fixture(options)
  local starts = {}
  local exits = {}
  local stops = {}
  local sends = {}
  local next_job = 0
  local sidebar = Terminal.new(vim.tbl_extend("force", {
    cwd = "/tmp/project",
    current_cwd = function() return "/tmp/project" end,
    read_state = function(_, _, callback) callback() end,
    enter_insert = false,
    model = "provider/model",
    session_id = "session-id",
    schedule = function(callback) callback() end,
    start_job = function(buffer, command, cwd, on_exit, env)
      next_job = next_job + 1
      starts[next_job] = { buffer = buffer, command = command, cwd = cwd, env = env }
      exits[next_job] = on_exit
      return next_job
    end,
    stop_job = function(job_id)
      table.insert(stops, job_id)
      if not (options and options.defer_exit) then exits[job_id](0) end
    end,
    send = function(job_id, text)
      table.insert(sends, { job_id = job_id, text = text })
    end,
  }, options or {}))
  return sidebar, starts, stops, sends, exits
end

local function cleanup(sidebar)
  sidebar:shutdown()
  wait_for(function() return not sidebar.exiting end)
  sidebar:close()
  if sidebar.buffer and vim.api.nvim_buf_is_valid(sidebar.buffer) then
    vim.api.nvim_buf_delete(sidebar.buffer, { force = true })
  end
end

local function project_fixture(callback, options)
  local current_directory = "/tmp/project"
  local state = { choices = {}, notices = {} }
  local util = require("vimgentic.util")
  local original_select, original_notify = vim.ui.select, util.notify
  vim.ui.select = function(items, picker_options, on_choice)
    table.insert(state.choices, { items = items, options = picker_options, choose = on_choice })
  end
  util.notify = function(message) table.insert(state.notices, message) end
  local sidebar, starts, stops, sends, exits = fixture(vim.tbl_extend("force", {
    current_cwd = function() return current_directory end,
  }, options or {}))
  state.sidebar, state.starts, state.stops, state.sends, state.exits = sidebar, starts, stops, sends, exits
  state.chdir = function(directory) current_directory = directory end
  local ok, error_message = xpcall(function() callback(state) end, debug.traceback)
  cleanup(sidebar)
  vim.ui.select, util.notify = original_select, original_notify
  vim.fn.delete(sidebar.session_state)
  assert(ok, error_message)
end

describe("vimgentic.chat.terminal continuity", function()
  it("a project change does not stop Pi until the user confirms the switch", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.chdir("/tmp/other-project")
      truthy(state.sidebar:send_text("explain this file"))
      eq({}, state.stops)
      eq({}, state.sends)
      eq(1, #state.starts)
      eq({ "Switch project", "Keep current chat", "Cancel" }, state.choices[1].items)
      truthy(state.choices[1].options.prompt:find("unsent input is lost", 1, true))
      state.choices[1].choose("Switch project")
      eq({ 1 }, state.stops)
      eq(1, #state.starts)
      eq({}, state.sends)
      state.exits[1](0)
      eq("/tmp/other-project", state.starts[2].cwd)
      truthy(vim.tbl_contains(state.starts[2].command, "--session-id"))
      eq({ { job_id = 2, text = "\27[200~explain this file\27[201~" } }, state.sends)
    end, { defer_exit = true })
  end)

  it("cancelling a project switch leaves the process and its input untouched", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.chdir("/tmp/other-project")
      state.sidebar:send_text("do not send this")
      state.choices[1].choose(nil)
      eq({}, state.stops)
      eq({}, state.sends)
      eq(1, #state.starts)
      eq(1, state.sidebar.job_id)
    end)
  end)

  it("keeping the current chat sends the requested draft without a restart", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.chdir("/tmp/other-project")
      state.sidebar:send_text("inspect this context")
      state.choices[1].choose("Keep current chat")
      eq({}, state.stops)
      eq("/tmp/project", state.starts[1].cwd)
      eq({ { job_id = 1, text = "\27[200~inspect this context\27[201~" } }, state.sends)
    end)
  end)

  it("a directory change while the confirmation is open cancels the stale action", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.chdir("/tmp/other-project")
      state.sidebar:open()
      state.chdir("/tmp/third-project")
      state.choices[1].choose("Switch project")
      eq({}, state.stops)
      eq(1, #state.starts)
      eq({ "The editor directory changed; retry the chat action" }, state.notices)
    end)
  end)

  it("shutdown cancels an unanswered project confirmation", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.chdir("/tmp/other-project")
      state.sidebar:send_text("cancel this draft")
      state.sidebar:shutdown()
      state.choices[1].choose("Switch project")
      eq({ 1 }, state.stops)
      eq(1, #state.starts)
      eq({}, state.sends)
    end)
  end)

  it("selecting a history session starts it in the session's directory after the old process exits", function()
    project_fixture(function(state)
      state.sidebar:open()
      state.sidebar:switch_session("/tmp/other-session.jsonl", "/tmp/other-project")
      eq({ 1 }, state.stops)
      eq(1, #state.starts)
      state.exits[1](0)
      eq("/tmp/other-project", state.starts[2].cwd)
      truthy(vim.tbl_contains(state.starts[2].command, "/tmp/other-session.jsonl"))
      state.exits[1](1)
      eq(2, state.sidebar.job_id)
      eq({}, state.choices)
    end, { defer_exit = true })
  end)

  for _, action in ipairs({ "new", "fork", "resume" }) do
    it("reopening after native /" .. action .. " resumes the latest session rather than the startup session", function()
      project_fixture(function(state)
        state.sidebar:open()
        local path = "/tmp/" .. action .. "-session.jsonl"
        vim.fn.writefile({ vim.json.encode({
          token = state.starts[1].env.VIMGENTIC_SESSION_TOKEN,
          cwd = "/tmp/project", path = path, id = action .. "-id",
        }) }, state.sidebar.session_state)
        state.exits[1](0)
        wait_for(function() return not state.sidebar.exiting end)
        state.sidebar:open()
        wait_for(function() return #state.starts == 2 end)
        truthy(vim.tbl_contains(state.starts[2].command, path))
        eq(false, vim.tbl_contains(state.starts[2].command, "--session-id"))
        eq({}, state.choices)
      end, { read_state = require("vimgentic.chat.state").read })
    end)
  end

  it("a hidden live terminal reports native session changes without another chat action", function()
    local reports = {}
    project_fixture(function(state)
      state.sidebar:open()
      state.sidebar:close()
      local report = { token = "1", cwd = "/tmp/project", path = "/tmp/first-session.jsonl", id = "first-id" }
      vim.fn.writefile({ vim.json.encode(report) }, state.sidebar.session_state)
      wait_for(function() return #reports == 1 end, 2000)
      eq(report, reports[1])
      report = { token = "1", cwd = "/tmp/other-project", path = "/tmp/resumed-session.jsonl", id = "resumed-id" }
      vim.fn.writefile({ vim.json.encode(report) }, state.sidebar.session_state)
      wait_for(function() return #reports == 2 end, 2000)
      eq(report, reports[2])
      eq(nil, state.sidebar.window)
      eq({}, state.stops)
      eq(1, #state.starts)
      state.exits[1](0)
      wait_for(function() return not state.sidebar.exiting end)
      state.sidebar:open()
      wait_for(function() return #state.choices == 1 end)
      state.choices[1].choose("Keep current chat")
      eq("/tmp/other-project", state.starts[2].cwd)
      truthy(vim.tbl_contains(state.starts[2].command, "/tmp/resumed-session.jsonl"))
    end, {
      read_state = require("vimgentic.chat.state").read,
      on_session = function(report) table.insert(reports, report) end,
    })
  end)

  it("an exit during a state read cannot restart Pi before the final state arrives", function()
    local reads = {}
    project_fixture(function(state)
      state.sidebar:open()
      state.sidebar:open()
      eq(1, #reads)
      state.exits[1](0)
      eq(2, #reads)
      reads[1](nil, { cwd = "/tmp/project", path = "/tmp/earlier-session.jsonl", id = "earlier" })
      eq(1, #state.starts)
      eq({}, state.sends)
      reads[2](nil, { cwd = "/tmp/project", path = "/tmp/latest-session.jsonl", id = "latest" })
      state.sidebar:open()
      reads[3]()
      truthy(vim.tbl_contains(state.starts[2].command, "/tmp/latest-session.jsonl"))
      state.sidebar:shutdown()
      reads[4]()
    end, { read_state = function(_, _, callback) table.insert(reads, callback) end })
  end)

  it("an earlier process's state cannot overwrite an explicit history selection", function()
    project_fixture(function(state)
      state.sidebar:open()
      vim.fn.writefile({ vim.json.encode({
        token = "1", cwd = "/tmp/project", path = "/tmp/old-session.jsonl", id = "old-id",
      }) }, state.sidebar.session_state)
      state.sidebar:switch_session("/tmp/selected-session.jsonl", "/tmp/project")
      wait_for(function() return #state.starts == 2 end)
      state.exits[2](0)
      wait_for(function() return not state.sidebar.exiting end)
      state.sidebar:open()
      wait_for(function() return #state.starts == 3 end)
      truthy(vim.tbl_contains(state.starts[3].command, "/tmp/selected-session.jsonl"))
      eq(false, vim.tbl_contains(state.starts[3].command, "/tmp/old-session.jsonl"))
    end, { read_state = require("vimgentic.chat.state").read })
  end)
end)

describe("vimgentic.chat.terminal", function()
  it("builds an interactive pi command without RPC mode", function()
    eq({ "pi", "--tui-mode", "fullscreen", "--model", "provider/model", "--session", "/tmp/session.jsonl", "--extension", root .. "/pi/session-log.js" }, cli.interactive({
      model = "provider/model",
      session_path = "/tmp/session.jsonl",
    }))
  end)

  it("keeps the terminal job alive while the sidebar is hidden", function()
    local sidebar, starts = fixture()
    sidebar:open()
    eq(1, #starts)
    local job_id = sidebar.job_id
    sidebar:close()
    eq(job_id, sidebar.job_id)
    sidebar:open()
    eq(1, #starts)
    eq(job_id, sidebar.job_id)
    cleanup(sidebar)
  end)

  it("stops the old job before it opens a selected session", function()
    local sidebar, starts, stops = fixture()
    sidebar:open()
    sidebar:switch_session("/tmp/selected.jsonl")
    eq({ 1 }, stops)
    eq(2, #starts)
    eq({ "pi", "--tui-mode", "fullscreen", "--model", "provider/model", "--session", "/tmp/selected.jsonl", "--extension", root .. "/pi/session-log.js" }, starts[2].command)
    cleanup(sidebar)
  end)

  it("sends a selected chat model through pi's native command", function()
    local sidebar, _, _, sends = fixture()
    sidebar:open()
    sidebar:set_model("other/new-model")
    eq({ { job_id = 1, text = "/model other/new-model\r" } }, sends)
    cleanup(sidebar)
  end)

  it("restores editor focus without starting a new terminal job or sending a prompt", function()
    local sidebar, starts, _, sends = fixture()
    local editor_window = vim.api.nvim_get_current_win()
    sidebar:focus_flip()
    truthy(sidebar:is_sidebar(vim.api.nvim_get_current_win()))
    sidebar:focus_flip()
    eq(editor_window, vim.api.nvim_get_current_win())
    sidebar:focus_flip()
    eq(1, #starts)
    eq({}, sends)
    cleanup(sidebar)
  end)

  it("rejects control characters that could escape bracketed paste", function()
    local sidebar, starts, _, sends = fixture()
    eq(false, sidebar:send_text("code\27[201~\rsubmit this"))
    eq(false, sidebar:send_text("code\003"))
    eq({}, starts)
    eq({}, sends)
    cleanup(sidebar)
  end)

  it("maps only Escape in terminal mode so typing is never delayed", function()
    local sidebar = fixture()
    sidebar:open()
    local tmaps = vim.api.nvim_buf_get_keymap(sidebar.buffer, "t")
    eq(1, #tmaps)
    eq("<Esc>", tmaps[1].lhs)
    cleanup(sidebar)
  end)

  it("sends selections as bracketed paste and Ctrl-C as an abort", function()
    local sidebar, _, _, sends = fixture()
    sidebar:open()
    truthy(sidebar:send_text("one\ntwo"))
    sidebar:abort()
    eq({
      { job_id = 1, text = "\27[200~one\ntwo\27[201~" },
      { job_id = 1, text = "\003" },
    }, sends)
    cleanup(sidebar)
  end)

  it("passes the session log path to the pi process environment", function()
    local seen_env = nil
    local sidebar = Terminal.new({
      cwd = "/tmp/project",
      enter_insert = false,
      model = "provider/model",
      schedule = function(callback) callback() end,
      session_log = "/tmp/vimgentic-tests/session-log.jsonl",
      start_job = function(_, _, _, _, env)
        seen_env = env
        return 1
      end,
    })
    sidebar:open()
    eq({
      VIMGENTIC_SESSION_LOG = "/tmp/vimgentic-tests/session-log.jsonl",
      VIMGENTIC_SESSION_STATE = sidebar.session_state,
      VIMGENTIC_SESSION_TOKEN = "1",
    }, seen_env)
    cleanup(sidebar)
  end)
end)
