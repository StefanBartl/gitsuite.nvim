---@module 'gitsuite.adapter.lazygit'
--- Adapter for the `lazygit` CLI tool itself -- not a Neovim plugin. Replaces
--- kdheepak/lazygit.nvim entirely: gitsuite.nvim owns the floating-terminal
--- spawn and the `nvr` bridge (`features/ui/lazygit/`, phase 3), so
--- availability is a plain `executable()` check, not `package.loaded`.

---@class GitSuite.Adapter.Lazygit: GitSuite.Adapter
local M = { name = "lazygit" }

---@return boolean
function M.is_available()
  return vim.fn.executable("lazygit") == 1
end

return M
