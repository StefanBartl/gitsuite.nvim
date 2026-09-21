---@module 'gitsuite'
--- Public entry point for gitsuite.nvim.
---
--- Bootstraps the plugin: merges config, registers the `:Git` command tree,
--- keymaps and autocmds. Idempotent -- the first call wins and later calls
--- are no-ops (PRINCIPLES.md "Feature-Module als Einheit").
---
--- Example: >lua
---   require("gitsuite").setup({
---     keymaps = { blame_full = "<leader>gb", ui_lazygit = "<leader>lg" },
---   })
--- <

local M = {}

---@type boolean
local _setup_done = false

---Configure and activate gitsuite.nvim.
---@param user_opts? GitSuite.Opts
---@return nil
function M.setup(user_opts)
  if _setup_done then return end
  _setup_done = true

  local config = require("gitsuite.config")
  local cfg = config.setup(user_opts)

  require("gitsuite.bindings").register(cfg)

  vim.g.loaded_gitsuite = 1
end

return M
