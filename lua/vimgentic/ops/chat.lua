local index = require("vimgentic.pi.index")
local models = require("vimgentic.pi.models")
local sessions = require("vimgentic.pi.sessions")
local selection = require("vimgentic.selection")
local Terminal = require("vimgentic.chat.terminal").Terminal
local util = require("vimgentic.util")

local M = {}
local Chat = {}
Chat.__index = Chat
local instance

function Chat.new()
  local self = setmetatable({ history_token = 0 }, Chat)
  self.terminal_sidebar = Terminal.new({
    model = models.get("chat"),
    on_session = function() index.sync_from_log(index.report_error) end,
  })
  return self
end

function Chat:toggle()
  self.terminal_sidebar:focus_flip()
end

function Chat:new_chat()
  self.history_token = self.history_token + 1
  self.terminal_sidebar:new_chat()
end

function Chat:close()
  self.history_token = self.history_token + 1
  self.terminal_sidebar:close()
end

function Chat:abort()
  self.terminal_sidebar:abort()
end

function Chat:switch_session(path)
  self.history_token = self.history_token + 1
  local token = self.history_token
  sessions.read_metadata(path, function(error_message, metadata)
    vim.schedule(function()
      if token ~= self.history_token then return end
      if error_message or not metadata or type(metadata.cwd) ~= "string" or metadata.cwd == "" then
        util.notify(error_message or "Could not read pi session: " .. path, vim.log.levels.ERROR)
        return
      end
      self.terminal_sidebar:switch_session(path, metadata.cwd)
    end)
  end)
end

function Chat:set_model(model)
  self.terminal_sidebar:set_model(model)
end

function Chat:selection_to_input()
  local context, error_message = selection.capture({ visual = true })
  if not context then
    util.notify(error_message, vim.log.levels.WARN)
    return
  end
  self.terminal_sidebar:send_text(selection.render(context))
end

function Chat:shutdown()
  self.history_token = self.history_token + 1
  self.terminal_sidebar:shutdown()
end

local function get()
  instance = instance or Chat.new()
  return instance
end

function M.toggle() get():toggle() end
function M.new_chat() get():new_chat() end
function M.close() get():close() end
function M.abort() if instance then instance:abort() end end
function M.switch_session(path) get():switch_session(path) end
function M.selection_to_input() get():selection_to_input() end
function M.draft(text) return get().terminal_sidebar:send_text(text) end
function M.terminal() get():toggle() end
function M.shutdown() if instance then instance:shutdown() end end
function M.set_model(model) get():set_model(model) end
function M.instance() return get() end

return M
