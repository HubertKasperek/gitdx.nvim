local config = require("gitdx.config")
local conflicts = require("gitdx.conflicts")
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
  open_style = nil,
  previous_bufnr = nil,
  previous_winfixbuf = nil,
  lock_group = nil,
  allow_window_replace = false,
  lock_guard = false,
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
  state.open_style = nil
  state.previous_bufnr = nil
  state.previous_winfixbuf = nil
  if state.lock_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.lock_group)
    state.lock_group = nil
  end
  state.allow_window_replace = false
  state.lock_guard = false
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

  if status == "U" then
    return "GitDxPanelStatusConflict"
  end

  return "GitDxPanelStatusChange"
end

local function sum_changes(entries)
  local summary = {
    A = 0,
    M = 0,
    D = 0,
    R = 0,
    U = 0,
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
    if entry.status == "U" then
      line = string.format("%s  [conflict]", line)
    end
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
  if panel_is_open() and state.repo_root then
    return state.repo_root
  end

  local buf = vim.api.nvim_get_current_buf()
  if util.is_regular_buffer(buf) then
    return vim.api.nvim_buf_get_name(buf)
  end

  return vim.fn.getcwd()
end

local function restore_locked_panel_window()
  if state.open_style ~= "current" then
    return
  end

  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  vim.wo[state.winid].winfixbuf = state.previous_winfixbuf == true
end

local function enforce_panel_window_buffer()
  if state.lock_guard or state.allow_window_replace then
    return
  end

  if not panel_is_open() then
    return
  end

  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    clear_state()
    return
  end

  local shown_buf = vim.api.nvim_win_get_buf(state.winid)
  if shown_buf == state.bufnr then
    return
  end

  state.lock_guard = true
  local previous_lock = vim.wo[state.winid].winfixbuf == true
  vim.wo[state.winid].winfixbuf = false
  pcall(vim.api.nvim_win_set_buf, state.winid, state.bufnr)
  vim.wo[state.winid].winfixbuf = previous_lock
  state.lock_guard = false

  util.notify("GitDx panel window is locked. Use q to close panel first.", vim.log.levels.WARN)
end

local function run_with_unlocked_panel_window(callback)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return pcall(callback)
  end

  local win = state.winid
  local was_locked = vim.wo[win].winfixbuf == true

  if was_locked then
    vim.wo[win].winfixbuf = false
  end

  local previous_allow = state.allow_window_replace
  state.allow_window_replace = true
  local ok, err = pcall(callback)
  state.allow_window_replace = previous_allow

  local should_relock = was_locked
    and state.bufnr
    and vim.api.nvim_buf_is_valid(state.bufnr)
    and state.winid
    and vim.api.nvim_win_is_valid(state.winid)
    and vim.api.nvim_win_get_buf(state.winid) == state.bufnr

  if should_relock then
    vim.wo[state.winid].winfixbuf = true
  end

  return ok, err
end

local function close_panel_window()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
    end
    return
  end

  if state.open_style == "current" then
    local win = state.winid
    local panel_buf = state.bufnr
    local previous_buf = state.previous_bufnr

    vim.wo[win].winfixbuf = false

    if previous_buf and vim.api.nvim_buf_is_valid(previous_buf) then
      pcall(vim.api.nvim_win_set_buf, win, previous_buf)
    else
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("enew")
      end)
    end

    restore_locked_panel_window()

    if panel_buf and vim.api.nvim_buf_is_valid(panel_buf) then
      pcall(vim.api.nvim_buf_delete, panel_buf, { force = true })
    end
    return
  end

  pcall(vim.api.nvim_win_close, state.winid, true)
end

function M.close()
  state.allow_window_replace = true
  close_panel_window()
  clear_state()
end

local function open_current_entry_at_mouse()
  if not panel_is_open() then
    return
  end

  local mouse = vim.fn.getmousepos()
  if not mouse or tonumber(mouse.winid) ~= state.winid then
    return
  end

  local line = math.max(1, tonumber(mouse.line) or 1)
  local col = math.max(0, (tonumber(mouse.column) or 1) - 1)

  pcall(vim.api.nvim_set_current_win, state.winid)
  pcall(vim.api.nvim_win_set_cursor, state.winid, { line, col })
  M.open_current_entry()
end

local function ensure_panel(open_style)
  open_style = open_style == "current" and "current" or "split"

  if panel_is_open() then
    return state.bufnr, state.winid
  end

  local win
  local previous_bufnr = nil
  local previous_winfixbuf = nil

  if open_style == "current" then
    win = vim.api.nvim_get_current_win()
    previous_bufnr = vim.api.nvim_win_get_buf(win)
    previous_winfixbuf = vim.wo[win].winfixbuf == true
  else
    local panel_opts = config.get().panel
    local cmd
    if panel_opts.split == "right" then
      cmd = string.format("botright vertical %dnew", panel_opts.width)
    else
      cmd = string.format("topleft vertical %dnew", panel_opts.width)
    end

    vim.cmd(cmd)
    win = vim.api.nvim_get_current_win()
  end

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
  vim.wo[win].winfixwidth = open_style == "split"
  vim.wo[win].winfixbuf = true

  vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true, desc = "GitDx panel close" })
  vim.keymap.set("n", "r", M.refresh, { buffer = buf, silent = true, desc = "GitDx panel refresh" })
  vim.keymap.set("n", "<CR>", function()
    M.open_current_entry()
  end, { buffer = buf, silent = true, desc = "GitDx panel open diff" })
  vim.keymap.set("n", "<LeftMouse>", open_current_entry_at_mouse, {
    buffer = buf,
    silent = true,
    desc = "GitDx panel open diff under mouse",
  })
  vim.keymap.set("n", "<2-LeftMouse>", open_current_entry_at_mouse, {
    buffer = buf,
    silent = true,
    desc = "GitDx panel open diff under mouse",
  })
  for _, name in ipairs({ "Ex", "Explore" }) do
    pcall(vim.api.nvim_buf_create_user_command, buf, name, function()
      util.notify(":" .. name .. " is disabled in GitDx panel. Use q to close panel first.", vim.log.levels.WARN)
    end, {
      desc = "GitDx panel command lock",
    })
  end

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    callback = function()
      restore_locked_panel_window()
      clear_state()
    end,
  })

  state.bufnr = buf
  state.winid = win
  state.open_style = open_style
  state.previous_bufnr = previous_bufnr
  state.previous_winfixbuf = previous_winfixbuf
  state.lock_group = vim.api.nvim_create_augroup(string.format("GitDxPanelLock_%d", buf), { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = state.lock_group,
    callback = function()
      enforce_panel_window_buffer()
    end,
  })

  return buf, win
end

local function render(data, open_style)
  local buf, win = ensure_panel(open_style)
  state.repo_root = data.repo_root

  local summary = sum_changes(data.entries)
  local root_display = vim.fn.fnamemodify(data.repo_root, ":~")
  local header = {
    string.format("GitDx Changes  %s", root_display),
    string.format("A:%d  M:%d  D:%d  R:%d  U:%d", summary.A, summary.M, summary.D, summary.R, summary.U),
    "Enter/Click: diff (or conflict)    r: refresh    q: close",
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

function M.refresh(opts)
  opts = opts or {}
  local open_style = opts.open_style or state.open_style or "split"
  local data, err = git.list_changes(panel_path())
  if not data then
    util.notify(err or "Unable to load repository status", vim.log.levels.ERROR)
    return
  end

  render(data, open_style)
end

function M.open(opts)
  opts = opts or {}
  local open_style = opts.open_style or "split"

  if diffview.is_active() then
    util.notify(
      "GitDx panel is unavailable during an active GitDxDiff view. Close diff first with :GitDxDiffClose.",
      vim.log.levels.WARN
    )
    return
  end

  if panel_is_open() and state.open_style ~= open_style then
    M.close()
  end

  if panel_is_open() then
    M.refresh()
    if vim.api.nvim_win_is_valid(state.winid) then
      vim.api.nvim_set_current_win(state.winid)
    end
    return
  end

  M.refresh({ open_style = open_style })
end

function M.open_in_current_window()
  M.open({ open_style = "current" })
end

function M.is_open()
  return panel_is_open()
end

local function open_conflict_entry(entry)
  if not entry.abs_path or entry.abs_path == "" then
    util.notify("Conflict entry has no path", vim.log.levels.WARN)
    return
  end

  local escaped = vim.fn.fnameescape(entry.abs_path)
  local ok_open, open_err = pcall(vim.cmd, "tabedit " .. escaped)
  if not ok_open then
    util.notify("Unable to open conflict file (" .. tostring(open_err) .. ")", vim.log.levels.ERROR)
    return
  end

  local ranges, err = conflicts.get_buffer_ranges(0)
  if not ranges then
    util.notify(err or "Unable to inspect conflict markers", vim.log.levels.WARN)
    return
  end

  if #ranges == 0 then
    util.notify("Conflict file has no unresolved markers", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_win_set_cursor(0, { ranges[1].start_line, 0 })
  util.notify(string.format("Opened conflict file (%d conflict blocks)", #ranges))
end

local function open_diff_entry(entry)
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

function M.open_current_entry()
  if not panel_is_open() then
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
  local entry = state.line_map[lnum]
  if not entry then
    return
  end

  local ok, err = run_with_unlocked_panel_window(function()
    if entry.status == "U" then
      open_conflict_entry(entry)
      return
    end

    open_diff_entry(entry)
  end)

  if not ok then
    util.notify("Unable to open selected entry (" .. tostring(err) .. ")", vim.log.levels.ERROR)
  end
end

return M
