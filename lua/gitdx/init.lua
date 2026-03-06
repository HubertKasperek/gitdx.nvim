local config = require("gitdx.config")
local conflicts = require("gitdx.conflicts")
local diffview = require("gitdx.diffview")
local git = require("gitdx.git")
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

local function notify_active_diff_stats()
  if not diffview.is_active() then
    return false
  end

  local _, stats_or_err = diffview.get_hunks(0)
  if type(stats_or_err) == "table" then
    notify_stats(stats_or_err)
    return true
  end

  return false
end

local function path_exists(path)
  local target = util.trim(path)
  if target == "" then
    return false
  end

  local resolved = vim.fn.fnamemodify(target, ":p")
  if resolved == "" then
    return false
  end

  local uv = vim.uv or vim.loop
  return uv.fs_stat(resolved) ~= nil
end

local function looks_like_path(value)
  if value:find("[/\\]") then
    return true
  end

  local first = value:sub(1, 1)
  if first == "." or first == "~" then
    return true
  end

  return value:match("^%a:[/\\]") ~= nil
end

local function current_ref_resolution_repo()
  local probe_path = vim.api.nvim_buf_get_name(0)
  if probe_path == "" then
    probe_path = vim.fn.getcwd()
  end

  return git.find_repo_root_from(probe_path)
end

local function should_treat_single_arg_as_path(arg)
  local exists = path_exists(arg)
  if not exists then
    return false
  end

  if looks_like_path(arg) then
    return true
  end

  local repo_root = current_ref_resolution_repo()
  if repo_root and git.ref_exists(repo_root, arg) then
    return false
  end

  return true
end

local function open_panel_with_optional_refs(opts, open_in_current_window)
  local fargs = opts.fargs or {}
  local argc = #fargs
  local command_name = open_in_current_window and "GitDxEx" or "GitDx"
  local split = opts.split
  local usage = string.format("Usage: :%s [path] OR :%s [from_ref] [to_ref]", command_name, command_name)
  local usage_refs = string.format("Usage: :%s [from_ref] [to_ref]", command_name)

  local function open_working_panel(path)
    if open_in_current_window then
      panel.open_in_current_window(path)
      return
    end

    panel.open({
      split = split,
      path = path,
    })
  end

  if argc == 0 then
    open_working_panel(nil)
    return
  end

  if argc > 2 then
    util.notify(usage, vim.log.levels.WARN)
    return
  end

  local first_arg = util.trim(fargs[1] or "")
  if first_arg == "" then
    util.notify(usage, vim.log.levels.WARN)
    return
  end

  if argc == 1 and should_treat_single_arg_as_path(first_arg) then
    open_working_panel(first_arg)
    return
  end

  local from_ref = first_arg

  local to_ref = "HEAD"
  if argc == 2 then
    to_ref = util.trim(fargs[2] or "")
    if to_ref == "" then
      util.notify(usage_refs, vim.log.levels.WARN)
      return
    end
  end

  local open_refs = open_in_current_window and panel.open_refs_in_current_window or panel.open_refs
  open_refs({
    from_ref = from_ref,
    to_ref = to_ref,
    split = split,
  })
end

local function open_diff_with_optional_refs(opts)
  local fargs = opts.fargs or {}
  local argc = #fargs

  if argc == 0 then
    diffview.open({})
    notify_active_diff_stats()
    return
  end

  if argc == 1 then
    local ref = util.trim(fargs[1] or "")
    if ref == "" then
      util.notify("Usage: :GitDxDiff [ref] [to_ref] [path]", vim.log.levels.WARN)
      return
    end

    diffview.open({ ref = ref })
    notify_active_diff_stats()
    return
  end

  if argc > 3 then
    util.notify("Usage: :GitDxDiff [ref] [to_ref] [path]", vim.log.levels.WARN)
    return
  end

  local from_ref = util.trim(fargs[1] or "")
  local to_ref = util.trim(fargs[2] or "")
  if from_ref == "" or to_ref == "" then
    util.notify("Usage: :GitDxDiff [ref] [to_ref] [path]", vim.log.levels.WARN)
    return
  end

  diffview.open_between_refs({
    from_ref = from_ref,
    to_ref = to_ref,
    path = fargs[3],
  })
  notify_active_diff_stats()
end

local function register_commands()
  if commands_registered then
    return
  end

  vim.api.nvim_create_user_command("GitDxDiff", function(opts)
    ensure_setup()
    open_diff_with_optional_refs(opts)
  end, {
    nargs = "*",
    desc = "Open side-by-side diff view (working tree or refs compare)",
  })

  vim.api.nvim_create_user_command("GitDxDiffClose", function()
    ensure_setup()
    diffview.close()
  end, {
    desc = "Close gitdx diff view in current tab",
  })

  vim.api.nvim_create_user_command("GitDxDiffNext", function()
    ensure_setup()
    diffview.jump_next_hunk()
  end, {
    desc = "Jump to next change in active GitDxDiff view (wraps)",
  })

  vim.api.nvim_create_user_command("GitDxDiffPrev", function()
    ensure_setup()
    diffview.jump_prev_hunk()
  end, {
    desc = "Jump to previous change in active GitDxDiff view (wraps)",
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

  vim.api.nvim_create_user_command("GitDx", function(opts)
    ensure_setup()
    open_panel_with_optional_refs(opts, false)
  end, {
    nargs = "*",
    desc = "Open GitDx panel (working tree/path or refs compare)",
  })

  vim.api.nvim_create_user_command("GitDxRight", function(opts)
    ensure_setup()
    local params = vim.tbl_extend("force", opts, { split = "right" })
    open_panel_with_optional_refs(params, false)
  end, {
    nargs = "*",
    desc = "Open GitDx panel on the right (working tree/path or refs compare)",
  })

  vim.api.nvim_create_user_command("GitDxEx", function(opts)
    ensure_setup()
    open_panel_with_optional_refs(opts, true)
  end, {
    nargs = "*",
    desc = "Open GitDx panel in current window (working tree/path or refs compare)",
  })

  vim.api.nvim_create_user_command("GitDxStats", function()
    ensure_setup()
    if diffview.is_active() then
      local _, stats_or_err = diffview.get_hunks(0)
      if not stats_or_err then
        util.notify("Unable to compute diff stats", vim.log.levels.WARN)
        return
      end

      if type(stats_or_err) == "string" then
        util.notify(stats_or_err, vim.log.levels.WARN)
        return
      end

      notify_stats(stats_or_err)
      return
    end

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
    local hunks, stats_or_err, info

    if diffview.is_active() then
      hunks, stats_or_err, info = diffview.get_hunks(0)
    else
      hunks, stats_or_err, info = live.get_hunks(0)
    end

    if not hunks then
      util.notify(stats_or_err or "Unable to compute changed line ranges", vim.log.levels.WARN)
      return
    end

    local stats = stats_or_err
    local title = format_ranges_title(info, stats)

    if diffview.is_active() then
      local lines = { title }
      if #hunks == 0 then
        if info and info.mode == "refs" then
          table.insert(lines, "refs comparison clean")
        else
          table.insert(lines, "working tree clean")
        end
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

function M.diff_next_change()
  ensure_setup()
  return diffview.jump_next_hunk()
end

function M.diff_prev_change()
  ensure_setup()
  return diffview.jump_prev_hunk()
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

function M.open_panel(path)
  ensure_setup()
  panel.open({ path = path })
end

function M.open_panel_right(path)
  ensure_setup()
  panel.open({ split = "right", path = path })
end

function M.open_panel_refs(from_ref, to_ref, open_in_current_window, path)
  ensure_setup()
  local opts = {
    from_ref = from_ref,
    to_ref = to_ref,
    path = path,
  }

  if open_in_current_window then
    panel.open_refs_in_current_window(opts)
  else
    panel.open_refs(opts)
  end
end

function M.get_session_state()
  ensure_setup()
  return panel.get_session_state()
end

function M.apply_session_state(snapshot)
  ensure_setup()
  return panel.apply_session_state(snapshot)
end

function M.is_setup()
  return setup_done
end

return M
