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
