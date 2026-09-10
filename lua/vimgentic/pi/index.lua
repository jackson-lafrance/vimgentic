local sessions = require("vimgentic.pi.sessions")
local util = require("vimgentic.util")

local M = {}
local Index = {}
Index.__index = Index

local function default_log_path()
  return vim.fn.stdpath("data") .. "/vimgentic/session-log.jsonl"
end

local function read_file(path, callback)
  vim.uv.fs_open(path, "r", 438, function(open_error, descriptor)
    if open_error then
      if tostring(open_error):match("ENOENT") then
        callback(nil, "[]")
      else
        callback(open_error)
      end
      return
    end
    vim.uv.fs_fstat(descriptor, function(stat_error, stat)
      if stat_error then
        vim.uv.fs_close(descriptor)
        callback(stat_error)
        return
      end
      vim.uv.fs_read(descriptor, stat.size, 0, function(read_error, data)
        vim.uv.fs_close(descriptor)
        callback(read_error, data or "[]")
      end)
    end)
  end)
end

local function write_file(path, contents, callback)
  local directory = vim.fs.dirname(path)
  local function write()
    local temporary = path .. ".tmp-" .. tostring(vim.uv.hrtime())
    vim.uv.fs_open(temporary, "w", 384, function(open_error, descriptor)
      if open_error then
        callback(open_error)
        return
      end
      vim.uv.fs_write(descriptor, contents, 0, function(write_error)
        vim.uv.fs_close(descriptor, function(close_error)
          if write_error or close_error then
            callback(write_error or close_error)
            return
          end
          vim.uv.fs_rename(temporary, path, function(rename_error)
            callback(rename_error)
          end)
        end)
      end)
    end)
  end
  util.mkdir_p(directory, function(mkdir_error)
    if mkdir_error then
      callback(mkdir_error)
      return
    end
    write()
  end)
end

function Index.new(options)
  return setmetatable({
    path = assert(options.path),
    log = options.log or default_log_path(),
    mutations = {},
    mutation_active = false,
  }, Index)
end

function Index:_read(callback)
  read_file(self.path, function(error_message, contents)
    if error_message then
      callback(error_message)
      return
    end
    local ok, entries = pcall(vim.json.decode, contents)
    if not ok or type(entries) ~= "table" then
      callback("invalid vimgentic session index: " .. tostring(entries))
      return
    end
    callback(nil, entries)
  end)
end

function Index:_write(entries, callback)
  local ok, encoded = pcall(vim.json.encode, entries)
  if not ok then
    callback(encoded)
    return
  end
  write_file(self.path, encoded, callback)
end

function Index:_next_mutation()
  if self.mutation_active or #self.mutations == 0 then
    return
  end
  self.mutation_active = true
  local mutation = table.remove(self.mutations, 1)
  self:_read(function(read_error, entries)
    if read_error then
      self.mutation_active = false
      mutation.callback(read_error)
      self:_next_mutation()
      return
    end
    local changed = mutation.change(entries)
    self:_write(changed, function(write_error)
      self.mutation_active = false
      mutation.callback(write_error, changed)
      self:_next_mutation()
    end)
  end)
end

function Index:_mutate(change, callback)
  table.insert(self.mutations, { change = change, callback = callback or function() end })
  self:_next_mutation()
end

function Index:add(entry, callback)
  local saved = vim.deepcopy(entry)
  saved.created = saved.created or os.time()
  saved.nvim_pid = saved.nvim_pid or vim.fn.getpid()
  self:_mutate(function(entries)
    local updated = {}
    for _, existing in ipairs(entries) do
      if existing.path ~= saved.path then
        table.insert(updated, existing)
      end
    end
    table.insert(updated, saved)
    return updated
  end, callback)
end

function Index:remove(path, callback)
  self:_mutate(function(entries)
    local updated = {}
    for _, entry in ipairs(entries) do
      if entry.path ~= path then
        table.insert(updated, entry)
      end
    end
    return updated
  end, callback)
end

function Index:list(options, callback)
  options = options or {}
  self:_read(function(read_error, entries)
    if read_error then
      callback(read_error)
      return
    end
    if #entries == 0 then
      callback(nil, {})
      return
    end
    local remaining = #entries
    local kept = {}
    local pruned = false
    for index, entry in ipairs(entries) do
      vim.uv.fs_stat(entry.path, function(stat_error, stat)
        if not stat_error and stat and stat.type == "file" then
          kept[index] = entry
        else
          pruned = true
        end
        remaining = remaining - 1
        if remaining ~= 0 then
          return
        end
        local compacted = {}
        for item_index = 1, #entries do
          if kept[item_index] then
            table.insert(compacted, kept[item_index])
          end
        end
        local filtered = {}
        for _, item in ipairs(compacted) do
          if not options.cwd or item.cwd == options.cwd then
            table.insert(filtered, item)
          end
        end
        table.sort(filtered, function(left, right)
          return (left.created or 0) > (right.created or 0)
        end)
        if pruned then
          self:_write(compacted, function(write_error)
            callback(write_error, filtered)
          end)
        else
          callback(nil, filtered)
        end
      end)
    end
  end)
end

function Index:sync_from_log(callback)
  callback = callback or function() end
  self:_read(function(read_error, entries)
    if read_error then
      callback(read_error)
      return
    end
    read_file(self.log, function(log_error, contents)
      if log_error then
        callback(log_error)
        return
      end
      local known = {}
      for _, entry in ipairs(entries) do
        known[entry.path] = true
      end
      local pending = {}
      for line in tostring(contents):gmatch("[^\r\n]+") do
        local ok, record = pcall(vim.json.decode, line)
        if ok and type(record) == "table" and type(record.path) == "string" and not known[record.path] then
          known[record.path] = true
          table.insert(pending, record)
        end
      end
      if #pending == 0 then
        callback(nil)
        return
      end
      local remaining = #pending
      local collected = {}
      for _, record in ipairs(pending) do
        sessions.read_metadata(record.path, function(metadata_error, metadata)
          if not metadata_error and metadata then
            table.insert(collected, {
              path = metadata.path,
              kind = "chat",
              cwd = type(record.cwd) == "string" and record.cwd or metadata.cwd,
              prompt = metadata.prompt,
              created = metadata.created,
            })
          end
          remaining = remaining - 1
          if remaining ~= 0 then
            return
          end
          if #collected == 0 then
            callback(nil)
            return
          end
          self:_mutate(function(current)
            local present = {}
            for _, entry in ipairs(current) do
              present[entry.path] = true
            end
            for _, entry in ipairs(collected) do
              if not present[entry.path] then
                entry.created = entry.created or os.time()
                entry.nvim_pid = entry.nvim_pid or vim.fn.getpid()
                table.insert(current, entry)
                present[entry.path] = true
              end
            end
            return current
          end, callback)
        end)
      end
    end)
  end)
end

M.Index = Index

local singleton
local function default_index()
  if not singleton then
    singleton = Index.new({ path = vim.fn.stdpath("data") .. "/vimgentic/sessions.json" })
  end
  return singleton
end

function M.add(entry, callback)
  default_index():add(entry, callback)
end

function M.remove(path, callback)
  default_index():remove(path, callback)
end

function M.list(options, callback)
  default_index():list(options, callback)
end

function M.sync_from_log(callback)
  default_index():sync_from_log(callback)
end

function M.path()
  return default_index().path
end

function M.report_error(error_message)
  if error_message then
    util.notify("Session index: " .. tostring(error_message), vim.log.levels.ERROR)
  end
end

return M
