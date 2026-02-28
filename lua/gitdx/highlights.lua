local config = require("gitdx.config")

local M = {}

local group_name = "GitDxHighlights"
local autocmd_registered = false

function M.apply()
  local highlights = config.get().highlights

  for group, opts in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, opts)
  end
end

function M.register_autocmd()
  if autocmd_registered then
    return
  end

  local augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      M.apply()
    end,
  })

  autocmd_registered = true
end

return M
