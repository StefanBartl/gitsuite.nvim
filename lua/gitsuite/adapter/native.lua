---@module 'gitsuite.adapter.native'
--- The always-available fallback adapter: needs nothing but `git` on `$PATH`
--- (via `lib.nvim.git`/`lib.nvim.cross.run_argv`, both argv-only per SEC-01).
--- No external git-UI plugin required -- every feature family that has a
--- native implementation stays usable even with zero adapter plugins
--- installed, the same property `filetree.nvim` has over netrw.

---@type GitSuite.Adapter
local M = { name = "native" }

---Always available: this adapter only depends on `git` itself, not on any
---other Neovim plugin.
---@return boolean
function M.is_available()
  return require("lib.nvim.git").in_git_repo()
end

return M
