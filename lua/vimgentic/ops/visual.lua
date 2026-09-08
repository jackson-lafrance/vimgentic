local oneshot = require("vimgentic.ops.oneshot")
local parse = require("vimgentic.parse")
local prompt_ui = require("vimgentic.ui.prompt")
local status = require("vimgentic.ui.status")
local util = require("vimgentic.util")

local M = {}

local function selected_range()
  local buffer = vim.api.nvim_get_current_buf()
  local first = vim.fn.getpos("'<")[2]
  local last = vim.fn.getpos("'>")[2]
  if first == 0 or last == 0 then
    first = vim.fn.line("v")
    last = vim.fn.line(".")
  end
  if first > last then
    first, last = last, first
  end
  return buffer, first, last
end

local function build_prompt(user_prompt, buffer, first, last)
  local path = vim.api.nvim_buf_get_name(buffer)
  local line_count = vim.api.nvim_buf_line_count(buffer)
  local context_start = math.max(0, first - 101)
  local context_end = math.min(line_count, last + 100)
  local selection = table.concat(vim.api.nvim_buf_get_lines(buffer, first - 1, last, false), "\n")
  local context = table.concat(vim.api.nvim_buf_get_lines(buffer, context_start, context_end, false), "\n")
  return table.concat({
    "Rewrite the selected code according to the user's request.",
    "You may use tools to inspect neighbouring files.",
    "Reply with only the replacement code. No fences, no commentary.",
    "",
    string.format("File: %s", path),
    string.format("Selected lines: %d-%d", first, last),
    "",
    "User request:",
    user_prompt,
    "",
    "Selection:",
    selection,
    "",
    string.format("Context (lines %d-%d):", context_start + 1, context_end),
    context,
  }, "\n")
end

function M.visual(options)
  options = options or {}
  local buffer, first, last = selected_range()
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buffer)
  local range_status = status.range(buffer, first, last)
  local function run(user_prompt)
    oneshot.run({
      kind = "visual",
      user_prompt = user_prompt,
      prompt = build_prompt(user_prompt, buffer, first, last),
      name = "visual: " .. user_prompt,
      status = range_status,
      metadata = { file = path, range = { first, last } },
      on_result = function(text)
        local replacement = parse.strip_code_fence(text)
        if replacement:match("^%s*$") then
          util.notify("vimgentic visual returned an empty replacement", vim.log.levels.WARN)
          return
        end
        local start_row, end_row = range_status:get_range()
        if not start_row or not end_row then
          util.notify("The selected range no longer exists; no text was replaced", vim.log.levels.ERROR)
          return
        end
        if end_row < start_row then
          util.notify("The selected range moved to an invalid position; no text was replaced", vim.log.levels.ERROR)
          return
        end
        vim.api.nvim_buf_set_lines(buffer, start_row, end_row, false, util.split_lines(replacement))
      end,
    })
  end
  if options.prompt and options.prompt ~= "" then
    run(options.prompt)
    return
  end
  prompt_ui.open({
    title = string.format("Vimgentic replace lines %d-%d", first, last),
    prefill = options.prefill,
    on_submit = run,
    on_cancel = function() range_status:stop() end,
  })
end

return M
