---@module 'gitsuite.bindings'
--- Orchestrates gitsuite.nvim's bindings: usrcmds, keymaps, autocmds.
--- Single entry point `require("gitsuite").setup()` calls into.

local M = {}

---Wire up every binding for the resolved config.
---@param cfg GitSuite.Config
---@return nil
function M.register(cfg)
  require("gitsuite.bindings.usrcmds").register(cfg)

  -- After usrcmds: the keymaps point at the composer command, which must
  -- already exist.
  require("gitsuite.bindings.keymaps").register(cfg)

  require("gitsuite.bindings.autocmds").register(cfg)
end

return M
