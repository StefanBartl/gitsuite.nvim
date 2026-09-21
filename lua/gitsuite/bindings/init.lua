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

  if cfg.features.ui then
    -- GitsuiteLazygitBadd/GitsuiteLazygitReplace: lazygit's O/<C-o> nvr
    -- targets, not part of the :Git tree (see features/ui/lazygit/init.lua).
    require("gitsuite.features.ui.lazygit").setup()
  end
end

return M
