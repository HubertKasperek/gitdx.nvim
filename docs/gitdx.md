# gitdx.nvim Reference

This document mirrors the Neovim help file (`:h gitdx`) in Markdown form for GitHub browsing.

## Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Commands](#commands)
4. [Configuration](#configuration)
5. [Highlight Groups](#highlight-groups)
6. [Lua API](#lua-api)
7. [Notes and Constraints](#notes-and-constraints)

## Introduction

`gitdx.nvim` provides Git-aware editing feedback with low ceremony:

- Live signs for added/changed/deleted hunks
- Optional line highlights and deleted-line virtual hint
- Winbar summary: `GitDx +A ~M -D`
- Changes panel (working tree or ref compare)
- Side-by-side diff view (working tree/ref or ref/ref)
- Range pickers for hunks and unresolved conflicts

Requirements:

- Neovim >= 0.9
- Git in `PATH`

## Installation

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

### Manual (`pack/*/start`)

```bash
git clone https://github.com/HubertKasperek/gitdx.nvim \
  ~/.config/nvim/pack/plugins/start/gitdx.nvim
```

If setup is not called explicitly, the plugin auto-initializes with defaults.
If `:h gitdx` does not resolve after manual install, run:

```vim
:helptags ~/.config/nvim/pack/plugins/start/gitdx.nvim/doc
```

## Commands

### `:GitDx [path]` or `:GitDx [from_ref] [to_ref]`

Open/focus the changes panel.

- No args: working-tree mode (`git status` data)
- In working-tree mode, when current directory is outside a Git repo but descendant folders contain repos, changes are grouped by repository
- One arg: if argument is an existing path, open working-tree mode for that path
- One arg: otherwise compare `<from_ref> -> HEAD`
- If argument is both an existing path and a valid ref in current repo, it is treated as ref; use `./path` (or absolute path) to force path mode
- Two args: compare `<from_ref> -> <to_ref>`
- Uses default side from `panel.split` (`left` or `right`)

### `:GitDxRight [path]` or `:GitDxRight [from_ref] [to_ref]`

Same as `:GitDx`, but always opens panel on the right side.

### `:GitDxEx [path]` or `:GitDxEx [from_ref] [to_ref]`

Same as `:GitDx`, but opens panel in current window.

Includes the same multi-repository working-tree grouping behavior as `:GitDx`.

### `:GitDxPanelClose`

Close panel. Warns if panel is not open.

### `:GitDxDiff [ref]` or `:GitDxDiff <from_ref> <to_ref> [path]`

Open side-by-side diff.

- No args: working tree vs `HEAD` for current file
- One arg (`ref`): working tree vs `<ref>` for current file
- Two args (`from_ref to_ref`): compare refs for current file
- Three args (`from_ref to_ref path`): compare refs for explicit file path

Notes:

- Left pane is base/from_ref, right pane is current/to_ref
- Both panes are locked (`winfixbuf`) to avoid replacement
- `:Ex`/`:Explore` are blocked while GitDxDiff is active
- Diff navigation: `n` (next) / `N` (previous) with wrap
- Alternative non-colliding keys: `]g` / `[g`
- Each jump echoes current position as `X/Y`

### `:GitDxDiffClose`

Close active GitDx diff in current tab.

If diff was opened in an owned tab (`diffview.open_in_tab=true`), closes that tab.
Otherwise runs `diffoff!` and cleans up GitDx temporary buffers.

### `:GitDxDiffNext`

Jump to next change in active GitDx diff view (wraps).

### `:GitDxDiffPrev`

Jump to previous change in active GitDx diff view (wraps).

### `:GitDxDiffEdit`

Close active GitDx diff and open source file in a new tab at the same line.

### `:GitDxStats`

Show current stats as `GitDx +A ~M -D`.

- In normal mode: stats come from live working-tree diff
- In active GitDx diff: stats come from visible diff buffers

### `:GitDxRanges`

Show changed hunk ranges.

- Normal mode: opens location list, supports Enter/mouse jump, `q` closes
- Active GitDx diff: prints plain text ranges (no extra windows)

### `:GitDxConflictRanges`

Show unresolved conflict marker ranges.

Conflict parser scans for markers: `<<<<<<<`, `=======`, `>>>>>>>`

- Normal mode: opens location list, supports Enter/mouse jump, `q` closes
- Active GitDx diff: prints plain text ranges (no extra windows)

### `:GitDxRefresh`

Force live refresh for current buffer. Also refreshes panel if open.

### `:GitDxToggle`, `:GitDxEnable`, `:GitDxDisable`

Toggle/enable/disable live diff engine.

### `:GitDxSignsToggle`, `:GitDxSignsEnable`, `:GitDxSignsDisable`

Toggle/enable/disable signcolumn markers only.

### `:GitDxWinbarToggle`, `:GitDxWinbarEnable`, `:GitDxWinbarDisable`

Toggle/enable/disable winbar summary label.

### Panel interactions (inside panel buffer)

- `q`: close panel
- `r`: refresh panel
- `<CR>` / mouse click: open selected entry

Panel entry open behavior:

- `A`, `M`: open working-tree diff for file
- `D`: open deleted-file diff (empty working tree side)
- `R`: open rename-aware diff (old path on base side)
- `U`: open conflict file in new tab and jump to first conflict block

## Configuration

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
    sync_scroll = true,
    winhighlight = table.concat({
      "DiffAdd:GitDxDiffAdd",
      "DiffDelete:GitDxDiffDelete",
      "DiffChange:GitDxDiffChange",
      "DiffText:GitDxDiffText",
    }, ","),
  },

  highlights = {
    -- override specific highlight groups
  },
})
```

Option reference:

- `ref` (string, default `"HEAD"`): baseline ref for live working-tree diff
- `sign_priority` (number, default `10`): priority used by sign placement
- `signs.add` / `signs.change` / `signs.delete` (string): marker text shown in signcolumn
- `live.enabled` (boolean, default `true`): enable live tracking engine on startup
- `live.debounce_ms` (number, default `120`): debounce for diff refresh events
- `live.max_file_lines` (number, default `20000`): files above this line count are skipped by live tracking
- `live.show_signs` (boolean, default `true`): show/hide signcolumn markers
- `live.line_highlight` (boolean, default `false`): highlight full changed lines
- `live.show_deleted_count` (boolean, default `true`): show deleted count virtual hint (`-N`) at delete anchor line
- `live.stable_signcolumn` (boolean, default `true`): keep signcolumn stable while GitDx is active in a Git-tracked buffer
- `live.stable_signcolumn_value` (string, default `"yes:1"`): value assigned to `win.signcolumn` when stable signcolumn is active
- `live.winbar_summary` (boolean, default `true`): show/hide winbar stats label
- `live.update_events` (string[]): buffer events that trigger live refresh
- `panel.width` (number, default `40`): panel width in split mode
- `panel.split` (`"left" | "right"`, default `"left"`): split side for `:GitDx` panel
- `diffview.open_in_tab` (boolean, default `true`): open diff in dedicated tab (if false, use current tab)
- `diffview.keep_focus` (`"left" | "right"`, default `"right"`): select focused pane after opening diff
- `diffview.sync_scroll` (boolean, default `true`): synchronize vertical and horizontal scroll between diff panes
- `diffview.winhighlight` (string): window-local diff highlight remap
- `highlights` (table): overrides for plugin highlight groups

Runtime notes:

- Toggle commands mutate config state in memory (not persisted automatically)
- Highlights are re-applied on `ColorScheme`

## Highlight Groups

Signs:

- `GitDxSignAdd`
- `GitDxSignChange`
- `GitDxSignDelete`

Live overlays:

- `GitDxLineAdd`
- `GitDxLineChange`
- `GitDxDeletedVirtual`
- `GitDxDirtyBadge`

Panel:

- `GitDxPanelTitle`
- `GitDxPanelHint`
- `GitDxPanelPath`
- `GitDxPanelStatusAdd`
- `GitDxPanelStatusChange`
- `GitDxPanelStatusDelete`
- `GitDxPanelStatusRename`
- `GitDxPanelStatusConflict`

Diff:

- `GitDxDiffAdd`
- `GitDxDiffDelete`
- `GitDxDiffChange`
- `GitDxDiffText`

## Lua API

Public entrypoint: `require("gitdx")`

- `setup(opts)`: apply config, register commands/highlights, and (re)configure live engine
- `refresh()`: refresh live state for current buffer
- `open_diff(ref)`: open working-tree diff for current buffer against `ref` (or default ref)
- `close_diff()`: close active diff in current tab
- `close_diff_and_edit()`: close active diff and open source file in a new tab
- `diff_next_change()`: jump to next change hunk in active GitDx diff view (wraps)
- `diff_prev_change()`: jump to previous change hunk in active GitDx diff view (wraps)
- `toggle()`: toggle live engine, returns boolean enabled state
- `toggle_signs()`: toggle sign visibility, returns boolean visibility state
- `toggle_winbar()`: toggle winbar summary, returns boolean enabled state
- `open_panel(path)`: open/focus working-tree panel (optional `path` for explicit repo/workspace root)
- `open_panel_right(path)`: open/focus working-tree panel on right split (optional `path`)
- `open_panel_refs(from_ref, to_ref, open_in_current_window, path)`: open refs panel (split or current window), optional `path` chooses repository root
- `get_session_state()`: return GitDx panel workflow snapshot for integrations
- `apply_session_state(snapshot)`: restore GitDx panel workflow snapshot
- `is_setup()`: returns true if setup was completed

## Notes and Constraints

- Live decorations are applied only to regular file buffers
- Buffers outside Git repositories are skipped cleanly
- Files ignored by `.gitignore` are skipped by live decorations
- Git calls are synchronous (`vim.system(...):wait()` or `system()` fallback)
- Ref compare requires both paths inside the same repo and valid commit refs
- During active GitDx diff, panel opening is blocked to avoid layout conflicts
- Active GitDx diff provides hunk navigation via `n`/`N` and `]g`/`[g` (wraps)
- `:Ex`/`:Explore` are blocked in panel/diff context and netrw windows are closed if opened into an active diff tab
- GitDx panel state is tab-local: each tab can keep its own panel independently
- Diff mode may append `hiddenoff` to `diffopt`; it is removed when no active GitDx diff remains
