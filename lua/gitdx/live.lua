local config = require("gitdx.config")
local git = require("gitdx.git")
local signs = require("gitdx.signs")
local util = require("gitdx.util")

local M = {}

local state = {
  enabled = false,
  global_augroup = nil,
  buffers = {},
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

local function refresh_now(bufnr, force)
  bufnr = resolve_bufnr(bufnr)

  if not is_eligible(bufnr) then
    signs.clear(bufnr)
    return
  end

  local item = state.buffers[bufnr]
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
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = git.compute_hunks(base.lines, lines)
  signs.apply(bufnr, hunks)
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
  }

  state.buffers[bufnr] = item
  setup_buffer_autocmds(bufnr, item)
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

  vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost", "DirChanged" }, {
    group = state.global_augroup,
    callback = function()
      M.refresh_all(true)
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    M.attach(bufnr)
  end
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
end

function M.reconfigure()
  local should_enable = config.get().live.enabled
  M.disable()
  if should_enable then
    M.enable()
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

return M
