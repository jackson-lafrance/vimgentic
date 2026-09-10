local prompt_ui = require("vimgentic.ui.prompt")

describe("vimgentic.ui.prompt", function()
  it("cancels exactly once when the user closes the prompt window directly", function()
    local cancellations = 0
    local submissions = {}
    local prompt = prompt_ui.open({
      prefill = "Explain the selection",
      on_cancel = function() cancellations = cancellations + 1 end,
      on_submit = function(text) table.insert(submissions, text) end,
    })
    vim.api.nvim_win_close(prompt.window, true)
    eq(1, cancellations)
    prompt.close()
    eq(1, cancellations)
    eq({}, submissions)
    eq(false, vim.api.nvim_buf_is_valid(prompt.buffer))
  end)

  it("submits through :write without asking for a filesystem filename", function()
    local submissions = {}
    local prompt = prompt_ui.open({
      prefill = "Use total instead of price",
      on_submit = function(text) table.insert(submissions, text) end,
    })
    vim.cmd("stopinsert")
    vim.cmd("write")
    eq({ "Use total instead of price" }, submissions)
    eq(false, vim.api.nvim_buf_is_valid(prompt.buffer))
  end)

  it("submits the edited prompt without firing cancellation during buffer cleanup", function()
    local cancellations = 0
    local submissions = {}
    local prompt = prompt_ui.open({
      prefill = "Initial request",
      on_cancel = function() cancellations = cancellations + 1 end,
      on_submit = function(text) table.insert(submissions, text) end,
    })
    vim.api.nvim_buf_set_lines(prompt.buffer, 0, -1, false, { "Use total instead of price" })
    prompt.submit()
    prompt.close()
    eq({ "Use total instead of price" }, submissions)
    eq(0, cancellations)
    eq(false, vim.api.nvim_buf_is_valid(prompt.buffer))
  end)
end)
