local util = require("gitdx.util")

local M = {}

local function resolve_bufnr(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end

  return bufnr
end

local function is_conflict_start(line)
  return line:match("^<<<<<<<") ~= nil
end

local function is_conflict_divider(line)
  return line:match("^=======$") ~= nil
end

local function is_conflict_end(line)
  return line:match("^>>>>>>>") ~= nil
end

local function parse_ranges(lines)
  local ranges = {}
  local current = nil

  for lnum, line in ipairs(lines) do
    if not current then
      if is_conflict_start(line) then
        current = {
          start_line = lnum,
          divider_line = nil,
          end_line = nil,
          complete = false,
        }
      end
    else
      if not current.divider_line and is_conflict_divider(line) then
        current.divider_line = lnum
      end

      if is_conflict_end(line) then
        current.end_line = lnum
        current.complete = true
        table.insert(ranges, current)
        current = nil
      end
    end
  end

  if current then
    current.end_line = #lines
    table.insert(ranges, current)
  end

  return ranges
end

function M.get_ranges_for_lines(lines)
  if type(lines) ~= "table" then
    return {}
  end

  return parse_ranges(lines)
end

function M.get_buffer_ranges(bufnr)
  bufnr = resolve_bufnr(bufnr)

  if not util.is_regular_buffer(bufnr) then
    return nil, "Current buffer is not a file on disk"
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ranges = parse_ranges(lines)

  return ranges, {
    bufnr = bufnr,
    path = path,
    relpath = vim.fn.fnamemodify(path, ":~:."),
  }
end

function M.get_file_ranges(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  local ok, lines = pcall(vim.fn.readfile, abs)
  if not ok then
    return nil, string.format("Unable to read file: %s", abs)
  end

  local ranges = parse_ranges(lines)
  return ranges, {
    path = abs,
    relpath = vim.fn.fnamemodify(abs, ":~:."),
  }
end

return M
