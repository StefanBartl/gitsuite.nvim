---@module 'gitsuite.util.notify'
--- Thin, explicitly-marked re-export of `lib.nvim.notify` (LUA-03): the one
--- place gitsuite.nvim's UI layer sends user-facing messages from (ERR-04 --
--- low-level/core modules return values, they never notify themselves).

return require("lib.nvim.notify").create("[gitsuite]")
