local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}
local entries = {}
local next_request = 0

function M.request(kind, prompt)
  next_request = next_request + 1
  local id = string.format("%s-%d", kind, next_request)
  M.append(id, "start", util.truncate(prompt, 300))
  return id
end

function M.append(request_id, event, message)
  table.insert(entries, {
    time = os.date("%Y-%m-%d %H:%M:%S"),
    request_id = request_id or "plugin",
    event = event,
    message = tostring(message or ""),
  })
  local maximum = config.get().log.max_entries
  while #entries > maximum do
    table.remove(entries, 1)
  end
end

function M.lines()
  local lines = { "# vimgentic logs", "" }
  for _, entry in ipairs(entries) do
    local prefix = string.format("[%s] [%s] %s", entry.time, entry.request_id, entry.event)
    local message_lines = util.split_lines(entry.message)
    table.insert(lines, prefix .. (message_lines[1] ~= "" and ": " .. message_lines[1] or ""))
    for index = 2, #message_lines do
      table.insert(lines, "  " .. message_lines[index])
    end
  end
  return lines
end

function M.open()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "vimgentic://logs")
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, M.lines())
  vim.bo[buffer].modifiable = false
  vim.api.nvim_set_current_buf(buffer)
end

return M
