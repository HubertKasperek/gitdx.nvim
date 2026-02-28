local M = {}

local defaults = {
  ref = "HEAD",
  sign_priority = 10,
  signs = {
    add = "|",
    change = "~",
    delete = "_",
  },
  live = {
    enabled = true,
    debounce_ms = 120,
    max_file_lines = 20000,
    line_highlight = true,
    show_deleted_count = true,
    update_events = {
      "TextChanged",
      "TextChangedI",
      "InsertLeave",
      "BufWritePost",
    },
  },
  diffview = {
    open_in_tab = true,
    keep_focus = "right",
    winhighlight = table.concat({
      "DiffAdd:GitDxDiffAdd",
      "DiffDelete:GitDxDiffDelete",
      "DiffChange:GitDxDiffChange",
      "DiffText:GitDxDiffText",
    }, ","),
  },
  highlights = {
    GitDxSignAdd = { fg = "#4FB37A", bg = "NONE" },
    GitDxSignChange = { fg = "#D1AA5A", bg = "NONE" },
    GitDxSignDelete = { fg = "#D86A6A", bg = "NONE" },
    GitDxLineAdd = { bg = "#102216" },
    GitDxLineChange = { bg = "#1A2233" },
    GitDxDeletedVirtual = { fg = "#C67575", italic = true },
    GitDxDiffAdd = { bg = "#14301F" },
    GitDxDiffDelete = { bg = "#381A1A" },
    GitDxDiffChange = { bg = "#1C2740" },
    GitDxDiffText = { bg = "#2E4264", bold = true },
  },
}

M.options = vim.deepcopy(defaults)

local function validate(user_opts)
  if user_opts ~= nil and type(user_opts) ~= "table" then
    error("gitdx.nvim: setup options must be a table")
  end

  if not user_opts then
    return
  end

  if user_opts.ref ~= nil and type(user_opts.ref) ~= "string" then
    error("gitdx.nvim: ref must be a string")
  end

  if user_opts.sign_priority ~= nil and type(user_opts.sign_priority) ~= "number" then
    error("gitdx.nvim: sign_priority must be a number")
  end

  if user_opts.diffview and user_opts.diffview.keep_focus then
    local keep_focus = user_opts.diffview.keep_focus
    if keep_focus ~= "left" and keep_focus ~= "right" then
      error("gitdx.nvim: diffview.keep_focus must be 'left' or 'right'")
    end
  end
end

function M.setup(user_opts)
  validate(user_opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user_opts or {})
  return M.options
end

function M.get()
  return M.options
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
