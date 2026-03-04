# gitdx.nvim

A Neovim plugin focused on developer experience:
- Live Git change indicators in `signcolumn` while you type
- Optional inline highlights for added and changed lines (off by default)
- Lightweight deleted-line hints (for example `-2` at end-of-line)
- Live change summary badge in `winbar` (`+A ~M -D`)
- Changes panel (`:GitDx`) with changed/added/deleted/renamed/conflict files
- Refs compare panel via `:GitDx <from_ref> [to_ref]`
- Side-by-side diff view:
  - file at `HEAD` (before changes)
  - current buffer (after changes)
  - optional `ref -> ref` comparison for one file (`:GitDxDiff`)
  - Added content highlighted in green, neutral placeholders in gray
  - Diff windows are buffer-locked to prevent accidental replacement (for example by `:Explore`)
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

- `:GitDxDiff [from_ref] [to_ref] [path]`
  - Open side-by-side diff for the current file (or refs compare)
  - `:GitDxDiff` opens working tree vs `HEAD`
  - `:GitDxDiff <ref>` opens working tree vs `<ref>`
  - `:GitDxDiff <from_ref> <to_ref>` opens refs compare for current file
  - `:GitDxDiff <from_ref> <to_ref> <path>` opens refs compare for explicit file path
  - Locks both diff panes against accidental buffer replacement
  - Blocks `:Ex` / `:Explore` while diff is active to keep layout stable
  - Automatically shows `GitDx +A ~M -D` stats after opening
  - Examples: `:GitDxDiff`, `:GitDxDiff HEAD~1`, `:GitDxDiff HEAD~5 HEAD`, `:GitDxDiff v1.0.0 v1.1.0 lua/gitdx/diffview.lua`
- `:GitDx [from_ref] [to_ref]`
  - `:GitDx` opens/focuses the working-tree panel (same as before)
  - `:GitDx <from_ref>` opens refs compare panel for `<from_ref> -> HEAD`
  - `:GitDx <from_ref> <to_ref>` opens refs compare panel for explicit range
  - Unavailable while `:GitDxDiff` is active in the current tab (to avoid UI conflicts)
  - Shows conflict files with `U` status and conflict highlighting in working-tree mode
  - Panel actions: `Enter` or mouse click (open diff / open conflict file), `r` (refresh), `q` (close)
  - Opening diff from panel (`Enter` / click) also shows `GitDx +A ~M -D` stats automatically
- `:GitDxEx [from_ref] [to_ref]`
  - Same behavior as `:GitDx`, but opens panel in current window (like `:Ex` or `:Explore`)
  - Keeps split-panel behavior unchanged for plain `:GitDx`
  - Panel buffer is locked to prevent accidental replacement
- `:GitDxPanelClose`
  - Close GitDx changes panel (shows warning if panel is not open)
- `:GitDxDiffClose`
  - If diff was opened in a dedicated tab, close that tab
  - Otherwise close diff mode in the current tab and close the plugin base buffer
- `:GitDxDiffEdit`
  - Close active `:GitDxDiff` view and open the source file in a new tab
  - Preserves cursor line from the diff source window
- `:GitDxStats`
  - Show added/changed/deleted line counts for the current buffer (`GitDx +A ~M -D`)
  - Works in active `:GitDxDiff` view (counts come from visible diff panes)
- `:GitDxRanges`
  - Open an interactive ranges list (location list) for changed hunks
  - `Enter` or mouse click jumps to selected line, `q` closes the list
  - While `:GitDxDiff` is active, falls back to plain text output (no extra windows)
  - If there are no changes, shows a notification instead of opening a list
- `:GitDxDiffRanges`
  - Alias for `:GitDxRanges` (handy during active diff workflows)
- `:GitDxConflictRanges`
  - Open an interactive ranges list for unresolved conflict blocks
  - `Enter` or mouse click jumps to selected conflict, `q` closes the list
  - While `:GitDxDiff` is active, falls back to plain text output (no extra windows)
  - If there are no conflicts, shows a notification instead of opening a list
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
    GitDxPanelStatusConflict = { fg = "#F29E4C", bold = true },

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
vim.keymap.set("n", "<leader>ge", "<cmd>GitDxDiffEdit<cr>", { desc = "GitDx: Close diff and edit file" })
vim.keymap.set("n", "<leader>gs", "<cmd>GitDx<cr>", { desc = "GitDx: Source control panel" })
vim.keymap.set("n", "<leader>gS", "<cmd>GitDxEx<cr>", { desc = "GitDx: Source control panel (current window)" })
vim.keymap.set("n", "<leader>gc", "<cmd>GitDxConflictRanges<cr>", { desc = "GitDx: Conflict ranges" })
vim.keymap.set("n", "<leader>gr", "<cmd>GitDxRefresh<cr>", { desc = "GitDx: Refresh" })
vim.keymap.set("n", "<leader>gt", "<cmd>GitDxToggle<cr>", { desc = "GitDx: Toggle" })
```

## Suggested Workflow

1. Keep live diff enabled for constant feedback
2. Run `:GitDxDiff` before committing
3. Review both sides quickly
4. Close with `:GitDxDiffClose` (or `:GitDxDiffEdit` to jump into normal editing tab)
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
- Conflict navigation seems empty:
  - Ensure the file contains unresolved markers (`<<<<<<<`, `=======`, `>>>>>>>`)
  - Run `:GitDxConflictRanges` in the conflict buffer

## License

MIT License. See [LICENSE](LICENSE) for full text.
