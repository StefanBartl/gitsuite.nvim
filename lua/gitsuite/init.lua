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

  -- `ui.statusline.modules.gitsuite_conflict` (ui.nvim) and any other
  -- "contributes only" consumer check `package.loaded["gitsuite.statusline"]`
  -- rather than `require`ing it themselves, precisely so a statusline
  -- redrawing before gitsuite.nvim's own lazy trigger has fired never forces
  -- an early load (see that module's own comment). That only works if
  -- something requires it once gitsuite genuinely IS loading -- this is
  -- that one place. The module itself is cheap to load (function
  -- definitions and one autocmd registration, no I/O), so this adds nothing
  -- measurable to `setup()`.
  require("gitsuite.statusline")

  vim.g.loaded_gitsuite = 1
end

return M
