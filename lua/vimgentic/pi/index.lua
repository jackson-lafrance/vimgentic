local lock = require("vimgentic.pi.lock")
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
    local temporary = path .. ".tmp-" .. vim.uv.os_getpid() .. "-" .. tostring(vim.uv.hrtime())
    vim.uv.fs_open(temporary, "wx", 384, function(open_error, descriptor)
      if open_error then
        callback(open_error)
        return
      end
      local function finish(write_error)
        vim.uv.fs_close(descriptor, function(close_error)
          local function failed(error_message)
            vim.uv.fs_unlink(temporary, function() callback(error_message) end)
          end
          if write_error or close_error then
            failed(write_error or close_error)
            return
          end
          vim.uv.fs_rename(temporary, path, function(rename_error)
            if rename_error then failed(rename_error) else callback() end
          end)
        end)
      end
      local function write_remaining(offset)
        vim.uv.fs_write(descriptor, contents:sub(offset + 1), offset, function(write_error, written)
          if write_error or not written or written == 0 then
            finish(write_error or "Could not write session index")
          elseif offset + written < #contents then
            write_remaining(offset + written)
          else
            finish()
          end
        end)
      end
      write_remaining(0)
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
    lock_timeout = options.lock_timeout or 5000,
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
  local function complete(error_message, entries)
    vim.schedule(function()
      self.mutation_active = false
      self:_next_mutation()
      mutation.callback(error_message, entries)
    end)
  end
  lock.acquire(self.path .. ".lock", self.lock_timeout, function(lock_error, release)
    if lock_error then complete(lock_error); return end
    local finished = false
    local function finish(error_message, entries, changed)
      if finished then return end
      finished = true
      local function unlock(write_error)
        release(function(close_error) complete(write_error or close_error, entries) end)
      end
      if error_message or changed == false then
        unlock(error_message)
      else
        self:_write(entries, unlock)
      end
    end
    self:_read(function(read_error, entries)
      if read_error then finish(read_error); return end
      local ok, error_message = pcall(mutation.change, entries, finish)
      if not ok then finish(error_message) end
    end)
  end)
end

function Index:_mutate(change, callback)
  self:_transaction(function(entries, finish) finish(nil, change(entries)) end, callback)
end

function Index:_transaction(change, callback)
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
  self:_transaction(function(entries, finish)
    if #entries == 0 then finish(nil, {}, false); return end
    local remaining = #entries
    local kept = {}
    local failure
    for position, entry in ipairs(entries) do
      vim.uv.fs_stat(entry.path, function(stat_error, stat)
        if stat_error and not tostring(stat_error):match("ENOENT") then
          failure = stat_error
        elseif stat and stat.type == "file" then
          kept[position] = entry
        end
        remaining = remaining - 1
        if remaining ~= 0 then return end
        local compacted = {}
        for item_index = 1, #entries do
          if kept[item_index] then table.insert(compacted, kept[item_index]) end
        end
        finish(failure, compacted, #compacted ~= #entries)
      end)
    end
  end, function(error_message, entries)
    if error_message then callback(error_message); return end
    local filtered = {}
    for _, entry in ipairs(entries) do
      if not options.cwd or entry.cwd == options.cwd then table.insert(filtered, entry) end
    end
    table.sort(filtered, function(left, right) return (left.created or 0) > (right.created or 0) end)
    callback(nil, filtered)
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
