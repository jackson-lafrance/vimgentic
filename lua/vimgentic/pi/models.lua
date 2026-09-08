local config = require("vimgentic.config")
local util = require("vimgentic.util")

local M = {}
local configured = {}
local overrides = {}
local cached_models
local loading_callbacks
local persistence_path

local function path()
  persistence_path = persistence_path or (vim.fn.stdpath("data") .. "/vimgentic/models.json")
  return persistence_path
end

local function read_overrides()
  local target = path()
  vim.uv.fs_open(target, "r", 438, function(open_error, descriptor)
    if open_error then
      return
    end
    vim.uv.fs_fstat(descriptor, function(stat_error, stat)
      if stat_error then
        vim.uv.fs_close(descriptor)
        return
      end
      vim.uv.fs_read(descriptor, stat.size, 0, function(read_error, data)
        vim.uv.fs_close(descriptor)
        if read_error then
          return
        end
        local ok, decoded = pcall(vim.json.decode, data)
        if ok and type(decoded) == "table" then
          overrides = decoded
        end
      end)
    end)
  end)
end

local function persist(callback)
  callback = callback or function() end
  local target = path()
  local directory = vim.fs.dirname(target)
  local encoded = vim.json.encode(overrides)
  local function write()
    local temporary = target .. ".tmp-" .. tostring(vim.uv.hrtime())
    vim.uv.fs_open(temporary, "w", 384, function(open_error, descriptor)
      if open_error then
        vim.schedule(function() callback(open_error) end)
        return
      end
      vim.uv.fs_write(descriptor, encoded, 0, function(write_error)
        vim.uv.fs_close(descriptor, function(close_error)
          if write_error or close_error then
            vim.schedule(function() callback(write_error or close_error) end)
            return
          end
          vim.uv.fs_rename(temporary, target, function(rename_error)
            vim.schedule(function() callback(rename_error) end)
          end)
        end)
      end)
    end)
  end
  vim.uv.fs_mkdir(directory, 493, function(mkdir_error)
    if mkdir_error and not tostring(mkdir_error):match("EEXIST") then
      vim.schedule(function() callback(mkdir_error) end)
      return
    end
    write()
  end)
end

function M.setup(models)
  configured = vim.deepcopy(models or {})
  overrides = {}
  read_overrides()
end

function M.get(kind)
  if overrides[kind] ~= nil then
    return overrides[kind] ~= vim.NIL and overrides[kind] or nil
  end
  return configured[kind]
end

function M.set(kind, model, callback)
  if not vim.tbl_contains({ "search", "visual", "chat" }, kind) then
    error("vimgentic: unknown model operation " .. tostring(kind))
  end
  overrides[kind] = model or vim.NIL
  persist(callback)
end

function M.fetch(callback)
  if cached_models then
    vim.schedule(function() callback(nil, vim.deepcopy(cached_models)) end)
    return
  end
  if loading_callbacks then
    table.insert(loading_callbacks, callback)
    return
  end
  loading_callbacks = { callback }
  vim.system({ config.get().pi.command, "--list-models" }, { text = true }, function(result)
    local error_message
    local models = {}
    if result.code ~= 0 then
      error_message = "pi --list-models failed: " .. (result.stderr or "")
    else
      for _, line in ipairs(vim.split(result.stdout or "", "\n", { trimempty = true })) do
        local provider, model = line:match("^(%S+)%s+(%S+)")
        if provider and model and provider ~= "provider" then
          table.insert(models, provider .. "/" .. model)
        end
      end
      cached_models = models
    end
    local callbacks = loading_callbacks
    loading_callbacks = nil
    vim.schedule(function()
      for _, queued in ipairs(callbacks) do
        queued(error_message, vim.deepcopy(models))
      end
    end)
  end)
end

function M.pick(operation, callback)
  M.fetch(function(error_message, available)
    if error_message then
      util.notify(error_message, vim.log.levels.ERROR)
      return
    end
    local entries = { "(pi default)" }
    vim.list_extend(entries, available)
    require("fzf-lua").fzf_exec(entries, {
      prompt = "Model for " .. operation .. "> ",
      actions = {
        ["enter"] = function(selected)
          if not selected[1] then
            return
          end
          local model = selected[1] == "(pi default)" and nil or selected[1]
          M.set(operation, model, function(write_error)
            if write_error then
              util.notify("Could not save model: " .. tostring(write_error), vim.log.levels.ERROR)
              return
            end
            if callback then
              callback(model)
            end
            util.notify(operation .. " model: " .. (model or "pi default"))
          end)
        end,
      },
    })
  end)
end

return M
