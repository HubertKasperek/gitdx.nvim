local util = require("gitdx.util")

local M = {}
local unpack_fn = table.unpack or unpack

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

function M.find_repo_root(path)
  local file_path = abs_path(path)
  local dir = vim.fs.dirname(file_path)
  local code, stdout = run_command({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if code ~= 0 then
    return nil
  end

  local root = util.trim(stdout)
  if root == "" then
    return nil
  end

  return root
end

function M.is_tracked(repo_root, relative_path)
  local code = run_git(repo_root, { "ls-files", "--error-unmatch", "--", relative_path })
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

function M.get_base(path, ref)
  local root = M.find_repo_root(path)
  if not root then
    return nil, "File is outside a Git repository"
  end

  local absolute_path = abs_path(path)
  local relative_path = relpath(root, absolute_path)

  local lines = {}
  local tracked = M.is_tracked(root, relative_path)
  if tracked then
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
