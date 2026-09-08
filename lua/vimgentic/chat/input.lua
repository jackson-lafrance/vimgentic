local util = require("vimgentic.util")

local M = {}
local contexts = {}

local builtins = {
  "/model", "/thinking", "/compact", "/new", "/name", "/session", "/fork", "/clone",
  "/export", "/resume", "/tree", "/abort", "/terminal",
}

local function submit(buffer, behavior)
  local context = contexts[buffer]
  if not context then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  if text:match("^%s*$") then
    return
  end
  context.submit(text, behavior)
end

local function insert_path(buffer, path)
  local window = vim.fn.bufwinid(buffer)
  if window == -1 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local line = vim.api.nvim_buf_get_lines(buffer, cursor[1] - 1, cursor[1], false)[1]
  local text = "@" .. path
  local before = line:sub(1, cursor[2])
  local after = line:sub(cursor[2] + 1)
  vim.api.nvim_buf_set_lines(buffer, cursor[1] - 1, cursor[1], false, { before .. text .. after })
  vim.api.nvim_win_set_cursor(window, { cursor[1], cursor[2] + #text })
  vim.api.nvim_set_current_win(window)
  vim.cmd("startinsert")
end

local function pick_path(buffer)
  local context = contexts[buffer]
  if not context then
    return
  end
  require("fzf-lua").files({
    cwd = util.cwd(),
    actions = {
      ["enter"] = function(selected)
        if selected[1] then
          insert_path(buffer, selected[1])
        end
      end,
    },
  })
end

local function path_completions(base)
  local cwd = util.cwd()
  local seen = {}
  local results = {}
  local function add(path)
    if not path or path == "" or path:sub(1, #cwd) ~= cwd then
      return
    end
    local relative = util.relative_path(path, cwd)
    local completion = "@" .. relative
    if not seen[completion] and completion:sub(1, #base) == base then
      seen[completion] = true
      table.insert(results, completion)
    end
  end
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      add(vim.api.nvim_buf_get_name(buffer))
    end
  end
  for _, path in ipairs(vim.v.oldfiles or {}) do
    add(path)
  end
  table.sort(results)
  return results
end

function M.omnifunc(find_start, base)
  local buffer = vim.api.nvim_get_current_buf()
  local context = contexts[buffer]
  if find_start == 1 then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line():sub(1, cursor[2])
    local token = line:match("[/%@][^%s]*$") or ""
    return cursor[2] - #token
  end
  if base:sub(1, 1) == "@" then
    return path_completions(base)
  end
  local commands = vim.deepcopy(builtins)
  if context and context.commands then
    vim.list_extend(commands, context.commands())
  end
  local seen = {}
  local matches = {}
  for _, command in ipairs(commands) do
    if not seen[command] and command:sub(1, #base) == base then
      seen[command] = true
      table.insert(matches, command)
    end
  end
  table.sort(matches)
  return matches
end

function M.setup(buffer, handlers)
  contexts[buffer] = handlers
  vim.bo[buffer].omnifunc = "v:lua.vimgentic_omnifunc"
  _G.vimgentic_omnifunc = M.omnifunc
  vim.keymap.set("n", "<CR>", function() submit(buffer, nil) end, { buffer = buffer, desc = "Submit vimgentic input" })
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd("stopinsert")
    submit(buffer, nil)
  end, { buffer = buffer, desc = "Submit vimgentic input" })
  vim.keymap.set("n", "<C-f>", function() submit(buffer, "followUp") end, { buffer = buffer, desc = "Queue vimgentic follow-up" })
  vim.keymap.set("i", "<C-f>", function() pick_path(buffer) end, { buffer = buffer, desc = "Insert a file path" })
end

return M
