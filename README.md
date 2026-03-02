# gitdx.nvim

A Neovim plugin focused on developer experience:
- Live Git change indicators in `signcolumn` while you type
- Optional inline highlights for added and changed lines (off by default)
- Lightweight deleted-line hints (for example `-2` at end-of-line)
- Live change summary badge in `winbar` (`+A ~M -D`)
- Changes panel (`:GitDx`) with changed/added/deleted/renamed files
- Side-by-side diff view:
  - file at `HEAD` (before changes)
  - current buffer (after changes)
  - Added content highlighted in green, neutral placeholders in gray
  - GitDx winbar summary is hidden in diff windows to keep both panes aligned

## Requirements

- Neovim `>= 0.9` (tested on 0.11.4)
- Git available in your `PATH`

## Installation

### Manual (`pack/*/start`)

Clone directly to Neovim's `start` package directory:

```bash
git clone https://github.com/HubertKasperek/gitdx.nvim ~/.config/nvim/pack/plugins/start/gitdx.nvim
```

Then add this to your Neovim config (init.lua):

```lua
require("gitdx").setup()
```

### lazy.nvim

```lua
{
  "HubertKasperek/gitdx.nvim",
  config = function()
    require("gitdx").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "HubertKasperek/gitdx.nvim",
  config = function()
    require("gitdx").setup()
  end,
}
```

## Quick Start

After installation, the plugin auto-initializes.

1. Open a file tracked by Git.
2. Start editing.
3. You will see these signs in `signcolumn`:
   - `|` for added
   - `~` for changed
   - `_` for deleted
4. Indicators and GitDx winbar summary are shown only for files inside a Git repository.

## Commands

- `:GitDxDiff [ref]`
  - Open side-by-side diff for the current file
  - Default ref is `HEAD`
  - Example: `:GitDxDiff HEAD~1`
- `:GitDx`
  - Open/focus the GitDx changes panel
  - Unavailable while `:GitDxDiff` is active in the current tab (to avoid UI conflicts)
  - Panel actions: `Enter` or mouse click (open diff), `r` (refresh), `q` (close)
- `:GitDxEx`
  - Open/focus the GitDx changes panel in the current window (like `:Ex` or `:Explore`)
  - Keeps `:GitDx` split-panel behavior unchanged
- `:GitDxPanelClose`
  - Close GitDx changes panel (shows warning if panel is not open)
- `:GitDxDiffClose`
  - If diff was opened in a dedicated tab, close that tab
  - Otherwise close diff mode in the current tab and close the plugin base buffer
- `:GitDxStats`
  - Show added/changed/deleted line counts for the current buffer (`GitDx +A ~M -D`)
- `:GitDxRanges`
  - Show changed line ranges (add/change/delete hunks) for the current buffer
- `:GitDxRefresh`
  - Force live diff recalculation for current buffer
- `:GitDxToggle`
  - Toggle live diff signs on/off
- `:GitDxSignsToggle`
  - Toggle left signcolumn indicators only
- `:GitDxSignsEnable`
  - Show left signcolumn indicators
- `:GitDxSignsDisable`
  - Hide left signcolumn indicators
- `:GitDxWinbarToggle`
  - Toggle top winbar summary (`GitDx +A ~M -D`)
- `:GitDxWinbarEnable`
  - Show top winbar summary
- `:GitDxWinbarDisable`
  - Hide top winbar summary
- `:GitDxEnable`
  - Enable live diff signs
- `:GitDxDisable`
  - Disable live diff signs

## Configuration

Full configuration example:

```lua
require("gitdx").setup({
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
    show_signs = true,
    line_highlight = false,
    show_deleted_count = true,
    stable_signcolumn = true,
    stable_signcolumn_value = "yes:1",
    winbar_summary = true,
    update_events = {
      "TextChanged",
      "TextChangedI",
      "InsertLeave",
      "BufWritePost",
    },
  },

  panel = {
    width = 40,
    split = "left", -- "left" | "right"
  },

  diffview = {
    open_in_tab = true,
    keep_focus = "right", -- "left" | "right"
    sync_scroll = true, -- true = linked scroll in both panes
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
    GitDxDirtyBadge = { fg = "#8FA7BF", bold = true },
    GitDxPanelTitle = { fg = "#8FA7BF", bold = true },
    GitDxPanelHint = { fg = "#6E7A89", italic = true },
    GitDxPanelPath = { fg = "#C7CED8" },
    GitDxPanelStatusAdd = { fg = "#4FB37A", bold = true },
    GitDxPanelStatusChange = { fg = "#D1AA5A", bold = true },
    GitDxPanelStatusDelete = { fg = "#D86A6A", bold = true },
    GitDxPanelStatusRename = { fg = "#68A0D8", bold = true },

    GitDxDiffAdd = { bg = "#14301F" },
    GitDxDiffDelete = { bg = "#2A2F38" },
    GitDxDiffChange = { bg = "#1C2740" },
    GitDxDiffText = { bg = "#2E4264", bold = true },
  },
})
```

## Color Customization

Recommended approach:

1. Keep plugin colors in one `palette` table
2. Pass them through `setup({ highlights = ... })`
3. Optionally re-apply custom highlight overrides after `ColorScheme`

Example:

```lua
local palette = {
  green = "#4FB37A",
  red = "#E06C75",
  yellow = "#D1AA5A",
  add_bg = "#11291A",
  del_bg = "#3A1C1C",
  change_bg = "#1E2942",
}

require("gitdx").setup({
  highlights = {
    GitDxSignAdd = { fg = palette.green },
    GitDxSignChange = { fg = palette.yellow },
    GitDxSignDelete = { fg = palette.red },
    GitDxDiffAdd = { bg = palette.add_bg },
    GitDxDiffDelete = { bg = palette.del_bg },
    GitDxDiffChange = { bg = palette.change_bg },
  },
})
```

## Recommended Keymaps

```lua
vim.keymap.set("n", "<leader>gd", "<cmd>GitDxDiff<cr>", { desc = "GitDx: Diff split" })
vim.keymap.set("n", "<leader>gD", "<cmd>GitDxDiffClose<cr>", { desc = "GitDx: Close diff" })
vim.keymap.set("n", "<leader>gs", "<cmd>GitDx<cr>", { desc = "GitDx: Source control panel" })
vim.keymap.set("n", "<leader>gS", "<cmd>GitDxEx<cr>", { desc = "GitDx: Source control panel (current window)" })
vim.keymap.set("n", "<leader>gr", "<cmd>GitDxRefresh<cr>", { desc = "GitDx: Refresh" })
vim.keymap.set("n", "<leader>gt", "<cmd>GitDxToggle<cr>", { desc = "GitDx: Toggle" })
```

## Suggested Workflow

1. Keep live diff enabled for constant feedback
2. Run `:GitDxDiff` before committing
3. Review both sides quickly
4. Close with `:GitDxDiffClose`
5. Commit after visual verification

## Troubleshooting

- No signs visible:
  - Ensure file is inside a Git repository
  - Run `:GitDxRefresh`
- `:GitDxDiff` does not open:
  - File must exist on disk
  - Git must be available in `PATH`
- `:GitDx` is blocked while diff view is active:
  - Close diff first with `:GitDxDiffClose`

## License

MIT License. See [LICENSE](LICENSE) for full text.
