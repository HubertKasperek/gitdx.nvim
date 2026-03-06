local util = require("gitdx.util")

local M = {}
local unpack_fn = table.unpack or unpack
local conflict_pairs = {
  DD = true,
  AU = true,
  UD = true,
  UA = true,
  DU = true,
  AA = true,
  UU = true,
}

local function run_command(argv)
  if vim.system then
    local result = vim.system(argv, { text = true }):wait()
    return result.code, result.stdout or "", result.stderr or ""
  end

  local output = vim.fn.system(argv)
  return vim.v.shell_error, output or "", ""
end

local function run_git(repo_root, args)
  local argv = { "git", "-C", repo_root }
  vim.list_extend(argv, args)
  return run_command(argv)
end

local function abs_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function normalize_abs_path(path)
  local absolute = abs_path(path)
  if #absolute > 1 and absolute:match("[/\\]$") then
    absolute = absolute:sub(1, -2)
  end
  return absolute
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end

  return vim.fn.fnamemodify(path, ":h")
end

local function is_directory(path)
  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function relpath(root, path)
  if vim.fs and vim.fs.relpath then
    local ok, relative = pcall(vim.fs.relpath, root, path)
    if ok and relative then
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

  return path
end

function M.find_repo_root_from(path)
  local start_path = normalize_abs_path(path or vim.fn.getcwd())
  local dir = start_path
  if not is_directory(start_path) then
    dir = dirname(start_path)
  end

  local code, stdout = run_command({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if code ~= 0 then
    return nil
  end

  local root = util.trim(stdout)
  if root == "" then
    return nil
  end

  return normalize_abs_path(root)
end

function M.find_repo_root(path)
  return M.find_repo_root_from(path)
end

function M.ref_exists(repo_root, ref)
  if type(repo_root) ~= "string" or repo_root == "" then
    return false
  end

  if type(ref) ~= "string" or util.trim(ref) == "" then
    return false
  end

  local code = run_git(repo_root, {
    "rev-parse",
    "--verify",
    "--quiet",
    ref .. "^{commit}",
  })

  return code == 0
end

function M.is_tracked(repo_root, relative_path)
  local code = run_git(repo_root, { "ls-files", "--error-unmatch", "--", relative_path })
  return code == 0
end

function M.is_ignored(repo_root, relative_path)
  if type(repo_root) ~= "string" or repo_root == "" then
    return false
  end

  if type(relative_path) ~= "string" or util.trim(relative_path) == "" then
    return false
  end

  local code = run_git(repo_root, {
    "check-ignore",
    "--quiet",
    "--",
    relative_path,
  })

  return code == 0
end

function M.read_file_at_ref(repo_root, relative_path, ref)
  local object = string.format("%s:%s", ref, relative_path)
  local code, stdout = run_git(repo_root, { "--no-pager", "show", object })

  if code ~= 0 then
    return {}
  end

  return util.split_lines(stdout)
end

function M.get_base(path, ref, opts)
  opts = opts or {}

  local root = M.find_repo_root(path)
  if not root then
    return nil, "File is outside a Git repository"
  end

  local absolute_path = abs_path(path)
  local relative_path = relpath(root, absolute_path)

  local lines = {}
  local tracked = M.is_tracked(root, relative_path)
  local ignored = false
  if not tracked and not opts.force_ref_read then
    ignored = M.is_ignored(root, relative_path)
  end

  if ignored then
    return nil, "File is ignored by Git (.gitignore)"
  end

  if tracked or opts.force_ref_read then
    lines = M.read_file_at_ref(root, relative_path, ref)
  end

  return {
    repo_root = root,
    relpath = relative_path,
    tracked = tracked,
    lines = lines,
    ref = ref,
  }
end

local function split_null_terminated(text)
  local items = {}
  local from = 1

  while true do
    local at = text:find("\0", from, true)
    if not at then
      break
    end

    table.insert(items, text:sub(from, at - 1))
    from = at + 1
  end

  if from <= #text then
    table.insert(items, text:sub(from))
  end

  return items
end

local function normalize_status(index_status, worktree_status)
  local pair = (index_status or " ") .. (worktree_status or " ")
  if conflict_pairs[pair] then
    return "U"
  end

  if index_status == "?" and worktree_status == "?" then
    return "A"
  end

  if index_status == "R" or worktree_status == "R" or index_status == "C" or worktree_status == "C" then
    return "R"
  end

  if index_status == "D" or worktree_status == "D" then
    return "D"
  end

  if index_status == "A" or worktree_status == "A" then
    return "A"
  end

  return "M"
end

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    if a.path == b.path then
      return a.status < b.status
    end

    return a.path < b.path
  end)
end

local function list_worktree_entries(repo_root)
  local code, stdout, stderr = run_git(repo_root, {
    "--no-pager",
    "status",
    "--porcelain=1",
    "--untracked-files=all",
    "-z",
  })

  if code ~= 0 then
    return nil, util.trim(stderr) ~= "" and util.trim(stderr) or "Unable to read Git status"
  end

  local records = split_null_terminated(stdout)
  local entries = {}
  local i = 1

  while i <= #records do
    local record = records[i]
    i = i + 1

    if record and record ~= "" then
      local index_status = record:sub(1, 1)
      local worktree_status = record:sub(2, 2)
      local path = record:sub(4)
      local old_path = nil

      if index_status == "R" or worktree_status == "R" or index_status == "C" or worktree_status == "C" then
        old_path = records[i] or old_path
        i = i + 1
      end

      if path and path ~= "" then
        local status = normalize_status(index_status, worktree_status)
        table.insert(entries, {
          status = status,
          path = path,
          old_path = old_path,
          abs_path = abs_path(repo_root .. "/" .. path),
          repo_root = repo_root,
          conflict = status == "U",
          staged = index_status ~= " " and index_status ~= "?",
          unstaged = worktree_status ~= " " and worktree_status ~= "?",
        })
      end
    end
  end

  sort_entries(entries)

  return entries
end

local function scan_root_from(start_path)
  local absolute = normalize_abs_path(start_path or vim.fn.getcwd())
  if is_directory(absolute) then
    return absolute
  end

  local parent = dirname(absolute)
  if not parent or parent == "" then
    return absolute
  end

  return normalize_abs_path(parent)
end

local function find_descendant_repo_roots(scan_root)
  local results = {}
  local seen = {}

  local function add_repo_root(root)
    if not root or root == "" then
      return
    end

    local normalized = normalize_abs_path(root)
    if normalized == "" or seen[normalized] then
      return
    end

    seen[normalized] = true
    table.insert(results, normalized)
  end

  if not vim.fs or type(vim.fs.find) ~= "function" then
    return results
  end

  -- Keep discovery bounded to avoid long UI stalls in very large trees.
  local find_limit = 100000
  for _, marker_type in ipairs({ "directory", "file" }) do
    local markers = vim.fs.find(".git", {
      path = scan_root,
      type = marker_type,
      limit = find_limit,
    })

    for _, marker in ipairs(markers) do
      local repo_dir = dirname(marker)
      local repo_root = M.find_repo_root_from(repo_dir)
      if repo_root then
        add_repo_root(repo_root)
      end
    end
  end

  table.sort(results)
  return results
end

function M.list_changes(start_path)
  local root_probe_path = start_path or vim.fn.getcwd()
  local repo_root = M.find_repo_root_from(root_probe_path)

  if repo_root then
    local entries, err = list_worktree_entries(repo_root)
    if not entries then
      return nil, err
    end

    return {
      repo_root = repo_root,
      entries = entries,
      repo_count = 1,
    }
  end

  local workspace_root = scan_root_from(root_probe_path)
  local repo_roots = find_descendant_repo_roots(workspace_root)
  if #repo_roots == 0 then
    return nil, "Current directory is outside a Git repository"
  end

  local repositories = {}
  local merged_entries = {}

  for _, child_root in ipairs(repo_roots) do
    local entries, err = list_worktree_entries(child_root)
    if not entries then
      return nil, err
    end

    if #entries > 0 then
      local repo_relpath = relpath(workspace_root, child_root)
      table.insert(repositories, {
        repo_root = child_root,
        relpath = repo_relpath,
        entries = entries,
      })
      vim.list_extend(merged_entries, entries)
    end
  end

  table.sort(repositories, function(a, b)
    return (a.relpath or a.repo_root or "") < (b.relpath or b.repo_root or "")
  end)

  return {
    repo_root = workspace_root,
    entries = merged_entries,
    repos = repositories,
    repo_count = #repo_roots,
    workspace_mode = true,
  }
end

function M.list_ref_changes(start_path, from_ref, to_ref)
  local repo_root = M.find_repo_root_from(start_path or vim.fn.getcwd())
  if not repo_root then
    return nil, "Current directory is outside a Git repository"
  end

  from_ref = util.trim(from_ref)
  to_ref = util.trim(to_ref)
  if from_ref == "" or to_ref == "" then
    return nil, "Usage: <from_ref> <to_ref>"
  end

  if not M.ref_exists(repo_root, from_ref) then
    return nil, "Unknown Git ref: " .. from_ref
  end

  if not M.ref_exists(repo_root, to_ref) then
    return nil, "Unknown Git ref: " .. to_ref
  end

  local code, stdout, stderr = run_git(repo_root, {
    "--no-pager",
    "diff",
    "--name-status",
    "--find-renames",
    "-z",
    from_ref,
    to_ref,
    "--",
  })

  if code ~= 0 then
    return nil, util.trim(stderr) ~= "" and util.trim(stderr) or "Unable to read Git diff between refs"
  end

  local records = split_null_terminated(stdout)
  local entries = {}
  local i = 1

  while i <= #records do
    local status_token = records[i]
    i = i + 1

    if status_token and status_token ~= "" then
      local status_code = status_token:sub(1, 1)

      if status_code == "R" or status_code == "C" then
        local old_path = records[i] or ""
        local new_path = records[i + 1] or ""
        i = i + 2

        if new_path ~= "" then
          table.insert(entries, {
            status = "R",
            path = new_path,
            old_path = old_path ~= "" and old_path or nil,
            abs_path = abs_path(repo_root .. "/" .. new_path),
            repo_root = repo_root,
          })
        end
      else
        local path = records[i] or ""
        i = i + 1

        if path ~= "" then
          local status = status_code
          if status ~= "A" and status ~= "M" and status ~= "D" then
            status = "M"
          end

          table.insert(entries, {
            status = status,
            path = path,
            abs_path = abs_path(repo_root .. "/" .. path),
            repo_root = repo_root,
          })
        end
      end
    end
  end

  sort_entries(entries)

  return {
    repo_root = repo_root,
    entries = entries,
    from_ref = from_ref,
    to_ref = to_ref,
  }
end

function M.compute_hunks(old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n")
  local new_text = table.concat(new_lines, "\n")

  local ok, indices = pcall(vim.diff, old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
  })

  if not ok or type(indices) ~= "table" then
    return {}
  end

  local hunks = {}

  for _, index in ipairs(indices) do
    local start_old, count_old, start_new, count_new = unpack_fn(index)

    local hunk_type
    if count_old == 0 and count_new > 0 then
      hunk_type = "add"
    elseif count_old > 0 and count_new == 0 then
      hunk_type = "delete"
    else
      hunk_type = "change"
    end

    table.insert(hunks, {
      type = hunk_type,
      start_old = start_old,
      count_old = count_old,
      start_new = start_new,
      count_new = count_new,
    })
  end

  return hunks
end

return M
