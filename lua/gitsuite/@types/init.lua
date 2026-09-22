---@meta
---@module 'gitsuite.@types'
--- Type declarations for gitsuite.nvim's user-facing configuration table.

---@class GitSuite.Config.Features
---@field conflict boolean  Buffer-local merge-conflict resolution (own implementation).
---@field hunk     boolean  Stage/reset/preview hunks (delegated to gitsigns when available).
---@field blame    boolean  Line/full blame (own implementation, `git blame --porcelain`).
---@field diff     boolean  `:Git diff *` -- thin alias onto diff.nvim.
---@field browse   boolean  Open the current file/selection/repo on its web host.
---@field branch   boolean  List/switch/show the current branch.
---@field ui       boolean  `:Git ui lazygit|neogit|diffview` TUI launcher.
---@field status   boolean  Repo status / quickfix export.

---@class GitSuite.Config.Commands
---@field git string  Name of the compound user command (default "Git").

---@class GitSuite.Config.Keymaps
---@field blame_full string|string[]|false  Default mapping for `:Git blame full`.
---@field ui_lazygit string|string[]|false  Default mapping for `:Git ui lazygit`.

---@class GitSuite.Config.Browse
---@field hosts table<string, "github"|"gitlab"|"codeberg">  Self-hosted instances, keyed by hostname.

--- The **resolved** configuration, as `config.get()` returns it: DEFAULTS
--- deep-merged with the user's `setup()` table. Every field below is
--- therefore always present.
---@class GitSuite.Config
---@field features GitSuite.Config.Features
---@field commands GitSuite.Config.Commands
---@field keymaps  GitSuite.Config.Keymaps
---@field browse   GitSuite.Config.Browse

--- The partial shape a caller hands to `require("gitsuite").setup(opts)`.
---@class GitSuite.Opts
---@field features? table
---@field commands? table
---@field keymaps?  table
---@field browse?   table

--- One entry in `gitsuite.adapter`'s registry. Built-in adapter modules
--- (`adapter/gitsigns.lua`, `adapter/native.lua`, ...) each return a table
--- matching this shape directly -- the module IS the adapter, nothing wraps it.
---@class GitSuite.Adapter
---@field name string             Registry key, matches the module's file name.
---@field is_available fun(): boolean  Reads `package.loaded[...]` only (LUA-91), never `require`s the foreign plugin.

--- Payload shapes of the `User` autocmd events `gitsuite.events` fires (D-2:
--- events, not direct integrations -- see `gitsuite/events.lua`). Every
--- consumer reads `event.data` in its `autocmd User Gitsuite* callback`.

--- `GitsuiteBranchSwitched` -- after a branch checkout.
---@class GitSuite.Event.BranchSwitched
---@field dir string     Repo root the checkout ran in.
---@field branch string  The branch now checked out.

--- `GitsuiteConflictsResolved` -- after a buffer's last conflict region was resolved.
---@class GitSuite.Event.ConflictsResolved
---@field bufnr integer

--- `GitsuiteStatusChanged` -- after a hunk stage/reset actually wrote to git.
---@class GitSuite.Event.StatusChanged
---@field dir string  Repo root the change happened in.
