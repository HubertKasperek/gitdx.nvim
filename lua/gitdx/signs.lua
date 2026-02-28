local config = require("gitdx.config")

local M = {}

local namespace = vim.api.nvim_create_namespace("gitdx_live_diff")
local sign_group = "gitdx_live_signs"
local sign_names = {
  add = "GitDxSignMarkerAdd",
  change = "GitDxSignMarkerChange",
  delete = "GitDxSignMarkerDelete",
}

local function place_sign(kind, bufnr, lnum)
  local sign_name = sign_names[kind]
  if not sign_name then
    return
  end

  vim.fn.sign_place(0, sign_group, sign_name, bufnr, {
    lnum = lnum,
    priority = config.get().sign_priority,
  })
end

local function add_line_highlight(bufnr, lnum, group)
  pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace, group, lnum - 1, 0, -1)
end

local function add_deleted_virtual_hint(bufnr, lnum, deleted_count)
  if deleted_count <= 0 then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, lnum - 1, 0, {
    virt_text = {
      { string.format("-%d", deleted_count), "GitDxDeletedVirtual" },
    },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

function M.define()
  local opts = config.get()

  vim.fn.sign_define(sign_names.add, {
    text = opts.signs.add,
    texthl = "GitDxSignAdd",
  })

  vim.fn.sign_define(sign_names.change, {
    text = opts.signs.change,
    texthl = "GitDxSignChange",
  })

  vim.fn.sign_define(sign_names.delete, {
    text = opts.signs.delete,
    texthl = "GitDxSignDelete",
  })
end

function M.clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.fn.sign_unplace(sign_group, { buffer = bufnr })
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.apply(bufnr, hunks)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M.clear(bufnr)

  local opts = config.get()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    line_count = 1
  end

  for _, hunk in ipairs(hunks) do
    if hunk.type == "add" then
      for lnum = hunk.start_new, hunk.start_new + hunk.count_new - 1 do
        if lnum >= 1 and lnum <= line_count then
          place_sign("add", bufnr, lnum)
          if opts.live.line_highlight then
            add_line_highlight(bufnr, lnum, "GitDxLineAdd")
          end
        end
      end
    elseif hunk.type == "change" then
      for lnum = hunk.start_new, hunk.start_new + hunk.count_new - 1 do
        if lnum >= 1 and lnum <= line_count then
          place_sign("change", bufnr, lnum)
          if opts.live.line_highlight then
            add_line_highlight(bufnr, lnum, "GitDxLineChange")
          end
        end
      end
    elseif hunk.type == "delete" then
      local anchor = hunk.start_new
      if anchor < 1 then
        anchor = 1
      elseif anchor > line_count then
        anchor = line_count
      end

      place_sign("delete", bufnr, anchor)
      if opts.live.show_deleted_count then
        add_deleted_virtual_hint(bufnr, anchor, hunk.count_old)
      end
    end
  end
end

return M
