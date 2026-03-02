local config = require("gitdx.config")
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

  vim.api.nvim_create_user_command("GitDxRanges", function()
    ensure_setup()
    local hunks, stats_or_err, info = live.get_hunks(0)
    if not hunks then
      util.notify(stats_or_err or "Unable to compute changed line ranges", vim.log.levels.WARN)
      return
    end

    local stats = stats_or_err
    local lines = {
      string.format(
        "GitDx ranges: %s (+%d ~%d -%d)",
        info.relpath or vim.fn.fnamemodify(info.path, ":~:."),
        stats.added,
        stats.changed,
        stats.deleted
      ),
    }

    if #hunks == 0 then
      table.insert(lines, "working tree clean")
    else
      for _, hunk in ipairs(hunks) do
        table.insert(lines, format_hunk_line(hunk))
      end
    end

    vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
  end, {
    desc = "Show changed line ranges for current buffer",
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
