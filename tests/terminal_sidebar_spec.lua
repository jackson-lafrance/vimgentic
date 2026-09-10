local Terminal = require("vimgentic.chat.terminal").Terminal
local cli = require("vimgentic.pi.cli")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local function fixture()
  local starts = {}
  local exits = {}
  local stops = {}
  local sends = {}
  local next_job = 0
  local sidebar = Terminal.new({
    cwd = "/tmp/project",
    enter_insert = false,
    model = "provider/model",
    session_id = "session-id",
    schedule = function(callback) callback() end,
    start_job = function(buffer, command, cwd, on_exit)
      next_job = next_job + 1
      starts[next_job] = { buffer = buffer, command = command, cwd = cwd }
      exits[next_job] = on_exit
      return next_job
    end,
    stop_job = function(job_id)
      table.insert(stops, job_id)
      exits[job_id](0)
    end,
    send = function(job_id, text)
      table.insert(sends, { job_id = job_id, text = text })
    end,
  })
  return sidebar, starts, stops, sends
end

local function cleanup(sidebar)
  sidebar:shutdown()
  sidebar:close()
  if sidebar.buffer and vim.api.nvim_buf_is_valid(sidebar.buffer) then
    vim.api.nvim_buf_delete(sidebar.buffer, { force = true })
  end
end

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
    eq({ VIMGENTIC_SESSION_LOG = "/tmp/vimgentic-tests/session-log.jsonl" }, seen_env)
    cleanup(sidebar)
  end)
end)
