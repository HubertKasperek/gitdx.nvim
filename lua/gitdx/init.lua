local config = require("gitdx.config")
local conflicts = require("gitdx.conflicts")
local diffview = require("gitdx.diffview")
local highlights = require("gitdx.highlights")
local live = require("gitdx.live")
local panel = require("gitdx.panel")
local signs = require("gitdx.signs")
local util = require("gitdx.util")

local M = {}

local setup_done = false
local commands_registered = false

local function ensure_setup()
  if not setup_done then
    M.setup()
  end
end

local function format_range(start_line, count)
  if type(start_line) ~= "number" or type(count) ~= "number" or count <= 0 then
    return "-"
  end

  local finish = start_line + count - 1
  if finish <= start_line then
    return tostring(start_line)
  end

  return string.format("%d-%d", start_line, finish)
end

local function format_hunk_line(hunk)
  local old_range = format_range(hunk.start_old, hunk.count_old)
  local new_range = format_range(hunk.start_new, hunk.count_new)

  if hunk.type == "add" then
    return string.format("add      new:%s", new_range)
  end

  if hunk.type == "change" then
    return string.format("change   old:%s -> new:%s", old_range, new_range)
  end

  local anchor = math.max(1, tonumber(hunk.start_new) or 1)
  return string.format("delete   old:%s (near new line %d)", old_range, anchor)
end

local function format_conflict_line(range, index)
  local suffix = ""
  if not range.complete then
    suffix = " (unterminated)"
  end

  if type(range.divider_line) == "number" then
    return string.format(
      "conflict #%d  %d-%d (split at %d)%s",
      index,
      range.start_line,
      range.end_line,
      range.divider_line,
      suffix
    )
  end

  return string.format("conflict #%d  %d-%d%s", index, range.start_line, range.end_line, suffix)
end

local function open_location_list_picker(opts)
  opts = opts or {}
  local path = opts.path
  local title = opts.title or "GitDx"
  local entries = opts.entries or {}

  if not path or path == "" then
    util.notify("Unable to open list view without file path", vim.log.levels.WARN)
    return false
  end

  if #entries == 0 then
    return false
  end

  local bufnr = vim.fn.bufnr(path, false)
  if bufnr < 0 then
    bufnr = vim.fn.bufadd(path)
    pcall(vim.fn.bufload, bufnr)
  end

  local source_win = vim.api.nvim_get_current_win()
  local loc_items = {}
  for _, entry in ipairs(entries) do
    table.insert(loc_items, {
      bufnr = bufnr,
      lnum = math.max(1, tonumber(entry.lnum) or 1),
      col = math.max(1, tonumber(entry.col) or 1),
      text = entry.text or "",
    })
  end

  vim.fn.setloclist(0, {}, " ", {
    title = title,
    items = loc_items,
  })

  local height = math.min(math.max(#loc_items + 1, 4), 14)
  vim.cmd(string.format("lopen %d", height))

  local loc_info = vim.fn.getloclist(0, { winid = 0 })
  local list_win = tonumber(loc_info.winid) or 0
  if list_win <= 0 or not vim.api.nvim_win_is_valid(list_win) then
    return
  end

  local list_buf = vim.api.nvim_win_get_buf(list_win)

  vim.keymap.set("n", "q", "<cmd>lclose<CR>", {
    buffer = list_buf,
    silent = true,
    desc = "GitDx close ranges list",
  })

  local function resolve_target_window()
    if vim.api.nvim_win_is_valid(source_win) and source_win ~= list_win then
      return source_win
    end

    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(win) and win ~= list_win then
        return win
      end
    end

    return nil
  end

  local function get_selected_item()
    if not vim.api.nvim_win_is_valid(list_win) then
      return nil
    end

    local cursor_line = vim.api.nvim_win_get_cursor(list_win)[1]
    local list = vim.api.nvim_win_call(list_win, function()
      return vim.fn.getloclist(0, { items = 1 })
    end)

    local items = list.items or {}
    return items[cursor_line]
  end

  local function jump_to_item(item)
    if not item or item.valid ~= 1 then
      return
    end

    local target_win = resolve_target_window()
    if not target_win then
      return
    end

    if item.bufnr and item.bufnr > 0 then
      pcall(vim.fn.bufload, item.bufnr)
    end

    local target_line = math.max(1, tonumber(item.lnum) or 1)
    local target_col = math.max(0, (tonumber(item.col) or 1) - 1)

    pcall(vim.api.nvim_set_current_win, target_win)

    if item.bufnr and item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
      pcall(vim.api.nvim_win_set_buf, target_win, item.bufnr)
    end

    pcall(vim.api.nvim_win_set_cursor, target_win, { target_line, target_col })
    pcall(vim.api.nvim_win_call, target_win, function()
      vim.cmd("normal! zv")
    end)
  end

  local function jump_current()
    jump_to_item(get_selected_item())
  end

  local function jump_at_mouse()
    if not vim.api.nvim_win_is_valid(list_win) then
      return
    end

    local mouse = vim.fn.getmousepos()
    if not mouse or tonumber(mouse.winid) ~= list_win then
      return
    end

    local line = math.max(1, tonumber(mouse.line) or 1)
    pcall(vim.api.nvim_set_current_win, list_win)
    pcall(vim.api.nvim_win_set_cursor, list_win, { line, 0 })
    jump_current()
  end

  vim.keymap.set("n", "<CR>", jump_current, {
    buffer = list_buf,
    silent = true,
    desc = "GitDx jump to selected range",
  })

  vim.keymap.set("n", "<LeftMouse>", jump_at_mouse, {
    buffer = list_buf,
    silent = true,
    desc = "GitDx jump to range under mouse",
  })

  vim.keymap.set("n", "<2-LeftMouse>", jump_at_mouse, {
    buffer = list_buf,
    silent = true,
    desc = "GitDx jump to range under mouse",
  })

  return true
end

local function echo_lines(lines)
  vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
end

local function format_ranges_title(info, stats)
  return string.format(
    "GitDx ranges: %s (+%d ~%d -%d)",
    info.relpath or vim.fn.fnamemodify(info.path, ":~:."),
    stats.added,
    stats.changed,
    stats.deleted
  )
end

local function format_conflicts_title(info, count)
  return string.format(
    "GitDx conflicts: %s (%d)",
    info.relpath or vim.fn.fnamemodify(info.path, ":~:."),
    count
  )
end

local function hunk_target_line(hunk)
  if hunk.type == "delete" then
    return math.max(1, tonumber(hunk.start_new) or 1)
  end

  return math.max(1, tonumber(hunk.start_new) or 1)
end

local function notify_stats(stats)
  util.notify(string.format("GitDx +%d ~%d -%d", stats.added, stats.changed, stats.deleted))
end

local function register_commands()
  if commands_registered then
    return
  end

  vim.api.nvim_create_user_command("GitDxDiff", function(opts)
    ensure_setup()
    local ref = opts.args ~= "" and opts.args or nil
    diffview.open({ ref = ref })
  end, {
    nargs = "?",
    desc = "Open side-by-side diff view for current file",
  })

  vim.api.nvim_create_user_command("GitDxDiffClose", function()
    ensure_setup()
    diffview.close()
  end, {
    desc = "Close gitdx diff view in current tab",
  })

  vim.api.nvim_create_user_command("GitDxDiffEdit", function()
    ensure_setup()
    diffview.close_and_edit()
  end, {
    desc = "Close gitdx diff view and open source file in a new tab at current line",
  })

  vim.api.nvim_create_user_command("GitDxRefresh", function()
    ensure_setup()
    live.refresh(0, true)
    if panel.is_open() then
      panel.refresh()
    end
  end, {
    desc = "Refresh live Git diff signs for current buffer",
  })

  vim.api.nvim_create_user_command("GitDx", function()
    ensure_setup()
    panel.open()
  end, {
    desc = "Open GitDx changes panel",
  })

  vim.api.nvim_create_user_command("GitDxEx", function()
    ensure_setup()
    panel.open_in_current_window()
  end, {
    desc = "Open GitDx changes panel in current window (like :Ex)",
  })

  vim.api.nvim_create_user_command("GitDxStats", function()
    ensure_setup()
    local stats, err = live.get_stats(0)
    if not stats then
      util.notify(err or "Unable to compute buffer stats", vim.log.levels.WARN)
      return
    end

    notify_stats(stats)
  end, {
    desc = "Show added/changed/deleted line counts for current buffer",
  })

  local function run_ranges_command()
    ensure_setup()
    local hunks, stats_or_err, info = live.get_hunks(0)
    if not hunks then
      util.notify(stats_or_err or "Unable to compute changed line ranges", vim.log.levels.WARN)
      return
    end

    local stats = stats_or_err
    local title = format_ranges_title(info, stats)

    if diffview.is_active() then
      local lines = { title }
      if #hunks == 0 then
        table.insert(lines, "working tree clean")
      else
        for _, hunk in ipairs(hunks) do
          table.insert(lines, format_hunk_line(hunk))
        end
      end
      echo_lines(lines)
      return
    end

    if #hunks == 0 then
      util.notify("GitDxRanges: working tree clean")
      return
    end

    local entries = {}
    for _, hunk in ipairs(hunks) do
      table.insert(entries, {
        lnum = hunk_target_line(hunk),
        col = 1,
        text = format_hunk_line(hunk),
      })
    end

    open_location_list_picker({
      title = title,
      path = info.path,
      entries = entries,
    })
  end

  vim.api.nvim_create_user_command("GitDxRanges", run_ranges_command, {
    desc = "Show changed line ranges for current buffer",
  })

  local function run_conflict_ranges_command()
    ensure_setup()
    local ranges, info_or_err = conflicts.get_buffer_ranges(0)
    if not ranges then
      util.notify(info_or_err or "Unable to compute conflict ranges", vim.log.levels.WARN)
      return
    end

    local info = info_or_err
    local title = format_conflicts_title(info, #ranges)

    if diffview.is_active() then
      local lines = { title }
      if #ranges == 0 then
        table.insert(lines, "no unresolved conflict markers")
      else
        for index, range in ipairs(ranges) do
          table.insert(lines, format_conflict_line(range, index))
        end
      end
      echo_lines(lines)
      return
    end

    if #ranges == 0 then
      util.notify("GitDxConflictRanges: no unresolved conflict markers")
      return
    end

    local entries = {}
    for index, range in ipairs(ranges) do
      table.insert(entries, {
        lnum = math.max(1, tonumber(range.start_line) or 1),
        col = 1,
        text = format_conflict_line(range, index),
      })
    end

    open_location_list_picker({
      title = title,
      path = info.path,
      entries = entries,
    })
  end

  vim.api.nvim_create_user_command("GitDxConflictRanges", run_conflict_ranges_command, {
    desc = "Show unresolved conflict marker ranges for current buffer",
  })


  vim.api.nvim_create_user_command("GitDxPanelClose", function()
    ensure_setup()
    if not panel.is_open() then
      util.notify("GitDx panel is not open", vim.log.levels.WARN)
      return
    end

    panel.close()
    util.notify("GitDx panel closed")
  end, {
    desc = "Close GitDx changes panel",
  })

  vim.api.nvim_create_user_command("GitDxWinbarToggle", function()
    ensure_setup()
    local enabled = live.toggle_winbar_summary()
    if enabled then
      util.notify("GitDx winbar summary is now visible")
    else
      util.notify("GitDx winbar summary is now hidden")
    end
  end, {
    desc = "Toggle GitDx winbar summary",
  })

  vim.api.nvim_create_user_command("GitDxWinbarEnable", function()
    ensure_setup()
    live.set_winbar_summary(true)
    util.notify("GitDx winbar summary is now visible")
  end, {
    desc = "Show GitDx winbar summary",
  })

  vim.api.nvim_create_user_command("GitDxWinbarDisable", function()
    ensure_setup()
    live.set_winbar_summary(false)
    util.notify("GitDx winbar summary is now hidden")
  end, {
    desc = "Hide GitDx winbar summary",
  })

  vim.api.nvim_create_user_command("GitDxSignsToggle", function()
    ensure_setup()
    local enabled = live.toggle_signs_visible()
    if enabled then
      util.notify("GitDx signs are now visible")
    else
      util.notify("GitDx signs are now hidden")
    end
  end, {
    desc = "Toggle GitDx signcolumn indicators",
  })

  vim.api.nvim_create_user_command("GitDxSignsEnable", function()
    ensure_setup()
    live.set_signs_visible(true)
    util.notify("GitDx signs are now visible")
  end, {
    desc = "Show GitDx signcolumn indicators",
  })

  vim.api.nvim_create_user_command("GitDxSignsDisable", function()
    ensure_setup()
    live.set_signs_visible(false)
    util.notify("GitDx signs are now hidden")
  end, {
    desc = "Hide GitDx signcolumn indicators",
  })

  vim.api.nvim_create_user_command("GitDxToggle", function()
    ensure_setup()
    local enabled = live.toggle()
    if enabled then
      util.notify("Live diff is now enabled")
    else
      util.notify("Live diff is now disabled")
    end
  end, {
    desc = "Toggle live Git diff signs",
  })

  vim.api.nvim_create_user_command("GitDxEnable", function()
    ensure_setup()
    live.enable()
    util.notify("Live diff is now enabled")
  end, {
    desc = "Enable live Git diff signs",
  })

  vim.api.nvim_create_user_command("GitDxDisable", function()
    ensure_setup()
    live.disable()
    util.notify("Live diff is now disabled")
  end, {
    desc = "Disable live Git diff signs",
  })

  commands_registered = true
end

function M.setup(user_opts)
  config.setup(user_opts or {})
  highlights.apply()
  highlights.register_autocmd()
  signs.define()
  register_commands()
  live.reconfigure()

  setup_done = true
  return config.get()
end

function M.refresh()
  ensure_setup()
  live.refresh(0, true)
end

function M.open_diff(ref)
  ensure_setup()
  diffview.open({ ref = ref })
end

function M.close_diff()
  ensure_setup()
  diffview.close()
end

function M.close_diff_and_edit()
  ensure_setup()
  diffview.close_and_edit()
end

function M.toggle()
  ensure_setup()
  return live.toggle()
end

function M.toggle_signs()
  ensure_setup()
  return live.toggle_signs_visible()
end

function M.toggle_winbar()
  ensure_setup()
  return live.toggle_winbar_summary()
end

function M.open_panel()
  ensure_setup()
  panel.open()
end

function M.is_setup()
  return setup_done
end

return M
