local config = require("gitdx.config")
local git = require("gitdx.git")
local util = require("gitdx.util")

local M = {}
local sync_session_seq = 0
local horizontal_sync_guard = false

local HORIZONTAL_SYNC_SESSION_VAR = "gitdx_diff_sync_session"
local HORIZONTAL_SYNC_PEER_VAR = "gitdx_diff_peer_win"
local PREV_WINHIGHLIGHT_VAR = "gitdx_diff_prev_winhighlight"
local PREV_WINFIXBUF_VAR = "gitdx_diff_prev_winfixbuf"
local EX_BLOCK_COUNT_VAR = "gitdx_diff_ex_block_count"
local EX_BLOCK_CREATED_VAR = "gitdx_diff_ex_block_created"
local DIFF_STATE_TAB_VAR = "gitdx_diff_state"
local DIFF_OWNED_TAB_VAR = "gitdx_diff_owned_tab"
local forced_hiddenoff = false

local function sync_live_window_decorations()
  local ok, live = pcall(require, "gitdx.live")
  if not ok or not live or type(live.sync_windows) ~= "function" then
    return
  end

  pcall(live.sync_windows)
end

local function split_diffopt_items(value)
  if type(value) ~= "string" or value == "" then
    return {}
  end

  local items = {}
  for token in value:gmatch("[^,]+") do
    local item = util.trim(token)
    if item ~= "" then
      table.insert(items, item)
    end
  end
  return items
end

local function diffopt_has_item(value, target)
  for _, item in ipairs(split_diffopt_items(value)) do
    if item == target then
      return true
    end
  end

  return false
end

local function encode_diffopt(items)
  return table.concat(items, ",")
end

local function ensure_hiddenoff_diffopt()
  local current = vim.o.diffopt or ""
  if diffopt_has_item(current, "hiddenoff") then
    return
  end

  local items = split_diffopt_items(current)
  table.insert(items, "hiddenoff")
  vim.o.diffopt = encode_diffopt(items)
  forced_hiddenoff = true
end

local function has_active_gitdx_diff_anywhere()
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      local ok, state = pcall(vim.api.nvim_tabpage_get_var, tabpage, DIFF_STATE_TAB_VAR)
      if not ok then
        state = nil
      end
      if type(state) == "table" then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
          if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
            return true
          end
        end
      end
    end
  end

  return false
end

local function maybe_restore_hiddenoff_diffopt()
  if not forced_hiddenoff then
    return
  end

  if has_active_gitdx_diff_anywhere() then
    return
  end

  local items = {}
  for _, item in ipairs(split_diffopt_items(vim.o.diffopt or "")) do
    if item ~= "hiddenoff" then
      table.insert(items, item)
    end
  end

  vim.o.diffopt = encode_diffopt(items)
  forced_hiddenoff = false
end

local function get_tab_var(tabpage, name)
  local ok, value = pcall(vim.api.nvim_tabpage_get_var, tabpage, name)
  if not ok then
    return nil
  end

  return value
end

local function set_tab_var(tabpage, name, value)
  pcall(vim.api.nvim_tabpage_set_var, tabpage, name, value)
end

local function del_tab_var(tabpage, name)
  pcall(vim.api.nvim_tabpage_del_var, tabpage, name)
end

local function get_win_var(win, name)
  local ok, value = pcall(vim.api.nvim_win_get_var, win, name)
  if not ok then
    return nil
  end

  return value
end

local function set_win_var(win, name, value)
  pcall(vim.api.nvim_win_set_var, win, name, value)
end

local function del_win_var(win, name)
  pcall(vim.api.nvim_win_del_var, win, name)
end

local function restore_winhighlight(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local prev = get_win_var(win, PREV_WINHIGHLIGHT_VAR)
  if prev == nil then
    return
  end

  vim.wo[win].winhighlight = prev
  del_win_var(win, PREV_WINHIGHLIGHT_VAR)
end

local function restore_winfixbuf(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local prev = get_win_var(win, PREV_WINFIXBUF_VAR)
  if prev == nil then
    return
  end

  vim.wo[win].winfixbuf = prev == true
  del_win_var(win, PREV_WINFIXBUF_VAR)
end

local function restore_diff_window_style(win)
  restore_winhighlight(win)
  restore_winfixbuf(win)
end

local function get_buffer_command_map(buf)
  local ok, commands = pcall(vim.api.nvim_buf_get_commands, buf, {})
  if not ok or type(commands) ~= "table" then
    return {}
  end

  return commands
end

local function block_explore_commands_for_buffer(buf)
  if not buf or buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local count = tonumber(vim.b[buf][EX_BLOCK_COUNT_VAR]) or 0
  if count > 0 then
    vim.b[buf][EX_BLOCK_COUNT_VAR] = count + 1
    return
  end

  local created = {}
  local commands = get_buffer_command_map(buf)
  for _, name in ipairs({ "Ex", "Explore" }) do
    if not commands[name] then
      local ok = pcall(vim.api.nvim_buf_create_user_command, buf, name, function()
        util.notify(":" .. name .. " is disabled during GitDxDiff. Close diff first with :GitDxDiffClose.", vim.log.levels.WARN)
      end, {
        desc = "GitDxDiff command lock",
      })
      if ok then
        created[name] = true
      end
    end
  end

  vim.b[buf][EX_BLOCK_CREATED_VAR] = created
  vim.b[buf][EX_BLOCK_COUNT_VAR] = 1
end

local function unblock_explore_commands_for_buffer(buf)
  if not buf or buf <= 0 or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local count = tonumber(vim.b[buf][EX_BLOCK_COUNT_VAR]) or 0
  if count <= 0 then
    return
  end

  if count > 1 then
    vim.b[buf][EX_BLOCK_COUNT_VAR] = count - 1
    return
  end

  local created = vim.b[buf][EX_BLOCK_CREATED_VAR]
  if type(created) == "table" then
    for name, was_created in pairs(created) do
      if was_created == true then
        pcall(vim.api.nvim_buf_del_user_command, buf, name)
      end
    end
  end

  vim.b[buf][EX_BLOCK_CREATED_VAR] = nil
  vim.b[buf][EX_BLOCK_COUNT_VAR] = nil
end

local function block_explore_commands_for_state(state)
  if type(state) ~= "table" then
    return
  end

  local seen = {}
  for _, key in ipairs({ "left_buf", "source_buf" }) do
    local buf = tonumber(state[key])
    if buf and buf > 0 and not seen[buf] then
      seen[buf] = true
      block_explore_commands_for_buffer(buf)
    end
  end
end

local function unblock_explore_commands_for_state(state)
  if type(state) ~= "table" then
    return
  end

  local seen = {}
  for _, key in ipairs({ "left_buf", "source_buf" }) do
    local buf = tonumber(state[key])
    if buf and buf > 0 and not seen[buf] then
      seen[buf] = true
      unblock_explore_commands_for_buffer(buf)
    end
  end
end

local function get_window_leftcol(win)
  if not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
end

local function set_window_leftcol(win, leftcol)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    if view.leftcol ~= leftcol then
      view.leftcol = leftcol
      vim.fn.winrestview(view)
    end
  end)
end

local function clear_horizontal_sync_for_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  del_win_var(win, HORIZONTAL_SYNC_SESSION_VAR)
  del_win_var(win, HORIZONTAL_SYNC_PEER_VAR)
end

local function sync_horizontal_from_window(win)
  if config.get().diffview.sync_scroll == false then
    return
  end

  if horizontal_sync_guard then
    return
  end

  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  local session = get_win_var(win, HORIZONTAL_SYNC_SESSION_VAR)
  if type(session) ~= "number" then
    return
  end

  local peer_win = get_win_var(win, HORIZONTAL_SYNC_PEER_VAR)
  if type(peer_win) ~= "number" or not vim.api.nvim_win_is_valid(peer_win) then
    return
  end

  if get_win_var(peer_win, HORIZONTAL_SYNC_SESSION_VAR) ~= session then
    return
  end

  local source_leftcol = get_window_leftcol(win)
  local peer_leftcol = get_window_leftcol(peer_win)
  if source_leftcol == nil or peer_leftcol == nil or source_leftcol == peer_leftcol then
    return
  end

  horizontal_sync_guard = true
  local ok = pcall(set_window_leftcol, peer_win, source_leftcol)
  horizontal_sync_guard = false

  if not ok then
    clear_horizontal_sync_for_window(win)
    clear_horizontal_sync_for_window(peer_win)
  end
end

local function register_horizontal_sync(left_win, right_win)
  if config.get().diffview.sync_scroll == false then
    clear_horizontal_sync_for_window(left_win)
    clear_horizontal_sync_for_window(right_win)
    return
  end

  sync_session_seq = sync_session_seq + 1
  local session = sync_session_seq

  set_win_var(left_win, HORIZONTAL_SYNC_SESSION_VAR, session)
  set_win_var(right_win, HORIZONTAL_SYNC_SESSION_VAR, session)
  set_win_var(left_win, HORIZONTAL_SYNC_PEER_VAR, right_win)
  set_win_var(right_win, HORIZONTAL_SYNC_PEER_VAR, left_win)

  local right_leftcol = get_window_leftcol(right_win)
  if right_leftcol ~= nil then
    pcall(set_window_leftcol, left_win, right_leftcol)
  end
end

local horizontal_sync_group = vim.api.nvim_create_augroup("gitdx_diffview_horizontal_sync", { clear = true })

vim.api.nvim_create_autocmd("WinScrolled", {
  group = horizontal_sync_group,
  callback = function()
    if config.get().diffview.sync_scroll == false then
      return
    end

    local event = vim.v.event
    local seen = {}

    if type(event) == "table" then
      for key, _ in pairs(event) do
        if key ~= "all" then
          local win = tonumber(key)
          if win and win > 0 and not seen[win] then
            seen[win] = true
            sync_horizontal_from_window(win)
          end
        end
      end
    end

    if next(seen) == nil then
      sync_horizontal_from_window(vim.api.nvim_get_current_win())
    end
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = horizontal_sync_group,
  pattern = "netrw",
  callback = function(args)
    local tab = vim.api.nvim_get_current_tabpage()
    local has_active_diff = false
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
        has_active_diff = true
        break
      end
    end

    if not has_active_diff then
      return
    end

    local closed = false
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == args.buf then
        closed = pcall(vim.api.nvim_win_close, win, true) or closed
      end
    end

    if closed then
      util.notify("Ex/Explore is disabled during GitDxDiff. Close diff first with :GitDxDiffClose.", vim.log.levels.WARN)
    end
  end,
})

local function source_file_display_name(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function to_abs_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function infer_filetype(path)
  if not vim.filetype or not vim.filetype.match then
    return nil
  end

  local ok, filetype = pcall(vim.filetype.match, { filename = path })
  if not ok then
    return nil
  end

  return filetype
end

local function set_unique_buffer_name(buf, preferred_name)
  if type(preferred_name) ~= "string" or preferred_name == "" then
    return
  end

  local function try_set(name)
    local existing = vim.fn.bufnr(name, false)
    if existing >= 0 and existing ~= buf then
      return false
    end

    local ok = pcall(vim.api.nvim_buf_set_name, buf, name)
    return ok
  end

  if try_set(preferred_name) then
    return
  end

  for index = 2, 1000 do
    local candidate = string.format("%s {%d}", preferred_name, index)
    if try_set(candidate) then
      return
    end
  end
end

local function create_ref_buffer(path, lines, ref, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  local buf_name = string.format("%s [%s]", source_file_display_name(path), ref)

  set_unique_buffer_name(buf, buf_name)

  local content = lines
  if #content == 0 then
    content = { "" }
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  if filetype and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end

  vim.b[buf].gitdx_diff_ephemeral = true

  return buf
end

local function create_left_buffer(source_buf, base_lines, ref)
  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_name = string.format("%s [%s]", source_file_display_name(source_name), ref)

  set_unique_buffer_name(left_buf, left_name)

  local lines = base_lines
  if #lines == 0 then
    lines = { "" }
  end

  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].undofile = false
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true

  local filetype = vim.bo[source_buf].filetype
  if filetype and filetype ~= "" then
    vim.bo[left_buf].filetype = filetype
  end

  vim.b[left_buf].gitdx_diff_base = true

  return left_buf
end

local function create_deleted_source_buffer(source_path)
  local source_buf = vim.api.nvim_create_buf(false, true)
  local display_name = string.format("%s [working tree deleted]", source_file_display_name(source_path))

  set_unique_buffer_name(source_buf, display_name)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "" })
  vim.bo[source_buf].buftype = "nofile"
  vim.bo[source_buf].bufhidden = "wipe"
  vim.bo[source_buf].swapfile = false
  vim.bo[source_buf].undofile = false
  vim.bo[source_buf].modifiable = false
  vim.bo[source_buf].readonly = true

  local inferred = infer_filetype(source_path)
  if inferred and inferred ~= "" then
    vim.bo[source_buf].filetype = inferred
  end

  vim.b[source_buf].gitdx_diff_ephemeral = true

  return source_buf
end

local function resolve_source(opts)
  if opts.path then
    local source_path = to_abs_path(opts.path)
    if opts.deleted then
      return create_deleted_source_buffer(source_path), source_path, nil, { 1, 0 }
    end

    local source_buf = vim.fn.bufnr(source_path, false)
    if source_buf < 0 then
      source_buf = vim.fn.bufadd(source_path)
      pcall(vim.fn.bufload, source_buf)
    end

    return source_buf, source_path, nil, { 1, 0 }
  end

  local source_buf = vim.api.nvim_get_current_buf()
  if not util.is_regular_buffer(source_buf) then
    return nil, nil, "Current buffer is not a file on disk"
  end

  local source_path = vim.api.nvim_buf_get_name(source_buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return source_buf, source_path, nil, cursor
end

local function resolve_ref_compare_target(opts)
  if opts.path then
    local source_path = to_abs_path(opts.path)
    local filetype = infer_filetype(source_path)

    local source_buf = vim.fn.bufnr(source_path, false)
    if source_buf >= 0 and vim.api.nvim_buf_is_valid(source_buf) then
      local loaded_filetype = vim.bo[source_buf].filetype
      if loaded_filetype and loaded_filetype ~= "" then
        filetype = loaded_filetype
      end
    end

    return {
      path = source_path,
      filetype = filetype,
      cursor = { 1, 0 },
    }, nil
  end

  local source_buf = vim.api.nvim_get_current_buf()
  if util.is_regular_buffer(source_buf) then
    return {
      path = vim.api.nvim_buf_get_name(source_buf),
      filetype = vim.bo[source_buf].filetype,
      cursor = vim.api.nvim_win_get_cursor(0),
    }, nil
  end

  local tab = vim.api.nvim_get_current_tabpage()
  local state = get_tab_var(tab, DIFF_STATE_TAB_VAR)
  if type(state) == "table" and type(state.source_path) == "string" and state.source_path ~= "" then
    local source_path = to_abs_path(state.source_path)
    local filetype = infer_filetype(source_path)
    local cursor = { 1, 0 }

    local right_win = tonumber(state.right_win)
    if right_win and right_win > 0 and vim.api.nvim_win_is_valid(right_win) then
      cursor = vim.api.nvim_win_get_cursor(right_win)
      local right_buf = vim.api.nvim_win_get_buf(right_win)
      local loaded_filetype = vim.bo[right_buf].filetype
      if loaded_filetype and loaded_filetype ~= "" then
        filetype = loaded_filetype
      end
    end

    return {
      path = source_path,
      filetype = filetype,
      cursor = cursor,
    }, nil
  end

  local alternate = vim.fn.bufnr("#")
  if type(alternate) == "number" and alternate > 0 and util.is_regular_buffer(alternate) then
    return {
      path = vim.api.nvim_buf_get_name(alternate),
      filetype = vim.bo[alternate].filetype,
      cursor = { 1, 0 },
    }, nil
  end

  return nil, "Current buffer is not a file on disk; pass [path]"
end

local function apply_diff_window_style(win)
  local win_cfg = config.get().diffview
  local sync_scroll = win_cfg.sync_scroll ~= false
  if get_win_var(win, PREV_WINHIGHLIGHT_VAR) == nil then
    set_win_var(win, PREV_WINHIGHLIGHT_VAR, vim.wo[win].winhighlight or "")
  end
  if get_win_var(win, PREV_WINFIXBUF_VAR) == nil then
    set_win_var(win, PREV_WINFIXBUF_VAR, vim.wo[win].winfixbuf == true)
  end

  vim.wo[win].diff = true
  vim.wo[win].scrollbind = sync_scroll
  vim.wo[win].cursorbind = sync_scroll
  vim.wo[win].wrap = false
  vim.wo[win].winfixbuf = true
  vim.wo[win].winhighlight = win_cfg.winhighlight
end

local function set_window_buffer(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return false, "Window is no longer valid"
  end

  local was_locked = vim.wo[win].winfixbuf == true
  if was_locked then
    vim.wo[win].winfixbuf = false
  end

  local ok, err = pcall(vim.api.nvim_win_set_buf, win, buf)

  if was_locked and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winfixbuf = true
  end

  if not ok then
    return false, tostring(err)
  end

  return true
end

local function tab_has_active_diff(tabpage)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      return true
    end
  end

  return false
end

local function get_diff_state(tabpage)
  local state = get_tab_var(tabpage, DIFF_STATE_TAB_VAR)
  if type(state) ~= "table" then
    return nil
  end

  return state
end

local function resolve_source_path_from_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if type(name) ~= "string" or name == "" then
    return nil
  end

  return name
end

local function relpath(root, path)
  if not root or root == "" or not path or path == "" then
    return nil
  end

  if vim.fs and vim.fs.relpath then
    local ok, relative = pcall(vim.fs.relpath, root, path)
    if ok and type(relative) == "string" and relative ~= "" then
      return relative
    end
  end

  local prefix = root
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end

  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end

  return nil
end

local function build_stats_from_hunks(hunks)
  local stats = {
    added = 0,
    changed = 0,
    deleted = 0,
  }

  for _, hunk in ipairs(hunks) do
    if hunk.type == "add" then
      stats.added = stats.added + (tonumber(hunk.count_new) or 0)
    elseif hunk.type == "change" then
      stats.changed = stats.changed + (tonumber(hunk.count_new) or 0)
    elseif hunk.type == "delete" then
      stats.deleted = stats.deleted + (tonumber(hunk.count_old) or 0)
    end
  end

  return stats
end

local function resolve_diff_buffers_from_state(tabpage, state)
  if type(state) ~= "table" then
    return nil, nil, "No active GitDx diff view in current tab"
  end

  local left_buf = nil
  local right_buf = nil

  if type(state.left_win) == "number" and vim.api.nvim_win_is_valid(state.left_win) then
    left_buf = vim.api.nvim_win_get_buf(state.left_win)
  end

  if type(state.right_win) == "number" and vim.api.nvim_win_is_valid(state.right_win) then
    right_buf = vim.api.nvim_win_get_buf(state.right_win)
  end

  if (not left_buf or not vim.api.nvim_buf_is_valid(left_buf)) and type(state.left_buf) == "number" then
    if vim.api.nvim_buf_is_valid(state.left_buf) then
      left_buf = state.left_buf
    end
  end

  if (not right_buf or not vim.api.nvim_buf_is_valid(right_buf)) and type(state.source_buf) == "number" then
    if vim.api.nvim_buf_is_valid(state.source_buf) then
      right_buf = state.source_buf
    end
  end

  if not left_buf or not vim.api.nvim_buf_is_valid(left_buf) then
    return nil, nil, "Unable to resolve left diff buffer"
  end

  if not right_buf or not vim.api.nvim_buf_is_valid(right_buf) then
    return nil, nil, "Unable to resolve right diff buffer"
  end

  return left_buf, right_buf
end

local function resolve_source_window(tabpage, state)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_tabpage(current_win) == tabpage then
    local current_buf = vim.api.nvim_win_get_buf(current_win)
    if vim.b[current_buf] and vim.b[current_buf].gitdx_diff_source then
      return current_win
    end
  end

  if state and type(state.right_win) == "number" and vim.api.nvim_win_is_valid(state.right_win) then
    return state.right_win
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf] and vim.b[buf].gitdx_diff_source then
        return win
      end
    end
  end

  return nil
end

local function get_edit_target(tabpage)
  local state = get_diff_state(tabpage) or {}
  local source_win = resolve_source_window(tabpage, state)
  local cursor = nil
  local source_path = state.source_path

  if source_win and vim.api.nvim_win_is_valid(source_win) then
    cursor = vim.api.nvim_win_get_cursor(source_win)
    source_path = source_path or resolve_source_path_from_buffer(vim.api.nvim_win_get_buf(source_win))
  end

  if not source_path and type(state.source_buf) == "number" then
    source_path = resolve_source_path_from_buffer(state.source_buf)
  end

  if not source_path or source_path == "" then
    return nil, "Unable to resolve source file for GitDx diff view"
  end

  local line = 1
  local col = 0
  if type(cursor) == "table" then
    line = math.max(1, tonumber(cursor[1]) or 1)
    col = math.max(0, tonumber(cursor[2]) or 0)
  end

  return {
    path = source_path,
    line = line,
    col = col,
  }
end

function M.open(opts)
  opts = opts or {}
  local source_buf, source_path, err, cursor = resolve_source(opts)
  if not source_buf then
    util.notify(err or "Unable to resolve source buffer", vim.log.levels.WARN)
    return
  end

  local ref = opts.ref or config.get().ref
  local base_path = opts.base_path and to_abs_path(opts.base_path) or source_path

  local base, err = git.get_base(base_path, ref, {
    force_ref_read = opts.base_path ~= nil,
  })
  if not base then
    util.notify(err or "Unable to open diff view", vim.log.levels.ERROR)
    return
  end

  if config.get().diffview.open_in_tab == false and M.is_active() then
    M.close()
  end

  local opened_diff_tab = false
  if config.get().diffview.open_in_tab then
    vim.cmd("tabnew")
    opened_diff_tab = true
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  set_tab_var(current_tab, DIFF_OWNED_TAB_VAR, opened_diff_tab)

  local left_win = vim.api.nvim_get_current_win()
  local left_buf = create_left_buffer(source_buf, base.lines, ref)
  local ok_left, left_err = set_window_buffer(left_win, left_buf)
  if not ok_left then
    util.notify("Unable to open left diff pane (" .. tostring(left_err) .. ")", vim.log.levels.ERROR)
    return
  end

  -- Keep semantic layout stable: base on the left, working tree on the right,
  -- regardless of user 'splitright' setting.
  vim.cmd("rightbelow vsplit")

  local right_win = vim.api.nvim_get_current_win()
  local ok_right, right_err = set_window_buffer(right_win, source_buf)
  if not ok_right then
    util.notify("Unable to open right diff pane (" .. tostring(right_err) .. ")", vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_win_set_cursor(right_win, cursor)

  vim.b[source_buf].gitdx_diff_source = true

  ensure_hiddenoff_diffopt()
  apply_diff_window_style(left_win)
  apply_diff_window_style(right_win)
  register_horizontal_sync(left_win, right_win)

  set_tab_var(current_tab, DIFF_STATE_TAB_VAR, {
    left_win = left_win,
    right_win = right_win,
    left_buf = left_buf,
    source_buf = source_buf,
    source_path = source_path,
    ref = ref,
  })
  block_explore_commands_for_state(get_diff_state(current_tab))

  if config.get().diffview.keep_focus == "left" then
    vim.api.nvim_set_current_win(left_win)
  else
    vim.api.nvim_set_current_win(right_win)
  end

  sync_live_window_decorations()
end

function M.open_between_refs(opts)
  opts = opts or {}

  local from_ref = util.trim(opts.from_ref)
  local to_ref = util.trim(opts.to_ref)
  if from_ref == "" or to_ref == "" then
    util.notify("Usage: :GitDxDiff <from_ref> <to_ref> [path]", vim.log.levels.WARN)
    return
  end

  local target, target_err = resolve_ref_compare_target(opts)
  if not target then
    util.notify(target_err or "Unable to resolve source file", vim.log.levels.WARN)
    return
  end

  local from_path = opts.from_path and to_abs_path(opts.from_path) or target.path
  local to_path = opts.to_path and to_abs_path(opts.to_path) or target.path

  local repo_root = git.find_repo_root(from_path)
  if not repo_root then
    util.notify("File is outside a Git repository", vim.log.levels.WARN)
    return
  end

  local right_repo_root = git.find_repo_root(to_path)
  if not right_repo_root then
    util.notify("File is outside a Git repository", vim.log.levels.WARN)
    return
  end

  if right_repo_root ~= repo_root then
    util.notify("Both compare paths must be inside the same Git repository", vim.log.levels.WARN)
    return
  end

  if not git.ref_exists(repo_root, from_ref) then
    util.notify("Unknown Git ref: " .. from_ref, vim.log.levels.WARN)
    return
  end

  if not git.ref_exists(repo_root, to_ref) then
    util.notify("Unknown Git ref: " .. to_ref, vim.log.levels.WARN)
    return
  end

  local left_base, left_err = git.get_base(from_path, from_ref, {
    force_ref_read = true,
  })
  if not left_base then
    util.notify(left_err or "Unable to read left ref", vim.log.levels.ERROR)
    return
  end

  local right_base, right_err = git.get_base(to_path, to_ref, {
    force_ref_read = true,
  })
  if not right_base then
    util.notify(right_err or "Unable to read right ref", vim.log.levels.ERROR)
    return
  end

  if config.get().diffview.open_in_tab == false and M.is_active() then
    M.close()
  end

  local opened_diff_tab = false
  if config.get().diffview.open_in_tab then
    vim.cmd("tabnew")
    opened_diff_tab = true
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  set_tab_var(current_tab, DIFF_OWNED_TAB_VAR, opened_diff_tab)

  local left_filetype = infer_filetype(from_path)
  local right_filetype = target.filetype or infer_filetype(to_path)
  if not left_filetype or left_filetype == "" then
    left_filetype = right_filetype
  end
  if not right_filetype or right_filetype == "" then
    right_filetype = left_filetype
  end

  local left_win = vim.api.nvim_get_current_win()
  local left_buf = create_ref_buffer(from_path, left_base.lines, from_ref, left_filetype)
  vim.b[left_buf].gitdx_diff_base = true
  local ok_left, left_err = set_window_buffer(left_win, left_buf)
  if not ok_left then
    util.notify("Unable to open left diff pane (" .. tostring(left_err) .. ")", vim.log.levels.ERROR)
    return
  end

  -- Keep semantic layout stable: first ref on the left, second ref on the right,
  -- regardless of user 'splitright' setting.
  vim.cmd("rightbelow vsplit")

  local right_win = vim.api.nvim_get_current_win()
  local right_buf = create_ref_buffer(to_path, right_base.lines, to_ref, right_filetype)
  local ok_right, right_err = set_window_buffer(right_win, right_buf)
  if not ok_right then
    util.notify("Unable to open right diff pane (" .. tostring(right_err) .. ")", vim.log.levels.ERROR)
    return
  end

  local right_line_count = vim.api.nvim_buf_line_count(right_buf)
  local target_line = 1
  local target_col = 0
  if type(target.cursor) == "table" then
    target_line = math.max(1, tonumber(target.cursor[1]) or 1)
    target_col = math.max(0, tonumber(target.cursor[2]) or 0)
  end
  target_line = math.min(target_line, math.max(1, right_line_count))
  pcall(vim.api.nvim_win_set_cursor, right_win, { target_line, target_col })

  vim.b[right_buf].gitdx_diff_source = true

  ensure_hiddenoff_diffopt()
  apply_diff_window_style(left_win)
  apply_diff_window_style(right_win)
  register_horizontal_sync(left_win, right_win)

  set_tab_var(current_tab, DIFF_STATE_TAB_VAR, {
    left_win = left_win,
    right_win = right_win,
    left_buf = left_buf,
    source_buf = right_buf,
    source_path = to_path,
    ref = from_ref,
    right_ref = to_ref,
  })
  block_explore_commands_for_state(get_diff_state(current_tab))

  if config.get().diffview.keep_focus == "left" then
    vim.api.nvim_set_current_win(left_win)
  else
    vim.api.nvim_set_current_win(right_win)
  end

  sync_live_window_decorations()
end

function M.is_active(tabpage)
  local target_tab = tabpage
  if not target_tab or target_tab == 0 then
    target_tab = vim.api.nvim_get_current_tabpage()
  end

  if not vim.api.nvim_tabpage_is_valid(target_tab) then
    return false
  end

  return tab_has_active_diff(target_tab)
end

function M.get_hunks(tabpage)
  local target_tab = tabpage
  if not target_tab or target_tab == 0 then
    target_tab = vim.api.nvim_get_current_tabpage()
  end

  if not vim.api.nvim_tabpage_is_valid(target_tab) then
    return nil, "Invalid tabpage"
  end

  local state = get_diff_state(target_tab)
  local left_buf, right_buf, resolve_err = resolve_diff_buffers_from_state(target_tab, state)
  if not left_buf then
    return nil, resolve_err
  end

  local left_lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
  local right_lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
  local hunks = git.compute_hunks(left_lines, right_lines)
  local stats = build_stats_from_hunks(hunks)

  local path = type(state) == "table" and state.source_path or nil
  if not path or path == "" then
    path = resolve_source_path_from_buffer(right_buf)
  end
  if not path or path == "" then
    path = resolve_source_path_from_buffer(left_buf)
  end

  if not path or path == "" then
    return nil, "Unable to resolve source file for GitDx diff view"
  end

  local repo_root = git.find_repo_root(path)
  local info = {
    path = path,
    relpath = relpath(repo_root, path),
    repo_root = repo_root,
    ref = type(state) == "table" and state.ref or nil,
    right_ref = type(state) == "table" and state.right_ref or nil,
    mode = (type(state) == "table" and state.right_ref) and "refs" or "working",
  }

  return vim.deepcopy(hunks), vim.deepcopy(stats), info
end

function M.close()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local state = get_diff_state(current_tab)
  local owns_tab = get_tab_var(current_tab, DIFF_OWNED_TAB_VAR) == true

  if owns_tab then
    unblock_explore_commands_for_state(state)
    local ok, err = pcall(vim.cmd, "tabclose")
    if ok then
      maybe_restore_hiddenoff_diffopt()
      return
    end

    util.notify(
      "Unable to close GitDx diff tab; closing diff windows instead (" .. tostring(err) .. ")",
      vim.log.levels.WARN
    )
  end

  local wins = vim.api.nvim_tabpage_list_wins(0)
  if not tab_has_active_diff(current_tab) then
    util.notify("No active diff windows in current tab", vim.log.levels.WARN)
    return
  end

  for _, win in ipairs(wins) do
    clear_horizontal_sync_for_window(win)
  end

  vim.cmd("diffoff!")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    restore_diff_window_style(win)
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local is_gitdx_tmp = vim.b[buf] and (vim.b[buf].gitdx_diff_base or vim.b[buf].gitdx_diff_ephemeral)
    if is_gitdx_tmp and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  unblock_explore_commands_for_state(state)
  del_tab_var(current_tab, DIFF_OWNED_TAB_VAR)
  del_tab_var(current_tab, DIFF_STATE_TAB_VAR)

  maybe_restore_hiddenoff_diffopt()
  sync_live_window_decorations()
end

function M.close_and_edit()
  local current_tab = vim.api.nvim_get_current_tabpage()
  if not tab_has_active_diff(current_tab) then
    util.notify("No active diff windows in current tab", vim.log.levels.WARN)
    return
  end

  local target, err = get_edit_target(current_tab)
  if not target then
    util.notify(err or "Unable to resolve file for edit", vim.log.levels.WARN)
    return
  end

  M.close()

  local escaped = vim.fn.fnameescape(target.path)
  local ok, open_err = pcall(vim.cmd, "tabedit " .. escaped)
  if not ok then
    util.notify("Unable to open source file (" .. tostring(open_err) .. ")", vim.log.levels.ERROR)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  local target_line = math.min(math.max(1, target.line or 1), math.max(1, line_count))
  local target_col = math.max(0, target.col or 0)
  pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })
end

return M
