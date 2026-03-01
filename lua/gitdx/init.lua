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
    panel.close()
  end, {
    desc = "Close GitDx changes panel",
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

function M.open_panel()
  ensure_setup()
  panel.open()
end

function M.is_setup()
  return setup_done
end

return M
