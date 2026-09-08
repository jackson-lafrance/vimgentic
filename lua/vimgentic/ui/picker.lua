local index = require("vimgentic.pi.index")
local models = require("vimgentic.pi.models")
local parse = require("vimgentic.parse")
local qf = require("vimgentic.ui.qf")
local sessions = require("vimgentic.pi.sessions")
local util = require("vimgentic.util")

local M = {}

local function age(timestamp)
  local seconds = math.max(0, os.time() - (timestamp or os.time()))
  if seconds < 60 then return tostring(seconds) .. "s ago" end
  if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m ago" end
  if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h ago" end
  return tostring(math.floor(seconds / 86400)) .. "d ago"
end

local function history_previewer()
  local builtin = require("fzf-lua.previewer.builtin")
  local Previewer = builtin.base:extend()

  function Previewer:new(options, picker_options, fzf_window)
    self.super.new(self, options, picker_options, fzf_window)
    setmetatable(self, Previewer)
    return self
  end

  function Previewer:populate_preview_buf(entry_string)
    local item_index = tonumber(entry_string:match("\t(%d+)$"))
    local entry = item_index and self.opts._vimgentic_entries[item_index]
    local buffer = self:get_tmp_buffer()
    vim.bo[buffer].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "Loading session preview…" })
    self:set_preview_buf(buffer)
    if not entry then
      return
    end
    self.win:update_preview_title(entry.path)
    sessions.preview(entry.path, function(error_message, preview)
      if not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      local lines
      if error_message then
        lines = { tostring(error_message) }
      else
        lines = { "## First user message", "" }
        vim.list_extend(lines, util.split_lines(preview.user))
        vim.list_extend(lines, { "", "## Last assistant message", "" })
        vim.list_extend(lines, util.split_lines(preview.assistant))
      end
      vim.bo[buffer].modifiable = true
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
      vim.bo[buffer].modifiable = false
    end)
  end

  return Previewer
end

local function delete_session(entry, state)
  vim.ui.select({ "Delete", "Cancel" }, { prompt = "Delete " .. entry.path .. "?" }, function(choice)
    if choice ~= "Delete" then
      return
    end
    local function removed(error_message)
      if error_message then
        util.notify("Could not delete session: " .. tostring(error_message), vim.log.levels.ERROR)
        return
      end
      index.remove(entry.path, function(index_error)
        if index_error then index.report_error(index_error) end
        M.history(state)
      end)
    end
    if vim.fn.executable("trash") == 1 then
      vim.system({ "trash", entry.path }, {}, function(result)
        vim.schedule(function() removed(result.code == 0 and nil or result.stderr) end)
      end)
    else
      vim.uv.fs_unlink(entry.path, function(error_message)
        vim.schedule(function() removed(error_message) end)
      end)
    end
  end)
end

local function open_search(entry)
  sessions.last_assistant(entry.path, function(error_message, text)
    if error_message then
      util.notify(tostring(error_message), vim.log.levels.ERROR)
      return
    end
    local results = parse.parse(text or "")
    if #results == 0 then
      util.notify("This search session has no locations")
      return
    end
    qf.open(results, "vimgentic search: " .. util.truncate(entry.prompt, 80))
  end)
end

local function show_history(entries, state)
  if #entries == 0 then
    util.notify("No matching pi sessions")
    return
  end
  table.sort(entries, function(left, right) return (left.created or 0) > (right.created or 0) end)
  local lines = {}
  for item_index, entry in ipairs(entries) do
    local project = state.all_projects and ("  " .. util.basename(entry.cwd or "?")) or ""
    local prompt = entry.prompt or entry.name or "pi session"
    lines[item_index] = string.format("[%-6s]  %-8s%s  %s\t%d", entry.kind or "pi", age(entry.created), project, util.truncate(prompt, 100), item_index)
  end
  local function selected_entry(selected)
    local item_index = selected[1] and tonumber(selected[1]:match("\t(%d+)$"))
    return item_index and entries[item_index] or nil
  end
  require("fzf-lua").fzf_exec(lines, {
    prompt = "Pi history> ",
    previewer = history_previewer(),
    _vimgentic_entries = entries,
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "1",
      ["--header"] = "ctrl-p: projects  ctrl-a: all pi  ctrl-q: quickfix  ctrl-d: delete",
    },
    actions = {
      ["enter"] = function(selected)
        local entry = selected_entry(selected)
        if entry then require("vimgentic.ops.chat").switch_session(entry.path) end
      end,
      ["ctrl-p"] = function()
        state.all_projects = not state.all_projects
        vim.schedule(function() M.history(state) end)
      end,
      ["ctrl-a"] = function()
        state.all_pi = not state.all_pi
        vim.schedule(function() M.history(state) end)
      end,
      ["ctrl-q"] = function(selected)
        local entry = selected_entry(selected)
        if entry and entry.kind == "search" then
          open_search(entry)
        else
          util.notify("Quickfix is available only for vimgentic search sessions")
        end
      end,
      ["ctrl-d"] = function(selected)
        local entry = selected_entry(selected)
        if entry then delete_session(entry, state) end
      end,
    },
  })
end

function M.history(state)
  state = state or { all_projects = false, all_pi = false }
  local cwd = util.cwd()
  index.list({ cwd = state.all_projects and nil or cwd }, function(index_error, indexed)
    vim.schedule(function()
      if index_error then
        index.report_error(index_error)
        return
      end
      if not state.all_pi then
        show_history(indexed, state)
        return
      end
      sessions.list({ cwd = cwd, all_projects = state.all_projects }, function(session_error, pi_entries)
        if session_error then
          util.notify(tostring(session_error), vim.log.levels.ERROR)
          return
        end
        local by_path = {}
        local combined = {}
        for _, entry in ipairs(indexed) do
          by_path[entry.path] = true
          table.insert(combined, entry)
        end
        for _, entry in ipairs(pi_entries) do
          if not by_path[entry.path] then
            table.insert(combined, entry)
          end
        end
        show_history(combined, state)
      end)
    end)
  end)
end

function M.models()
  require("fzf-lua").fzf_exec({ "search", "visual", "chat" }, {
    prompt = "Vimgentic operation> ",
    actions = {
      ["enter"] = function(selected)
        local operation = selected[1]
        if not operation then return end
        models.pick(operation, function(model)
          if operation == "chat" and model then
            require("vimgentic.ops.chat").set_model(model)
          end
        end)
      end,
    },
  })
end

return M
