local parse = require("vimgentic.parse")

describe("vimgentic.parse", function()
  it("parses a complete location", function()
    eq({ { path = "/tmp/example.lua", lnum = 12, col = 4, count = 3, notes = "matching function" } }, parse.parse("/tmp/example.lua:12:4,3,matching function"))
  end)

  it("keeps commas in notes", function()
    eq("first, second, third", parse.parse("/tmp/example.lua:2:1,1,first, second, third")[1].notes)
  end)

  it("defaults a missing column to one", function()
    eq({ { path = "/tmp/example.lua", lnum = 8, col = 1, count = 2, notes = "two lines" } }, parse.parse("/tmp/example.lua:8,2,two lines"))
  end)

  it("ignores garbage lines", function()
    eq({}, parse.parse("Here are the results:\nnone\n/tmp/no-count.lua:2:3,note"))
  end)

  it("parses locations inside a fenced reply", function()
    eq(2, #parse.parse("```text\n/tmp/a.lua:1:1,1,one\n/tmp/b.lua:2:2,1,two\n```"))
  end)

  it("removes one wrapping code fence", function()
    eq("local value = 1", parse.strip_code_fence("```lua\nlocal value = 1\n```"))
  end)
end)
