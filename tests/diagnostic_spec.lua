local vimgentic = require("vimgentic")
local chat = require("vimgentic.ops.chat")
local util = require("vimgentic.util")
local namespace = vim.api.nvim_create_namespace("vimgentic.tests.diagnostic")

local function fixture(callback)
  local original_select, original_draft, original_notify = vim.ui.select, chat.draft, util.notify
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_name(buffer, "/tmp/project/diagnostic-example.lua")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local total = nil", "return total + price", "-- done" })
  vim.api.nvim_win_set_cursor(0, { 2, 8 })
  local state = { drafts = {}, notices = {} }
  vim.ui.select = function(items, options, on_choice)
    state.items, state.options, state.choose = items, options, on_choice
  end
  chat.draft = function(text) table.insert(state.drafts, text) end
  util.notify = function(message) table.insert(state.notices, message) end
  state.diagnostics = function(diagnostics)
    vim.diagnostic.set(namespace, buffer, diagnostics, { virtual_text = false, signs = false, underline = false })
  end
  local ok, error_message = xpcall(function() callback(buffer, state) end, debug.traceback)
  vim.diagnostic.reset(namespace, buffer)
  vim.ui.select, chat.draft, util.notify = original_select, original_draft, original_notify
  vim.api.nvim_buf_delete(buffer, { force = true })
  assert(ok, error_message)
end

local function diagnostic(options)
  return vim.tbl_extend("force", {
    lnum = 1, col = 7, end_lnum = 1, end_col = 12,
    message = "Cannot add nil and number", source = "lua-language-server", code = "type-error",
    severity = vim.diagnostic.severity.ERROR,
  }, options or {})
end

describe("vimgentic.explain_error", function()
  it("a diagnostic at the cursor creates an explanation-only draft with its verbatim message and unsaved code", function()
    fixture(function(buffer, state)
      local message = "Cannot add nil and number\nExpected a number, got nil."
      state.diagnostics({ diagnostic({ message = message, code = 1234 }) })
      vimgentic.explain_error()
      eq(1, #state.drafts)
      local draft = state.drafts[1]
      truthy(draft:find(message, 1, true))
      truthy(draft:find("Severity: ERROR", 1, true))
      truthy(draft:find("Source: lua-language-server", 1, true))
      truthy(draft:find("Code: 1234", 1, true))
      truthy(draft:find("Diagnostic range: 2:8-2:13", 1, true))
      truthy(draft:find("/tmp/project/diagnostic-example.lua", 1, true))
      truthy(draft:find("return total + price", 1, true))
      truthy(draft:find("live buffer with unsaved changes", 1, true))
      truthy(draft:find("Do not edit files, generate replacement code, or implement a fix.", 1, true))
      eq(nil, state.items)
      eq({ "local total = nil", "return total + price", "-- done" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    end)
  end)

  it("the diagnostic under the cursor takes precedence over another diagnostic on the same line", function()
    fixture(function(_, state)
      state.diagnostics({
        diagnostic({ col = 0, end_col = 4, message = "Different error" }),
        diagnostic({ message = "Warning at the cursor", severity = vim.diagnostic.severity.WARN }),
      })
      vimgentic.explain_error()
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("Warning at the cursor", 1, true))
      eq(nil, state.drafts[1]:find("Different error", 1, true))
      eq(nil, state.items)
    end)
  end)

  it("a cursor outside the highlighted range uses the diagnostic on its line", function()
    fixture(function(_, state)
      state.diagnostics({ diagnostic() })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vimgentic.explain_error()
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("Cannot add nil and number", 1, true))
      truthy(state.drafts[1]:find("Editor cursor: 2:1", 1, true))
    end)
  end)

  it("overlapping diagnostics offer a choice and preserve the original message and source snapshot", function()
    fixture(function(buffer, state)
      state.diagnostics({
        diagnostic({ message = "A warning", severity = vim.diagnostic.severity.WARN }),
        diagnostic({ message = "An error" }),
      })
      vimgentic.explain_error()
      eq({}, state.drafts)
      eq("Explain diagnostic", state.options.prompt)
      eq("An error", state.items[1].message)
      eq("A warning", state.items[2].message)
      truthy(state.options.format_item(state.items[1]):find("[ERROR] lua-language-server type-error: An error", 1, true))
      vim.api.nvim_buf_set_lines(buffer, 1, 2, false, { "return changed_code" })
      vim.diagnostic.reset(namespace, buffer)
      state.choose(state.items[1])
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("An error", 1, true))
      truthy(state.drafts[1]:find("return total + price", 1, true))
      eq(nil, state.drafts[1]:find("return changed_code", 1, true))
    end)
  end)

  it("cancelling a diagnostic choice does not send a draft or change the source", function()
    fixture(function(buffer, state)
      state.diagnostics({ diagnostic(), diagnostic({ message = "Another diagnostic" }) })
      vimgentic.explain_error()
      state.choose(nil)
      eq({}, state.drafts)
      eq({}, state.notices)
      eq({ "local total = nil", "return total + price", "-- done" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
    end)
  end)

  it("a multiline diagnostic includes a cursor inside its range", function()
    fixture(function(_, state)
      state.diagnostics({ diagnostic({ lnum = 0, col = 0, end_lnum = 2, end_col = 0 }) })
      vimgentic.explain_error()
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("Diagnostic range: 1:1-3:1", 1, true))
    end)
  end)

  it("the exclusive final line of a multiline diagnostic does not match the cursor", function()
    fixture(function(_, state)
      state.diagnostics({ diagnostic({ lnum = 0, col = 0, end_lnum = 2, end_col = 0 }) })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vimgentic.explain_error()
      eq({}, state.drafts)
      eq({ "No diagnostic at the cursor or on this line" }, state.notices)
    end)
  end)

  it("a zero-width diagnostic matches its exact cursor position", function()
    fixture(function(_, state)
      state.diagnostics({ diagnostic({ col = 8, end_col = 8 }) })
      vimgentic.explain_error()
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("Diagnostic range: 2:9-2:9", 1, true))
    end)
  end)

  it("a buffer without diagnostics does not open chat", function()
    fixture(function(_, state)
      vimgentic.explain_error()
      eq({}, state.drafts)
      eq({ "No diagnostic at the cursor or on this line" }, state.notices)
    end)
  end)

  it("a scratch buffer is rejected before a diagnostic draft is created", function()
    fixture(function(buffer, state)
      vim.bo[buffer].buftype = "nofile"
      vimgentic.explain_error()
      eq({}, state.drafts)
      eq({ "Vimgentic needs a source buffer" }, state.notices)
    end)
  end)

  it("the user command drafts the current diagnostic", function()
    fixture(function(_, state)
      state.diagnostics({ diagnostic() })
      local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
      dofile(root .. "/plugin/vimgentic.lua")
      vim.cmd("VimgenticExplainError")
      eq(1, #state.drafts)
      truthy(state.drafts[1]:find("Cannot add nil and number", 1, true))
    end)
  end)
end)
