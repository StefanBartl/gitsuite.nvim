---@module 'gitsuite.bindings.autocmds'
--- Autocommand registration for gitsuite.nvim.
---
--- Empty for now: the first consumer is `features/conflict/` (phase 2),
--- which needs a `BufReadPost`/`BufNewFile` scan for conflict markers to set
--- up its buffer-local keymaps, mirroring git-conflict.nvim's
--- `setup_buffer_mappings`. Kept as its own module from the start (matching
--- `bindings/{keymaps,usrcmds,autocmds}.lua`) so that wiring has a fixed home.

local M = {}

---@param _cfg GitSuite.Config
function M.register(_cfg) end

return M
