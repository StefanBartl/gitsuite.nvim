---@module 'gitsuite.bindings.autocmds'
--- Autocommand registration for gitsuite.nvim.
---
--- The one consumer is `features/conflict/`: a `BufReadPost`/`BufNewFile`
--- scan for conflict markers sets up buffer-local keymaps the moment a
--- buffer actually has one, mirroring git-conflict.nvim's own
--- `setup_buffer_mappings` -- same six keys (`co`/`ct`/`cb`/`c0`/`]x`/`[x`),
--- kept 1:1 for muscle memory, buffer-local and fixed (not routed through
--- the user-configurable keymap registry the way `<leader>gb`/`<leader>lg`
--- are: these are conflict-resolution mode keys, not plugin entry points).

local map = require("lib.nvim.bindings.keymap")

local M = {}

---@internal
---@param bufnr integer
local function setup_buffer_mappings(bufnr)
  if vim.b[bufnr].gitsuite_conflict_mappings_set then return end
  vim.b[bufnr].gitsuite_conflict_mappings_set = true

  local conflict = require("gitsuite.features.conflict")
  local opts = { buffer = bufnr, silent = true }

  map("n", "co", function()
    conflict.choose("ours")
  end, opts, "[gitsuite] Conflict: choose ours")
  map("n", "ct", function()
    conflict.choose("theirs")
  end, opts, "[gitsuite] Conflict: choose theirs")
  map("n", "cb", function()
    conflict.choose("both")
  end, opts, "[gitsuite] Conflict: choose both")
  map("n", "c0", function()
    conflict.choose("none")
  end, opts, "[gitsuite] Conflict: choose none")
  map("n", "]x", function()
    conflict.next()
  end, opts, "[gitsuite] Conflict: next")
  map("n", "[x", function()
    conflict.prev()
  end, opts, "[gitsuite] Conflict: previous")
end

---@param cfg GitSuite.Config
function M.register(cfg)
  if not cfg.features.conflict then return end

  local group = vim.api.nvim_create_augroup("gitsuite_conflict_scan", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    desc = "[gitsuite] Scan for merge-conflict markers, highlight + bind if found",
    callback = function(args)
      -- Cheap guard before the scan itself: conflict markers are a file-
      -- buffer concept, never meaningful in a terminal/quickfix/help/scratch
      -- buffer, so there is no reason to read + parse those at all.
      if vim.bo[args.buf].buftype ~= "" then return end

      -- One scan, not two: has_conflicts() + refresh() used to each
      -- independently read and re-parse the whole buffer for any buffer
      -- that DOES have a conflict. refresh() already returns the regions
      -- it found, so that single call answers both "are there any" and
      -- "highlight them" at once.
      local conflict = require("gitsuite.features.conflict")
      local regions = conflict.refresh(args.buf)
      if #regions > 0 then setup_buffer_mappings(args.buf) end
    end,
  })
end

return M
