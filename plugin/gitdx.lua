if vim.g.loaded_gitdx == 1 then
  return
end

vim.g.loaded_gitdx = 1

vim.schedule(function()
  local ok, gitdx = pcall(require, "gitdx")
  if not ok then
    return
  end

  if not gitdx.is_setup() then
    gitdx.setup()
  end
end)
