local M = {}
local last

-- Pick the main editor window for opening a quickfix entry: the first non
-- terminal, non quickfix window, preferring the largest by area. Returns nil
-- if only the quickfix window exists.
local function main_editor_window(qf_win)
  local best, best_area
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not vim.api.nvim_win_is_valid(win) then
      goto continue
    end
    if win == qf_win then
      goto continue
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then
      goto continue
    end
    if vim.bo[buf].filetype == "vimgentic-prompt" then
      goto continue
    end
    local config = vim.api.nvim_win_get_config(win)
    if config.relative and config.relative ~= "" then
      goto continue
    end
    local width = vim.api.nvim_win_get_width(win)
    local height = vim.api.nvim_win_get_height(win)
    local area = width * height
    if not best or area > best_area then
      best = win
      best_area = area
    end
    ::continue::
  end
  return best
end

local function bind_enter(buffer)
  -- Make <CR> open the entry in the main editor window instead of the
  -- last-used window (which may be a narrow sidebar/terminal split).
  vim.keymap.set("n", "<CR>", function()
    local qf_win = vim.api.nvim_get_current_win()
    local row = vim.api.nvim_win_get_cursor(qf_win)[1]
    local target = main_editor_window(qf_win)
    if target then
      vim.api.nvim_set_current_win(target)
    end
    vim.cmd(row .. "cc")
  end, { buffer = buffer, nowait = true })
end

function M.open(results, title)
  local items = require("vimgentic.parse").to_quickfix(results)
  last = { items = vim.deepcopy(items), title = title }
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen")
  bind_enter(0)
end

function M.reopen()
  if not last then
    vim.notify("vimgentic: no search results yet", vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = last.title, items = last.items })
  vim.cmd("botright copen")
  bind_enter(0)
end

function M.last()
  return last and vim.deepcopy(last) or nil
end

return M
