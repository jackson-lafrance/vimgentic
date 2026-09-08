local M = {}
local last

function M.open(results, title)
  local items = require("vimgentic.parse").to_quickfix(results)
  last = { items = vim.deepcopy(items), title = title }
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen")
end

function M.reopen()
  if not last then
    vim.notify("vimgentic: no search results yet", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = last.title, items = last.items })
  vim.cmd("botright copen")
end

function M.last()
  return last and vim.deepcopy(last) or nil
end

return M
