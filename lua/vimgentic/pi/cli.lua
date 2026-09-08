local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}

function M.build(options)
  options = options or {}
  local command = { config.get().pi.command, "--mode", "rpc" }
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
  return command
end

function M.session_id()
  return util.uuid()
end

return M
