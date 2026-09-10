local M = {}

local defaults = {
  models = {
    search = nil,
    visual = nil,
    chat = nil,
  },
  chat = {
    width = 0.45,
    min_width = 60,
  },
  pi = {
    command = "pi",
  },
  pairing = {
    enabled = false,
  },
  timeout = {
    command = 30000,
    operation = 600000,
  },
  log = {
    max_entries = 1000,
  },
}

local values = vim.deepcopy(defaults)

local function check_model(name, value)
  if value ~= nil and (type(value) ~= "string" or value == "") then
    error("vimgentic: models." .. name .. " must be a non-empty string or nil")
  end
end

local function validate(config)
  for _, kind in ipairs({ "search", "visual", "chat" }) do
    check_model(kind, config.models[kind])
  end
  if type(config.chat.width) ~= "number" or config.chat.width <= 0 or config.chat.width >= 1 then
    error("vimgentic: chat.width must be between 0 and 1")
  end
  if type(config.chat.min_width) ~= "number" or config.chat.min_width < 20 then
    error("vimgentic: chat.min_width must be at least 20")
  end
  if type(config.pi.command) ~= "string" or config.pi.command == "" then
    error("vimgentic: pi.command must be a non-empty string")
  end
  if type(config.pairing.enabled) ~= "boolean" then
    error("vimgentic: pairing.enabled must be a boolean")
  end
  if type(config.timeout.command) ~= "number" or config.timeout.command <= 0 then
    error("vimgentic: timeout.command must be positive")
  end
  if type(config.timeout.operation) ~= "number" or config.timeout.operation <= 0 then
    error("vimgentic: timeout.operation must be positive")
  end
end

function M.setup(options)
  values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  validate(values)
  return values
end

function M.get()
  return values
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
