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

-- Reports keep narrative order. A malformed response remains readable without
-- guessing source coordinates from arbitrary Markdown.
function M.report(text)
  local raw = text or ""
  local json = M.strip_code_fence(raw)
  local ok, decoded = pcall(vim.json.decode, json)
  if not ok or type(decoded) ~= "table" or type(decoded.report) ~= "string"
    or type(decoded.locations) ~= "table" or not vim.islist(decoded.locations) then
    return { report = raw, locations = {}, warning = "Pi returned an unstructured report; jump locations are unavailable." }
  end
  local result = { report = decoded.report, locations = {} }
  local function positive(value)
    return type(value) == "number" and value >= 1 and value <= 2147483647 and value == math.floor(value)
  end
  for _, location in ipairs(decoded.locations) do
    local valid = type(location) == "table"
      and type(location.path) == "string" and location.path:sub(1, 1) == "/" and not location.path:find("[%z\r\n]")
      and positive(location.lnum) and positive(location.col or 1) and positive(location.count or 1)
      and location.lnum + (location.count or 1) - 1 <= 2147483647
      and type(location.notes) == "string" and location.notes:find("%S")
      and vim.tbl_contains({ "working tree", "editor snapshot", "index", "revision" }, location.source)
      and (location.anchor == nil or (type(location.anchor) == "string" and not location.anchor:find("[%z\r\n]")))
    if valid then
      table.insert(result.locations, {
        path = location.path, lnum = location.lnum, col = location.col or 1, count = location.count or 1,
        notes = location.notes, source = location.source, anchor = location.anchor,
      })
    else
      result.warning = "Pi returned invalid locations; those entries remain in the raw response below, not in the jump list."
    end
  end
  if result.warning then
    result.report = result.report .. "\n\n## Raw response\n\n" .. raw
  end
  return result
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
