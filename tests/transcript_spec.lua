local Transcript = require("vimgentic.chat.transcript").Transcript

local function transcript()
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].modifiable = false
  return Transcript.new(buffer, {
    schedule = function(callback) callback() end,
    show_thinking = false,
  }), buffer
end

describe("vimgentic.chat.transcript", function()
  it("coalesces a text delta into the last block without changing older boundaries", function()
    local view, buffer = transcript()
    view:add_user("Question")
    local user_first = view:get_blocks()[1].first_line
    local user_last = view:get_blocks()[1].last_line
    view:feed_event({ type = "message_start", message = { role = "assistant", content = {} } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_start", contentIndex = 0 } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "Hello" } })
    eq(2, view.last_render_from)
    eq(user_first, view:get_blocks()[1].first_line)
    eq(user_last, view:get_blocks()[1].last_line)
    eq({ "## You", "Question", "", "## Pi", "Hello", "" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("uses message_end as the authoritative assistant content", function()
    local view, buffer = transcript()
    view:feed_event({ type = "message_start", message = { role = "assistant", content = {} } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_start", contentIndex = 0 } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "Partial" } })
    view:feed_event({
      type = "message_end",
      message = { role = "assistant", content = { { type = "text", text = "Final answer" } } },
    })
    eq({ "## Pi", "Final answer", "" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  end)

  it("renders a recorded text and tool event sequence with block boundaries", function()
    local view, buffer = transcript()
    view:feed_event({ type = "message_start", message = { role = "assistant", content = {} } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_start", contentIndex = 0 } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "I will search." } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "toolcall_start", contentIndex = 1, id = "call-1", toolName = "bash" } })
    view:feed_event({ type = "message_update", assistantMessageEvent = { type = "toolcall_delta", contentIndex = 1, delta = '{"command":"rg value"}' } })
    view:feed_event({
      type = "message_end",
      message = {
        role = "assistant",
        content = {
          { type = "text", text = "I will search." },
          { type = "toolCall", id = "call-1", name = "bash", arguments = { command = "rg value" } },
        },
      },
    })
    view:feed_event({ type = "tool_execution_start", toolCallId = "call-1", toolName = "bash", args = { command = "rg value" } })
    view:feed_event({
      type = "tool_execution_end",
      toolCallId = "call-1",
      toolName = "bash",
      result = { content = { { type = "text", text = "a.lua:1:value\nb.lua:2:value" } } },
      isError = false,
    })
    local blocks = view:get_blocks()
    eq(2, #blocks)
    eq({ 1, 3 }, { blocks[1].first_line, blocks[1].last_line })
    eq({ 4, 7 }, { blocks[2].first_line, blocks[2].last_line })
    eq("▸ bash  rg value  (done, 2 lines)", vim.api.nvim_buf_get_lines(buffer, 3, 4, false)[1])
  end)

  it("rebuilds blocks from saved messages", function()
    local view = transcript()
    view:render_messages({
      { role = "user", content = "Question" },
      { role = "assistant", content = { { type = "text", text = "Answer" } } },
    })
    eq("user", view:get_blocks()[1].kind)
    eq("assistant_text", view:get_blocks()[2].kind)
  end)
end)
