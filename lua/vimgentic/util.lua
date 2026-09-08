local M = {}

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "vimgentic" })
  end)
end

function M.cwd()
  return assert(vim.uv.cwd(), "vimgentic: Neovim has no current working directory")
end

function M.basename(path)
  return path:match("([^/]+)/*$") or path
end

function M.truncate(text, length)
  text = tostring(text or ""):gsub("%s+", " ")
  if #text <= length then
    return text
  end
  return text:sub(1, math.max(1, length - 1)) .. "…"
end

function M.uuid()
  local seed = table.concat({ M.cwd(), tostring(vim.uv.hrtime()), tostring(vim.fn.getpid()), tostring(math.random()) }, ":")
  local hash = vim.fn.sha256(seed)
  return table.concat({ hash:sub(1, 8), hash:sub(9, 12), "4" .. hash:sub(14, 16), "a" .. hash:sub(18, 20), hash:sub(21, 32) }, "-")
end

function M.model_parts(model)
  if not model then
    return nil, nil
  end
  local provider, model_id = model:match("^([^/]+)/(.+)$")
  return provider, model_id
end

function M.message_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end
  local parts = {}
  for _, block in ipairs(content) do
    if block.type == "text" and block.text then
      table.insert(parts, block.text)
    elseif block.type == "thinking" and block.thinking then
      table.insert(parts, block.thinking)
    end
  end
  return table.concat(parts, "\n")
end

function M.result_text(result)
  if type(result) ~= "table" then
    return tostring(result or "")
  end
  return M.message_text(result.content or result)
end

function M.relative_path(path, cwd)
  cwd = cwd or M.cwd()
  local relative = vim.fs.relpath(cwd, path)
  return relative or path
end

function M.split_lines(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
end

function M.mkdir_p(path, callback)
  vim.uv.fs_stat(path, function(stat_error, stat)
    if stat and stat.type == "directory" then
      callback()
      return
    end
    if stat_error and not tostring(stat_error):match("ENOENT") then
      callback(stat_error)
      return
    end
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      callback(stat_error or "could not create directory " .. path)
      return
    end
    M.mkdir_p(parent, function(parent_error)
      if parent_error then
        callback(parent_error)
        return
      end
      vim.uv.fs_mkdir(path, 493, function(mkdir_error)
        if mkdir_error and not tostring(mkdir_error):match("EEXIST") then
          callback(mkdir_error)
        else
          callback()
        end
      end)
    end)
  end)
end

function M.set_buffer_lines(buffer, start_line, end_line, lines)
  if not vim.api.nvim_buf_is_valid(buffer) then
    return false
  end
  local modifiable = vim.bo[buffer].modifiable
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, start_line, end_line, false, lines)
  vim.bo[buffer].modifiable = modifiable
  return true
end

return M
