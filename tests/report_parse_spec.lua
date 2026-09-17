local parse = require("vimgentic.parse")

local function location(path)
  return { path = path, lnum = 2, col = 3, count = 2, notes = "Follow the caller\nThen inspect the return", source = "working tree", anchor = "  return total" }
end

describe("vimgentic.parse.report", function()
  it("preserves narrative order, repeated files, multiline explanations, and source provenance", function()
    local locations = { location("/tmp/z.lua"), location("/tmp/a.lua"), location("/tmp/z.lua") }
    locations[2].source = "index"
    locations[3].source = "editor snapshot"
    local result = parse.report(vim.json.encode({ report = "# Scope\nConfidence: High", locations = locations }))
    eq({ report = "# Scope\nConfidence: High", locations = locations }, result)
  end)

  it("accepts fenced JSON, revision locations, and omitted optional coordinates", function()
    eq({ report = "Review", locations = {
      { path = "/tmp/revision.lua", lnum = 1, col = 1, count = 1, notes = "Historical defect", source = "revision" },
    } }, parse.report('```json\n{"report":"Review","locations":[{"path":"/tmp/revision.lua","lnum":1,"notes":"Historical defect","source":"revision"}]}\n```'))
  end)

  it("a scope question or clean review remains a report without invented findings", function()
    for _, text in ipairs({ "Review needs scope: which files?", "No actionable findings in the reviewed scope" }) do
      eq({ report = text, locations = {} }, parse.report(vim.json.encode({ report = text, locations = {} })))
    end
  end)

  it("malformed responses preserve the original text without guessing locations", function()
    for _, text in ipairs({ "", "# Review\n/tmp/not-a-finding.lua:3:1,1,note", "null", "[]", '{"report":false,"locations":[]}', '{"report":"text","locations":{}}' }) do
      local result = parse.report(text)
      eq(text, result.report)
      eq({}, result.locations)
      eq("Pi returned an unstructured report; jump locations are unavailable.", result.warning)
    end
  end)

  it("invalid locations remain in the raw report while valid locations stay jumpable", function()
    local bad_locations = { false, vim.NIL }
    for _, change in ipairs({
      { path = "relative.lua" }, { path = "https://example.test/file" }, { path = "/tmp/line\nbreak" },
      { path = "/tmp/nul\0" }, { lnum = 0 }, { lnum = 1.5 }, { col = -1 }, { count = "3" },
      { lnum = 2147483647, count = 2 }, { notes = "" }, { source = "unknown" }, { anchor = "two\nlines" },
    }) do
      table.insert(bad_locations, vim.tbl_extend("force", location("/tmp/bad.lua"), change))
    end
    for _, bad in ipairs(bad_locations) do
      local valid = location("/tmp/good.lua")
      local raw = vim.json.encode({ report = "Evidence stays readable", locations = { bad, valid } })
      local result = parse.report(raw)
      eq({ valid }, result.locations)
      truthy(result.warning:find("invalid locations", 1, true))
      truthy(result.report:find(raw, 1, true))
    end
  end)
end)
