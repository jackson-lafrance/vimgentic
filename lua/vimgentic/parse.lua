local M = {}

local function parse_line(line)
  local path, line_number, column, count, notes = line:match("^(.*):(%d+):(%d+),(%d+),(.*)$")
  if not path then
    path, line_number, count, notes = line:match("^(.*):(%d+),(%d+),(.*)$")
    column = "1"
  end
  if not path then
    path, line_number, column, count = line:match("^(.*):(%d+):(%d+),(%d+)$")
    notes = ""
  end
  if not path then
    path, line_number, count = line:match("^(.*):(%d+),(%d+)$")
    column = "1"
    notes = ""
  end
  if not path or path == "" then
    return nil
  end
  line_number, column, count = tonumber(line_number), tonumber(column), tonumber(count)
  if line_number < 1 or column < 1 or count < 1 then
    return nil
  end
  return {
    path = path,
    lnum = line_number,
    col = column,
    count = count,
    notes = notes,
  }
end

function M.parse(text)
  local results = {}
  for _, line in ipairs(vim.split((text or ""):gsub("\r\n", "\n"), "\n", { plain = true })) do
    if not line:match("^%s*```") then
      local result = parse_line(line)
      if result then
        table.insert(results, result)
      end
    end
  end
  return results
end

function M.to_quickfix(results)
  local items = {}
  for _, result in ipairs(results) do
    table.insert(items, {
      filename = result.path,
      lnum = result.lnum,
      col = result.col,
      end_lnum = result.lnum + result.count - 1,
      text = result.notes,
    })
  end
  return items
end

function M.strip_code_fence(text)
  text = (text or ""):gsub("\r\n", "\n")
  local fenced = text:match("^%s*```[^\n]*\n(.-)\n```%s*$")
  if fenced then
    return fenced
  end
  return text:gsub("^\n", ""):gsub("\n$", "")
end

return M
