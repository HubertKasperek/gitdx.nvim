local M = {}

local uv = vim.uv or vim.loop
local unpack_fn = table.unpack or unpack

function M.trim(value)
  if value == nil then
    return ""
  end

  return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.split_lines(text)
  if not text or text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.notify(message, level)
  vim.notify("gitdx.nvim: " .. message, level or vim.log.levels.INFO)
end

function M.is_regular_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end

  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false
  end

  if name:match("^%w+://") then
    return false
  end

  return true
end

function M.close_timer(timer)
  if not timer then
    return
  end

  pcall(function()
    timer:stop()
  end)

  pcall(function()
    if timer.is_closing then
      if not timer:is_closing() then
        timer:close()
      end
      return
    end

    timer:close()
  end)
end

function M.debounce(fn, timeout_ms)
  local timer = uv.new_timer()

  local function wrapped(...)
    local argv = { ... }
    timer:stop()
    timer:start(timeout_ms, 0, vim.schedule_wrap(function()
      fn(unpack_fn(argv))
    end))
  end

  local function stop()
    M.close_timer(timer)
  end

  return wrapped, stop
end

return M
