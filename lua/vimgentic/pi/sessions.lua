local util = require("vimgentic.util")

local M = {}
local chunk_size = 65536
local cache = {}

local function session_root()
  return vim.env.PI_CODING_AGENT_SESSION_DIR or (vim.fn.expand("~/.pi/agent/sessions"))
end

local function cwd_directory(cwd)
  return session_root() .. "/--" .. cwd:gsub("/", "-") .. "--"
end

local function read_range(path, offset, length, callback)
  vim.uv.fs_open(path, "r", 438, function(open_error, descriptor)
    if open_error then
      callback(open_error)
      return
    end
    vim.uv.fs_read(descriptor, length, offset, function(read_error, data)
      vim.uv.fs_close(descriptor)
      callback(read_error, data or "")
    end)
  end)
end

local function decode(line)
  local ok, value = pcall(vim.json.decode, line)
  if ok then
    return value
  end
  return nil
end

local function find_from_start(path, stat, predicate, callback, offset, carry)
  offset = offset or 0
  carry = carry or ""
  if offset >= stat.size then
    if carry ~= "" then
      callback(nil, predicate(decode(carry)) and decode(carry) or nil)
    else
      callback(nil, nil)
    end
    return
  end
  local length = math.min(chunk_size, stat.size - offset)
  read_range(path, offset, length, function(read_error, data)
    if read_error then
      callback(read_error)
      return
    end
    local combined = carry .. data
    local parts = vim.split(combined, "\n", { plain = true })
    local next_carry = table.remove(parts) or ""
    for _, line in ipairs(parts) do
      local entry = decode(line:gsub("\r$", ""))
      if entry and predicate(entry) then
        callback(nil, entry)
        return
      end
    end
    find_from_start(path, stat, predicate, callback, offset + length, next_carry)
  end)
end

local function find_from_end(path, stat, predicate, callback, finish, carry)
  finish = finish or stat.size
  carry = carry or ""
  if finish <= 0 then
    local entry = decode(carry:gsub("\r$", ""))
    callback(nil, entry and predicate(entry) and entry or nil)
    return
  end
  local offset = math.max(0, finish - chunk_size)
  read_range(path, offset, finish - offset, function(read_error, data)
    if read_error then
      callback(read_error)
      return
    end
    local combined = data .. carry
    local parts = vim.split(combined, "\n", { plain = true })
    local next_carry = ""
    if offset > 0 then
      next_carry = table.remove(parts, 1) or ""
    end
    for index = #parts, 1, -1 do
      local line = parts[index]
      if line ~= "" then
        local entry = decode(line:gsub("\r$", ""))
        if entry and predicate(entry) then
          callback(nil, entry)
          return
        end
      end
    end
    find_from_end(path, stat, predicate, callback, offset, next_carry)
  end)
end

local function with_stat(path, callback)
  vim.uv.fs_stat(path, function(stat_error, stat)
    if stat_error or not stat then
      callback(stat_error or "missing session file")
      return
    end
    callback(nil, stat)
  end)
end

local function assistant_text(entry)
  if not entry or entry.type ~= "message" or not entry.message or entry.message.role ~= "assistant" then
    return nil
  end
  return util.message_text(entry.message.content)
end

function M.last_assistant(path, callback)
  with_stat(path, function(stat_error, stat)
    if stat_error then
      vim.schedule(function() callback(stat_error) end)
      return
    end
    find_from_end(path, stat, function(entry)
      return assistant_text(entry) ~= nil
    end, function(read_error, entry)
      vim.schedule(function()
        callback(read_error, assistant_text(entry))
      end)
    end)
  end)
end

function M.preview(path, callback)
  with_stat(path, function(stat_error, stat)
    if stat_error then
      vim.schedule(function() callback(stat_error) end)
      return
    end
    local first_user
    local last_assistant
    local remaining = 2
    local first_error
    local function done(error_message)
      first_error = first_error or error_message
      remaining = remaining - 1
      if remaining == 0 then
        vim.schedule(function()
          callback(first_error, {
            user = first_user or "",
            assistant = last_assistant or "",
          })
        end)
      end
    end
    find_from_start(path, stat, function(entry)
      return entry and entry.type == "message" and entry.message and entry.message.role == "user"
    end, function(error_message, entry)
      first_user = entry and util.message_text(entry.message.content) or ""
      done(error_message)
    end)
    find_from_end(path, stat, function(entry)
      return assistant_text(entry) ~= nil
    end, function(error_message, entry)
      last_assistant = assistant_text(entry)
      done(error_message)
    end)
  end)
end

local function timestamp_seconds(timestamp, fallback)
  if not timestamp then
    return fallback
  end
  local year, month, day, hour, minute, second = timestamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then
    return fallback
  end
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
  })
end

local function read_metadata(path, callback)
  with_stat(path, function(stat_error, stat)
    if stat_error then
      callback(stat_error)
      return
    end
    local header
    local session_info
    local remaining = 2
    local first_error
    local function done(error_message)
      first_error = first_error or error_message
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      if first_error or not header then
        callback(first_error or "session header missing")
        return
      end
      callback(nil, {
        path = path,
        kind = "pi",
        cwd = header.cwd,
        prompt = session_info and session_info.name or "pi session",
        name = session_info and session_info.name or nil,
        created = timestamp_seconds(header.timestamp, stat.mtime.sec),
        session_id = header.id,
      })
    end
    find_from_start(path, stat, function(entry)
      return entry and entry.type == "session"
    end, function(error_message, entry)
      header = entry
      done(error_message)
    end)
    find_from_end(path, stat, function(entry)
      return entry and entry.type == "session_info"
    end, function(error_message, entry)
      session_info = entry
      done(error_message)
    end)
  end)
end

local function scan_files(directory, callback)
  vim.uv.fs_scandir(directory, function(scan_error, handle)
    if scan_error then
      if tostring(scan_error):match("ENOENT") then
        callback(nil, {})
      else
        callback(scan_error)
      end
      return
    end
    local files = {}
    while true do
      local name, file_type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if file_type == "file" and name:match("%.jsonl$") then
        table.insert(files, directory .. "/" .. name)
      end
    end
    callback(nil, files)
  end)
end

local function scan_directories(root, callback)
  vim.uv.fs_scandir(root, function(scan_error, handle)
    if scan_error then
      callback(scan_error)
      return
    end
    local directories = {}
    while true do
      local name, file_type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if file_type == "directory" then
        table.insert(directories, root .. "/" .. name)
      end
    end
    callback(nil, directories)
  end)
end

local function collect_files(directories, callback)
  if #directories == 0 then
    callback(nil, {})
    return
  end
  local remaining = #directories
  local files = {}
  local first_error
  for _, directory in ipairs(directories) do
    scan_files(directory, function(error_message, found)
      first_error = first_error or error_message
      vim.list_extend(files, found or {})
      remaining = remaining - 1
      if remaining == 0 then
        callback(first_error, files)
      end
    end)
  end
end

local function collect_metadata(files, callback)
  if #files == 0 then
    callback(nil, {})
    return
  end
  local remaining = #files
  local entries = {}
  for _, path in ipairs(files) do
    read_metadata(path, function(_, entry)
      if entry then
        table.insert(entries, entry)
      end
      remaining = remaining - 1
      if remaining == 0 then
        table.sort(entries, function(left, right) return left.created > right.created end)
        callback(nil, entries)
      end
    end)
  end
end

function M.list(options, callback)
  options = options or {}
  local cwd = options.cwd or util.cwd()
  local scope_path = options.all_projects and session_root() or cwd_directory(cwd)
  vim.uv.fs_stat(scope_path, function(stat_error, stat)
    if stat_error or not stat then
      vim.schedule(function() callback(stat_error, {}) end)
      return
    end
    local cache_key = scope_path
    local mtime = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec)
    if cache[cache_key] and cache[cache_key].mtime == mtime then
      vim.schedule(function() callback(nil, vim.deepcopy(cache[cache_key].entries)) end)
      return
    end
    local function directories_done(directory_error, directories)
      if directory_error then
        vim.schedule(function() callback(directory_error) end)
        return
      end
      collect_files(directories, function(file_error, files)
        if file_error then
          vim.schedule(function() callback(file_error) end)
          return
        end
        collect_metadata(files, function(metadata_error, entries)
          if not options.all_projects then
            entries = vim.tbl_filter(function(entry) return entry.cwd == cwd end, entries)
          end
          cache[cache_key] = { mtime = mtime, entries = vim.deepcopy(entries) }
          vim.schedule(function() callback(metadata_error, entries) end)
        end)
      end)
    end
    if options.all_projects then
      scan_directories(scope_path, directories_done)
    else
      directories_done(nil, { scope_path })
    end
  end)
end

return M
