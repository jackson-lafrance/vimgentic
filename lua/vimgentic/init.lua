local M = {}
local configured = false

function M.setup(options)
  local values = require("vimgentic.config").setup(options)
  require("vimgentic.pi.models").setup(values.models)
  if not configured then
    configured = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("vimgentic.lifecycle", { clear = true }),
      callback = function()
        require("vimgentic.ops.oneshot").abort_all()
        require("vimgentic.ops.chat").shutdown()
      end,
    })
  end
  return M
end

function M.search(options)
  require("vimgentic.ops.search").search(options)
end

function M.visual(options)
  require("vimgentic.ops.visual").visual(options)
end

function M.visual_preview()
  require("vimgentic.ops.visual").preview()
end

function M.pair(options)
  require("vimgentic.ops.pair").actions(options)
end

function M.chat_toggle()
  require("vimgentic.ops.chat").toggle()
end

function M.chat_close()
  require("vimgentic.ops.chat").close()
end

function M.chat_selection()
  require("vimgentic.ops.chat").selection_to_input()
end

function M.history()
  require("vimgentic.ui.picker").history()
end

function M.reopen()
  require("vimgentic.ops.search").reopen()
end

function M.abort_all()
  require("vimgentic.ops.oneshot").abort_all()
  require("vimgentic.ops.chat").abort()
end

function M.pick_model()
  require("vimgentic.ui.picker").models()
end

function M.logs()
  require("vimgentic.log").open()
end

function M.terminal()
  require("vimgentic.ops.chat").terminal()
end

return M
