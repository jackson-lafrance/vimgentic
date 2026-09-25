local config = require("vimgentic.config")
local cli = require("vimgentic.pi.cli")
local rpc = require("vimgentic.pi.rpc")
local util = require("vimgentic.util")

local M = {}
local configured = {}
local overrides = {}
local cached_models
local loading_callbacks
local persistence_path
local picker_generation = 0
local cancel_lookup

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
  util.mkdir_p(directory, function(mkdir_error)
    if mkdir_error then
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
  if not vim.tbl_contains({ "search", "review", "tour", "visual", "chat" }, kind) then
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
  local function received(result)
    local error_message
    local models = {}
    if result.code ~= 0 then
      error_message = "pi --list-models failed: " .. (result.stderr or "")
    else
      local header = false
      for _, line in ipairs(vim.split(result.stdout or "", "\n", { trimempty = true })) do
        local provider, model = line:match("^(%S+)%s+(%S+)")
        if provider == "provider" and model == "model" then
          header = true
        elseif header and provider and model then
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
  end
  local ok, error_message = pcall(vim.system, { config.get().pi.command, "--list-models" }, { text = true }, received)
  if not ok then received({ code = -1, stderr = tostring(error_message) }) end
end

function M.thinking_levels(model, callback)
  local argv = cli.build({ model = model })
  table.insert(argv, "--no-session")
  local ok, client = pcall(rpc.new, { argv = argv, cwd = util.cwd(), log_id = "model-picker" })
  if not ok then callback(tostring(client)); return end
  local done, unsubscribe = false, nil
  local function finish(error_message, levels)
    if done then return end
    done = true
    if unsubscribe then unsubscribe() end
    client:close()
    callback(error_message, levels)
  end
  unsubscribe = client:on_event(function(event)
    if event.type == "extension_ui_request" and vim.tbl_contains({ "select", "confirm", "input", "editor" }, event.method) then
      client:write({ type = "extension_ui_response", id = event.id, cancelled = true })
      finish("Model selection needs Pi input: " .. (event.title or event.method))
    elseif event.type == "process_exit" then
      finish(event.stderr and event.stderr ~= "" and event.stderr or "Pi exited before returning thinking levels")
    end
  end)
  client:send({ type = "get_available_thinking_levels" }, function(response)
    if not response.success then finish(response.error or "Could not read Pi's thinking levels"); return end
    local levels = type(response.data) == "table" and response.data.levels or nil
    if type(levels) ~= "table" or not vim.islist(levels) or #levels == 0 then
      finish("Pi returned no supported thinking levels")
      return
    end
    for _, level in ipairs(levels) do
      if type(level) ~= "string" or not level:match("^[a-z]+$") then
        finish("Pi returned an invalid thinking level")
        return
      end
    end
    finish(nil, levels)
  end)
  return function() finish("Model selection cancelled") end
end

function M.cancel_pick()
  picker_generation = picker_generation + 1
  local cancel = cancel_lookup
  cancel_lookup = nil
  if cancel then cancel() end
end

function M.pick(operation, callback)
  M.cancel_pick()
  local generation = picker_generation
  local function current() return generation == picker_generation end
  local function save(model)
    if not current() then return end
    M.set(operation, model, function(write_error)
      if write_error then
        util.notify("Could not save model: " .. tostring(write_error), vim.log.levels.ERROR)
        return
      end
      if not current() then return end
      if callback then callback(model) end
      util.notify(operation .. " model: " .. (model or "pi default"))
    end)
  end
  M.fetch(function(error_message, available)
    if not current() then return end
    if error_message then
      util.notify(error_message, vim.log.levels.ERROR)
      return
    end
    local entries = { "(pi default)" }
    vim.list_extend(entries, available)
    require("fzf-lua").fzf_exec(entries, {
      prompt = "Model for " .. operation .. "> ",
      no_hide = true,
      no_resume = true,
      actions = {
        ["enter"] = function(selected)
          if not current() or not selected[1] then return end
          local model = selected[1]
          if model == "(pi default)" then save(nil); return end
          cancel_lookup = M.thinking_levels(model, function(level_error, levels)
            if not current() then return end
            cancel_lookup = nil
            if level_error then util.notify(level_error, vim.log.levels.ERROR); return end
            local choices = { "(pi default)" }
            vim.list_extend(choices, levels)
            require("fzf-lua").fzf_exec(choices, {
              prompt = "Thinking for " .. operation .. "> ",
              no_hide = true,
              no_resume = true,
              fzf_opts = { ["--header"] = model .. " — higher thinking can take longer and use more tokens" },
              actions = {
                ["enter"] = function(thinking)
                  if not current() or not thinking[1] then return end
                  if thinking[1] == "(pi default)" then
                    save(model)
                  elseif vim.tbl_contains(levels, thinking[1]) then
                    save(model .. ":" .. thinking[1])
                  end
                end,
              },
            })
          end)
        end,
      },
    })
  end)
end

return M
