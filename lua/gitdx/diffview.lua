local config = require("gitdx.config")
local git = require("gitdx.git")
local util = require("gitdx.util")

local M = {}
local sync_session_seq = 0
local horizontal_sync_guard = false

local HORIZONTAL_SYNC_SESSION_VAR = "gitdx_diff_sync_session"
local HORIZONTAL_SYNC_PEER_VAR = "gitdx_diff_peer_win"
local PREV_WINHIGHLIGHT_VAR = "gitdx_diff_prev_winhighlight"

local function sync_live_window_decorations()
  local ok, live = pcall(require, "gitdx.live")
  if not ok or not live or type(live.sync_windows) ~= "function" then
    return
  end

  pcall(live.sync_windows)
end

local function get_tab_var(tabpage, name)
  local ok, value = pcall(vim.api.nvim_tabpage_get_var, tabpage, name)
  if not ok then
    return nil
  end

  return value
end

local function set_tab_var(tabpage, name, value)
  pcall(vim.api.nvim_tabpage_set_var, tabpage, name, value)
end

local function get_win_var(win, name)
  local ok, value = pcall(vim.api.nvim_win_get_var, win, name)
  if not ok then
    return nil
  end

  return value
end

local function set_win_var(win, name, value)
  pcall(vim.api.nvim_win_set_var, win, name, value)
end

local function del_win_var(win, name)
  pcall(vim.api.nvim_win_del_var, win, name)
end

local function restore_winhighlight(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local prev = get_win_var(win, PREV_WINHIGHLIGHT_VAR)
  if prev == nil then
    return
  end

  vim.wo[win].winhighlight = prev
  del_win_var(win, PREV_WINHIGHLIGHT_VAR)
end

local function get_window_leftcol(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
end

local function set_window_leftcol(win, leftcol)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    if view.leftcol ~= leftcol then
      view.leftcol = leftcol
      vim.fn.winrestview(view)
    end
  end)
end

local function clear_horizontal_sync_for_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  del_win_var(win, HORIZONTAL_SYNC_SESSION_VAR)
  del_win_var(win, HORIZONTAL_SYNC_PEER_VAR)
end

local function sync_horizontal_from_window(win)
  if config.get().diffview.sync_scroll == false then
    return
  end

  if horizontal_sync_guard then
    return
  end

  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local session = get_win_var(win, HORIZONTAL_SYNC_SESSION_VAR)
  if type(session) ~= "number" then
    return
  end

  local peer_win = get_win_var(win, HORIZONTAL_SYNC_PEER_VAR)
  if type(peer_win) ~= "number" or not vim.api.nvim_win_is_valid(peer_win) then
    return
  end

  if get_win_var(peer_win, HORIZONTAL_SYNC_SESSION_VAR) ~= session then
    return
  end

  local source_leftcol = get_window_leftcol(win)
  local peer_leftcol = get_window_leftcol(peer_win)
  if source_leftcol == nil or peer_leftcol == nil or source_leftcol == peer_leftcol then
    return
  end

  horizontal_sync_guard = true
  local ok = pcall(set_window_leftcol, peer_win, source_leftcol)
  horizontal_sync_guard = false

  if not ok then
    clear_horizontal_sync_for_window(win)
    clear_horizontal_sync_for_window(peer_win)
  end
end

local function register_horizontal_sync(left_win, right_win)
  if config.get().diffview.sync_scroll == false then
    clear_horizontal_sync_for_window(left_win)
    clear_horizontal_sync_for_window(right_win)
    return
  end

  sync_session_seq = sync_session_seq + 1
  local session = sync_session_seq

  set_win_var(left_win, HORIZONTAL_SYNC_SESSION_VAR, session)
  set_win_var(right_win, HORIZONTAL_SYNC_SESSION_VAR, session)
  set_win_var(left_win, HORIZONTAL_SYNC_PEER_VAR, right_win)
  set_win_var(right_win, HORIZONTAL_SYNC_PEER_VAR, left_win)

  local right_leftcol = get_window_leftcol(right_win)
  if right_leftcol ~= nil then
    pcall(set_window_leftcol, left_win, right_leftcol)
  end
end

local horizontal_sync_group = vim.api.nvim_create_augroup("gitdx_diffview_horizontal_sync", { clear = true })

vim.api.nvim_create_autocmd("WinScrolled", {
  group = horizontal_sync_group,
  callback = function()
    if config.get().diffview.sync_scroll == false then
      return
    end

    local event = vim.v.event
    local seen = {}

    if type(event) == "table" then
      for key, _ in pairs(event) do
        if key ~= "all" then
          local win = tonumber(key)
          if win and win > 0 and not seen[win] then
            seen[win] = true
            sync_horizontal_from_window(win)
          end
        end
      end
    end

    if next(seen) == nil then
      sync_horizontal_from_window(vim.api.nvim_get_current_win())
    end
  end,
})

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
  local sync_scroll = win_cfg.sync_scroll ~= false
  if get_win_var(win, PREV_WINHIGHLIGHT_VAR) == nil then
    set_win_var(win, PREV_WINHIGHLIGHT_VAR, vim.wo[win].winhighlight or "")
  end

  vim.wo[win].diff = true
  vim.wo[win].scrollbind = sync_scroll
  vim.wo[win].cursorbind = sync_scroll
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = win_cfg.winhighlight
end

local function tab_has_active_diff(tabpage)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      return true
    end
  end

  return false
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

  local opened_diff_tab = false
  if config.get().diffview.open_in_tab then
    vim.cmd("tabnew")
    opened_diff_tab = true
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  set_tab_var(current_tab, "gitdx_diff_owned_tab", opened_diff_tab)

  local left_win = vim.api.nvim_get_current_win()
  local left_buf = create_left_buffer(source_buf, base.lines, ref)
  vim.api.nvim_win_set_buf(left_win, left_buf)

  -- Keep semantic layout stable: base on the left, working tree on the right,
  -- regardless of user 'splitright' setting.
  vim.cmd("rightbelow vsplit")

  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, source_buf)
  vim.api.nvim_win_set_cursor(right_win, cursor)

  vim.b[source_buf].gitdx_diff_source = true

  apply_diff_window_style(left_win)
  apply_diff_window_style(right_win)
  register_horizontal_sync(left_win, right_win)

  if config.get().diffview.keep_focus == "left" then
    vim.api.nvim_set_current_win(left_win)
  else
    vim.api.nvim_set_current_win(right_win)
  end

  sync_live_window_decorations()
end

function M.is_active(tabpage)
  local target_tab = tabpage
  if not target_tab or target_tab == 0 then
    target_tab = vim.api.nvim_get_current_tabpage()
  end

  if not vim.api.nvim_tabpage_is_valid(target_tab) then
    return false
  end

  return tab_has_active_diff(target_tab)
end

function M.close()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local owns_tab = get_tab_var(current_tab, "gitdx_diff_owned_tab") == true

  if owns_tab then
    local ok, err = pcall(vim.cmd, "tabclose")
    if ok then
      return
    end

    util.notify(
      "Unable to close GitDx diff tab; closing diff windows instead (" .. tostring(err) .. ")",
      vim.log.levels.WARN
    )
  end

  local wins = vim.api.nvim_tabpage_list_wins(0)
  if not tab_has_active_diff(current_tab) then
    util.notify("No active diff windows in current tab", vim.log.levels.WARN)
    return
  end

  for _, win in ipairs(wins) do
    clear_horizontal_sync_for_window(win)
  end

  vim.cmd("diffoff!")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    restore_winhighlight(win)
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local is_gitdx_tmp = vim.b[buf] and (vim.b[buf].gitdx_diff_base or vim.b[buf].gitdx_diff_ephemeral)
    if is_gitdx_tmp and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  sync_live_window_decorations()
end

return M
