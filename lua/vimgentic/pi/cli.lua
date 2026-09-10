local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

local function add_options(command, options)
  if options.model then
    vim.list_extend(command, { "--model", options.model })
  end
  if options.session_path then
    vim.list_extend(command, { "--session", options.session_path })
  elseif options.session_id then
    vim.list_extend(command, { "--session-id", options.session_id })
  end
  if options.name then
    vim.list_extend(command, { "--name", util.truncate(options.name, 100) })
  end
  if options.tools then
    vim.list_extend(command, { "--tools", table.concat(options.tools, ",") })
  end
  return command
end

function M.build(options)
  return add_options({ config.get().pi.command, "--mode", "rpc" }, options or {})
end

function M.interactive(options)
  local command = add_options({ config.get().pi.command, "--tui-mode", "fullscreen" }, options or {})
  vim.list_extend(command, { "--extension", plugin_root .. "/pi/session-log.js" })
  if config.get().pairing.enabled then
    vim.list_extend(command, { "--extension", plugin_root .. "/pi/pairing.js" })
  end
  return command
end

function M.session_id()
  return util.uuid()
end

return M
