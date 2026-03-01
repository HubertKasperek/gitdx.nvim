local config = require("gitdx.config")
local diffview = require("gitdx.diffview")
local git = require("gitdx.git")
local util = require("gitdx.util")

local M = {}

local namespace = vim.api.nvim_create_namespace("gitdx_panel")
local state = {
  bufnr = nil,
  winid = nil,
  repo_root = nil,
  line_map = {},
}

local function panel_is_open()
  return state.bufnr
    and vim.api.nvim_buf_is_valid(state.bufnr)
    and state.winid
    and vim.api.nvim_win_is_valid(state.winid)
end

local function clear_state()
  state.bufnr = nil
  state.winid = nil
  state.repo_root = nil
  state.line_map = {}
end

local function status_group(status)
  if status == "A" then
    return "GitDxPanelStatusAdd"
  end

  if status == "D" then
    return "GitDxPanelStatusDelete"
  end

  if status == "R" then
    return "GitDxPanelStatusRename"
  end

  return "GitDxPanelStatusChange"
end

local function sum_changes(entries)
  local summary = {
    A = 0,
    M = 0,
    D = 0,
    R = 0,
  }

  for _, entry in ipairs(entries) do
    summary[entry.status] = (summary[entry.status] or 0) + 1
  end

  return summary
end

local function common_prefix_len(a, b)
  local len = math.min(#a, #b)
  local i = 1
  while i <= len and a[i] == b[i] do
    i = i + 1
  end
  return i - 1
end

local function render_entries(entries)
  local lines = {}
  local highlights = {}
  local line_map = {}
  local path_hl = "GitDxPanelPath"
  local current_dirs = {}

  for _, entry in ipairs(entries) do
    local parts = vim.split(entry.path, "/", { plain = true })
    local filename = parts[#parts]
    local dirs = {}
    for i = 1, #parts - 1 do
      table.insert(dirs, parts[i])
    end

    local shared = common_prefix_len(current_dirs, dirs)
    for i = shared + 1, #dirs do
      local indent = string.rep("  ", i - 1)
      table.insert(lines, indent .. dirs[i] .. "/")
      table.insert(highlights, {
        lnum = #lines - 1,
        col_start = 0,
        col_end = -1,
        group = path_hl,
      })
    end
    current_dirs = dirs

    local file_indent = string.rep("  ", #dirs)
    local line = string.format("%s%s %s", file_indent, entry.status, filename)
    if entry.status == "R" and entry.old_path and entry.old_path ~= "" then
      line = string.format("%s  <- %s", line, entry.old_path)
    end
    table.insert(lines, line)
    line_map[#lines] = entry

    table.insert(highlights, {
      lnum = #lines - 1,
      col_start = #file_indent,
      col_end = #file_indent + 1,
      group = status_group(entry.status),
    })

    if entry.status == "R" and entry.old_path and entry.old_path ~= "" then
      local path_col = #file_indent + 2 + #filename + 6
      table.insert(highlights, {
        lnum = #lines - 1,
        col_start = path_col,
        col_end = -1,
        group = path_hl,
      })
    end
  end

  return lines, highlights, line_map
end

local function panel_path()
  local buf = vim.api.nvim_get_current_buf()
  if util.is_regular_buffer(buf) then
    return vim.api.nvim_buf_get_name(buf)
  end

  return vim.fn.getcwd()
end

local function close_panel_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
end

function M.close()
  close_panel_window()
  clear_state()
end

local function ensure_panel()
  if panel_is_open() then
    return state.bufnr, state.winid
  end

  local panel_opts = config.get().panel
  local cmd
  if panel_opts.split == "right" then
    cmd = string.format("botright vertical %dnew", panel_opts.width)
  else
    cmd = string.format("topleft vertical %dnew", panel_opts.width)
  end

  vim.cmd(cmd)

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "gitdx-panel"

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true

  vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true, desc = "GitDx panel close" })
  vim.keymap.set("n", "r", M.refresh, { buffer = buf, silent = true, desc = "GitDx panel refresh" })
  vim.keymap.set("n", "<CR>", function()
    M.open_current_entry()
  end, { buffer = buf, silent = true, desc = "GitDx panel open diff" })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    callback = function()
      clear_state()
    end,
  })

  state.bufnr = buf
  state.winid = win

  return buf, win
end

local function render(data)
  local buf, win = ensure_panel()
  state.repo_root = data.repo_root

  local summary = sum_changes(data.entries)
  local root_display = vim.fn.fnamemodify(data.repo_root, ":~")
  local header = {
    string.format("GitDx Changes  %s", root_display),
    string.format("A:%d  M:%d  D:%d  R:%d", summary.A, summary.M, summary.D, summary.R),
    "Enter: diff    r: refresh    q: close",
    "",
  }

  local body, body_hl, line_map = render_entries(data.entries)
  if #body == 0 then
    body = { "Working tree clean" }
    body_hl = {
      {
        lnum = 0,
        col_start = 0,
        col_end = -1,
        group = "GitDxPanelHint",
      },
    }
  end

  local lines = vim.list_extend(vim.deepcopy(header), body)
  state.line_map = {}

  for line, entry in pairs(line_map) do
    state.line_map[line + #header] = entry
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "GitDxPanelTitle", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "GitDxPanelHint", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "GitDxPanelHint", 2, 0, -1)

  for _, hl in ipairs(body_hl) do
    vim.api.nvim_buf_add_highlight(
      buf,
      namespace,
      hl.group,
      hl.lnum + #header,
      hl.col_start,
      hl.col_end
    )
  end

  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

function M.refresh()
  local data, err = git.list_changes(panel_path())
  if not data then
    util.notify(err or "Unable to load repository status", vim.log.levels.ERROR)
    return
  end

  render(data)
end

function M.open()
  if panel_is_open() then
    M.refresh()
    if vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end

  M.refresh()
end

function M.is_open()
  return panel_is_open()
end

function M.open_current_entry()
  if not panel_is_open() then
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
  local entry = state.line_map[lnum]
  if not entry then
    return
  end

  if entry.status == "D" then
    diffview.open({
      path = entry.abs_path,
      deleted = true,
    })
    return
  end

  local opts = {
    path = entry.abs_path,
  }

  if entry.status == "R" and entry.old_path and state.repo_root then
    opts.base_path = state.repo_root .. "/" .. entry.old_path
  end

  diffview.open(opts)
end

return M
