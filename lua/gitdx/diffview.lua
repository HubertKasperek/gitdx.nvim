local config = require("gitdx.config")
local git = require("gitdx.git")
local util = require("gitdx.util")

local M = {}

local function source_file_display_name(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function to_abs_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function infer_filetype(path)
  if not vim.filetype or not vim.filetype.match then
    return nil
  end

  local ok, filetype = pcall(vim.filetype.match, { filename = path })
  if not ok then
    return nil
  end

  return filetype
end

local function create_left_buffer(source_buf, base_lines, ref)
  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_name = string.format("%s [%s]", source_file_display_name(source_name), ref)

  pcall(vim.api.nvim_buf_set_name, left_buf, left_name)

  local lines = base_lines
  if #lines == 0 then
    lines = { "" }
  end

  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].undofile = false
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true

  local filetype = vim.bo[source_buf].filetype
  if filetype and filetype ~= "" then
    vim.bo[left_buf].filetype = filetype
  end

  vim.b[left_buf].gitdx_diff_base = true

  return left_buf
end

local function create_deleted_source_buffer(source_path)
  local source_buf = vim.api.nvim_create_buf(false, true)
  local display_name = string.format("%s [working tree deleted]", source_file_display_name(source_path))

  pcall(vim.api.nvim_buf_set_name, source_buf, display_name)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "" })
  vim.bo[source_buf].buftype = "nofile"
  vim.bo[source_buf].bufhidden = "wipe"
  vim.bo[source_buf].swapfile = false
  vim.bo[source_buf].undofile = false
  vim.bo[source_buf].modifiable = false
  vim.bo[source_buf].readonly = true

  local inferred = infer_filetype(source_path)
  if inferred and inferred ~= "" then
    vim.bo[source_buf].filetype = inferred
  end

  vim.b[source_buf].gitdx_diff_ephemeral = true

  return source_buf
end

local function resolve_source(opts)
  if opts.path then
    local source_path = to_abs_path(opts.path)
    if opts.deleted then
      return create_deleted_source_buffer(source_path), source_path, nil, { 1, 0 }
    end

    local source_buf = vim.fn.bufnr(source_path, false)
    if source_buf < 0 then
      source_buf = vim.fn.bufadd(source_path)
      pcall(vim.fn.bufload, source_buf)
    end

    return source_buf, source_path, nil, { 1, 0 }
  end

  local source_buf = vim.api.nvim_get_current_buf()
  if not util.is_regular_buffer(source_buf) then
    return nil, nil, "Current buffer is not a file on disk"
  end

  local source_path = vim.api.nvim_buf_get_name(source_buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return source_buf, source_path, nil, cursor
end

local function apply_diff_window_style(win)
  local win_cfg = config.get().diffview
  vim.wo[win].diff = true
  vim.wo[win].scrollbind = true
  vim.wo[win].cursorbind = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = win_cfg.winhighlight
end

function M.open(opts)
  opts = opts or {}
  local source_buf, source_path, err, cursor = resolve_source(opts)
  if not source_buf then
    util.notify(err or "Unable to resolve source buffer", vim.log.levels.WARN)
    return
  end

  local ref = opts.ref or config.get().ref
  local base_path = opts.base_path and to_abs_path(opts.base_path) or source_path

  local base, err = git.get_base(base_path, ref, {
    force_ref_read = opts.base_path ~= nil,
  })
  if not base then
    util.notify(err or "Unable to open diff view", vim.log.levels.ERROR)
    return
  end

  if config.get().diffview.open_in_tab then
    vim.cmd("tabnew")
  end

  local left_win = vim.api.nvim_get_current_win()
  local left_buf = create_left_buffer(source_buf, base.lines, ref)
  vim.api.nvim_win_set_buf(left_win, left_buf)

  vim.cmd("vsplit")

  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, source_buf)
  vim.api.nvim_win_set_cursor(right_win, cursor)

  vim.b[source_buf].gitdx_diff_source = true

  apply_diff_window_style(left_win)
  apply_diff_window_style(right_win)

  if config.get().diffview.keep_focus == "left" then
    vim.api.nvim_set_current_win(left_win)
  else
    vim.api.nvim_set_current_win(right_win)
  end
end

function M.close()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local has_diff = false

  for _, win in ipairs(wins) do
    if vim.wo[win].diff then
      has_diff = true
      break
    end
  end

  if not has_diff then
    util.notify("No active diff windows in current tab", vim.log.levels.WARN)
    return
  end

  vim.cmd("diffoff!")

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local is_gitdx_tmp = vim.b[buf] and (vim.b[buf].gitdx_diff_base or vim.b[buf].gitdx_diff_ephemeral)
    if is_gitdx_tmp and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

return M
