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
  local self = setmetatable({ registration_token = 0 }, Chat)
  self.terminal_sidebar = Terminal.new({
    model = models.get("chat"),
    on_start = function(path, session_id) self:_register(path, session_id) end,
  })
  return self
end

function Chat:_add_to_index(path)
  index.add({
    path = path,
    kind = "chat",
    cwd = util.cwd(),
    prompt = "chat: " .. util.basename(util.cwd()),
  }, index.report_error)
end

function Chat:_register(path, session_id)
  self.registration_token = self.registration_token + 1
  local token = self.registration_token
  if path then
    self:_add_to_index(path)
    return
  end
  local function find_session()
    if token ~= self.registration_token or not session_id then
      return
    end
    sessions.find_by_id(util.cwd(), session_id, function(error_message, found)
      if token ~= self.registration_token then
        return
      end
      if error_message then
        index.report_error(error_message)
        return
      end
      if found then
        self.terminal_sidebar.session_path = found
        self:_add_to_index(found)
        return
      end
      if self.terminal_sidebar.job_id then
        vim.defer_fn(find_session, 1000)
      end
    end)
  end
  find_session()
end

function Chat:toggle()
  self.terminal_sidebar:focus_flip()
end

function Chat:close()
  self.terminal_sidebar:close()
end

function Chat:abort()
  self.terminal_sidebar:abort()
end

function Chat:switch_session(path)
  self.terminal_sidebar:switch_session(path)
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
  self.terminal_sidebar:shutdown()
end

local function get()
  instance = instance or Chat.new()
  return instance
end

function M.toggle() get():toggle() end
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
