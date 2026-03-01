local config = require("gitdx.config")
local git = require("gitdx.git")
local signs = require("gitdx.signs")
local util = require("gitdx.util")

local M = {}

local state = {
  enabled = false,
  global_augroup = nil,
  buffers = {},
  windows = {},
}

local function resolve_bufnr(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  return bufnr
end

local function is_eligible(bufnr)
  if not util.is_regular_buffer(bufnr) then
    return false
  end

  local max_file_lines = config.get().live.max_file_lines
  if max_file_lines and max_file_lines > 0 then
    if vim.api.nvim_buf_line_count(bufnr) > max_file_lines then
      return false
    end
  end

  return true
end

local function ensure_window_state(win)
  local item = state.windows[win]
  if item then
    return item
  end

  item = {}
  state.windows[win] = item
  return item
end

local function restore_window_option(win, field)
  local win_state = state.windows[win]
  if not win_state or win_state[field] == nil then
    return
  end

  if not vim.api.nvim_win_is_valid(win) then
    state.windows[win] = nil
    return
  end

  vim.wo[win][field] = win_state[field]
  win_state[field] = nil
  if win_state.signcolumn == nil and win_state.winbar == nil then
    state.windows[win] = nil
  end
end

local function build_stats(hunks)
  local stats = {
    added = 0,
    changed = 0,
    deleted = 0,
  }

  for _, hunk in ipairs(hunks) do
    if hunk.type == "add" then
      stats.added = stats.added + hunk.count_new
    elseif hunk.type == "change" then
      stats.changed = stats.changed + hunk.count_new
    elseif hunk.type == "delete" then
      stats.deleted = stats.deleted + hunk.count_old
    end
  end

  return stats
end

local function build_winbar_label(stats)
  return string.format("%%#GitDxDirtyBadge#GitDx +%d ~%d -%d%%*", stats.added, stats.changed, stats.deleted)
end

local function strip_gitdx_winbar_label(winbar)
  if type(winbar) ~= "string" or winbar == "" then
    return ""
  end

  local cleaned = winbar
  local marker = "%#GitDxDirtyBadge#GitDx "

  while true do
    local from = cleaned:find(marker, 1, true)
    if not from then
      break
    end

    local to = cleaned:find("%*", from, true)
    if not to then
      break
    end

    cleaned = cleaned:sub(1, from - 1) .. cleaned:sub(to + 2)
  end

  cleaned = cleaned:gsub("^%s*%%=%s*", "")
  cleaned = cleaned:gsub("%s*%%=%s*$", "")
  return util.trim(cleaned)
end

local function apply_window_decoration(win, bufnr)
  if not vim.api.nvim_win_is_valid(win) then
    state.windows[win] = nil
    return
  end

  local live_opts = config.get().live
  local in_diff_window = vim.wo[win].diff == true
  local buf_state = state.buffers[bufnr]
  local has_attached = state.enabled and buf_state ~= nil
  local has_git_context = has_attached and buf_state.git_in_repo == true

  if not has_git_context then
    restore_window_option(win, "signcolumn")
    restore_window_option(win, "winbar")
    return
  end

  if live_opts.stable_signcolumn and live_opts.show_signs then
    local win_state = ensure_window_state(win)
    if win_state.signcolumn == nil then
      win_state.signcolumn = vim.wo[win].signcolumn
    end
    vim.wo[win].signcolumn = live_opts.stable_signcolumn_value
  else
    restore_window_option(win, "signcolumn")
  end

  if live_opts.winbar_summary and not in_diff_window then
    local win_state = ensure_window_state(win)
    if win_state.winbar == nil then
      win_state.winbar = strip_gitdx_winbar_label(vim.wo[win].winbar or "")
    end

    local original = win_state.winbar or ""
    local label = build_winbar_label(buf_state.stats or { added = 0, changed = 0, deleted = 0 })
    if original == "" then
      vim.wo[win].winbar = label
    else
      vim.wo[win].winbar = string.format("%s %%=%s", original, label)
    end
  else
    if has_git_context and in_diff_window then
      local win_state = ensure_window_state(win)
      if win_state.winbar == nil then
        win_state.winbar = strip_gitdx_winbar_label(vim.wo[win].winbar or "")
      end
    end
    restore_window_option(win, "winbar")
  end
end

local function sync_windows_for_buffer(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    apply_window_decoration(win, bufnr)
  end
end

local function sync_all_windows()
  local seen = {}

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    apply_window_decoration(win, bufnr)
    seen[win] = true
  end

  for win, _ in pairs(state.windows) do
    if not seen[win] then
      state.windows[win] = nil
    end
  end
end

local function refresh_now(bufnr, force)
  bufnr = resolve_bufnr(bufnr)

  local item = state.buffers[bufnr]
  if not is_eligible(bufnr) then
    signs.clear(bufnr)
    if item then
      item.stats = { added = 0, changed = 0, deleted = 0 }
      item.git_in_repo = false
      sync_windows_for_buffer(bufnr)
    end
    return
  end

  if item then
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    if not force and item.last_tick == changedtick then
      return
    end
    item.last_tick = changedtick
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local base = git.get_base(path, config.get().ref)
  if not base then
    signs.clear(bufnr)
    if item then
      item.stats = { added = 0, changed = 0, deleted = 0 }
      item.git_in_repo = false
      sync_windows_for_buffer(bufnr)
    end
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = git.compute_hunks(base.lines, lines)
  signs.apply(bufnr, hunks)

  if item then
    item.stats = build_stats(hunks)
    item.git_in_repo = true
    sync_windows_for_buffer(bufnr)
  end
end

local function setup_buffer_autocmds(bufnr, item)
  for _, event in ipairs(config.get().live.update_events) do
    vim.api.nvim_create_autocmd(event, {
      group = item.group,
      buffer = bufnr,
      callback = function()
        item.debounced_refresh()
      end,
    })
  end

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = item.group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })
end

function M.attach(bufnr)
  bufnr = resolve_bufnr(bufnr)

  if not state.enabled then
    return
  end

  if state.buffers[bufnr] then
    return
  end

  if not is_eligible(bufnr) then
    return
  end

  local group = vim.api.nvim_create_augroup(string.format("GitDxBuffer_%d", bufnr), { clear = true })
  local debounced_refresh, stop_debounce = util.debounce(function()
    refresh_now(bufnr, false)
  end, config.get().live.debounce_ms)

  local item = {
    group = group,
    debounced_refresh = debounced_refresh,
    stop_debounce = stop_debounce,
    last_tick = nil,
    stats = { added = 0, changed = 0, deleted = 0 },
    git_in_repo = false,
  }

  state.buffers[bufnr] = item
  setup_buffer_autocmds(bufnr, item)
  sync_windows_for_buffer(bufnr)
  refresh_now(bufnr, true)
end

function M.detach(bufnr)
  bufnr = resolve_bufnr(bufnr)

  local item = state.buffers[bufnr]
  if not item then
    return
  end

  if item.stop_debounce then
    item.stop_debounce()
  end

  if item.group then
    pcall(vim.api.nvim_del_augroup_by_id, item.group)
  end

  signs.clear(bufnr)
  state.buffers[bufnr] = nil
  sync_all_windows()
end

function M.refresh(bufnr, force)
  refresh_now(resolve_bufnr(bufnr), force == nil and true or force)
end

function M.refresh_all(force)
  local should_force = force == nil and true or force
  for bufnr, _ in pairs(state.buffers) do
    refresh_now(bufnr, should_force)
  end
end

function M.enable()
  if state.enabled then
    return
  end

  state.enabled = true
  state.global_augroup = vim.api.nvim_create_augroup("GitDxGlobal", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufEnter" }, {
    group = state.global_augroup,
    callback = function(args)
      M.attach(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinNew", "TabEnter" }, {
    group = state.global_augroup,
    callback = function()
      sync_all_windows()
    end,
  })

  vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost", "DirChanged" }, {
    group = state.global_augroup,
    callback = function()
      M.refresh_all(true)
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    M.attach(bufnr)
  end

  sync_all_windows()
end

function M.disable()
  if not state.enabled then
    return
  end

  if state.global_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.global_augroup)
    state.global_augroup = nil
  end

  local attached = {}
  for bufnr, _ in pairs(state.buffers) do
    table.insert(attached, bufnr)
  end

  for _, bufnr in ipairs(attached) do
    M.detach(bufnr)
  end

  state.enabled = false
  sync_all_windows()
end

function M.reconfigure()
  local should_enable = config.get().live.enabled
  M.disable()
  if should_enable then
    M.enable()
  else
    sync_all_windows()
  end
end

function M.toggle()
  if state.enabled then
    M.disable()
    return false
  end

  M.enable()
  return true
end

function M.is_enabled()
  return state.enabled
end

function M.set_signs_visible(enabled)
  local opts = config.get()
  opts.live.show_signs = enabled and true or false

  if state.enabled then
    M.refresh_all(true)
    sync_all_windows()
  end

  return opts.live.show_signs
end

function M.toggle_signs_visible()
  return M.set_signs_visible(not config.get().live.show_signs)
end

function M.are_signs_visible()
  return config.get().live.show_signs
end

function M.set_winbar_summary(enabled)
  local opts = config.get()
  opts.live.winbar_summary = enabled and true or false
  sync_all_windows()
  return opts.live.winbar_summary
end

function M.toggle_winbar_summary()
  return M.set_winbar_summary(not config.get().live.winbar_summary)
end

function M.is_winbar_summary_enabled()
  return config.get().live.winbar_summary
end

function M.sync_windows()
  sync_all_windows()
end

return M
