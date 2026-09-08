local oneshot = require("vimgentic.ops.oneshot")
local parse = require("vimgentic.parse")
local prompt_ui = require("vimgentic.ui.prompt")
local qf = require("vimgentic.ui.qf")
local status = require("vimgentic.ui.status")
local util = require("vimgentic.util")

local M = {}

local function agent_prompt(prompt, cwd)
  return table.concat({
    "Search the codebase for the user's request and return only matching source locations.",
    "Output one result per line as: path:lnum:col,count,notes",
    "Use an absolute path. lnum and col are one-based. count is the number of lines.",
    "Notes can contain commas. Do not add bullets or commentary.",
    "Search under the current working directory `" .. cwd .. "` first.",
    "Use rg with path filters and --max-count. Never list the whole repository.",
    "",
    "User request:",
    prompt,
  }, "\n")
end

local function run(prompt)
  local cwd = util.cwd()
  oneshot.run({
    kind = "search",
    user_prompt = prompt,
    prompt = agent_prompt(prompt, cwd),
    name = "search: " .. prompt,
    status = status.command(),
    on_result = function(text)
      local results = parse.parse(text)
      if #results == 0 then
        util.notify("vimgentic search returned no locations")
        return
      end
      qf.open(results, "vimgentic search: " .. util.truncate(prompt, 80))
    end,
  })
end

function M.search(options)
  options = options or {}
  if options.prompt and options.prompt ~= "" then
    run(options.prompt)
    return
  end
  prompt_ui.open({
    title = "Vimgentic search",
    prefill = options.prefill,
    on_submit = run,
  })
end

function M.reopen()
  qf.reopen()
end

return M
