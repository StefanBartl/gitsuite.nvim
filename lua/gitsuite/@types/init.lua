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
---@field blame_full     string|string[]|false  Default mapping for `:Git blame full`.
---@field ui_lazygit     string|string[]|false  Default mapping for `:Git ui lazygit`.
---@field hunk_inline    string|string[]|false  Default mapping for `:Git hunk inline`.
---@field diffview_open  string|string[]|false  Default mapping for `:Git ui diffview open`.
---@field diffview_close string|string[]|false  Default mapping for `:Git ui diffview close`.
---@field diff_history   string|string[]|false  Default mapping for `:Git diff history`.

---@class GitSuite.Config.Browse
---@field hosts table<string, "github"|"gitlab"|"codeberg">  Self-hosted instances, keyed by hostname.

---@class GitSuite.Config.Branch
---@field sessions boolean  GS-24, opt-in, default false: save the current branch's window/tab layout (sessions.nvim, optional soft dep) before a `branch.switch()` checkout, load the target branch's layout after. Off by default -- an automatic load can discard unsaved buffers.

--- One named page `:Git dashboard` can flip to with `<C-l>`/`<Right>` /
--- `<C-h>`/`<Left>`, alongside the default (unnamed) `base_dir` page.
---@class GitSuite.Config.Dashboard.Group
---@field name string    Shown in the dashboard's title/winbar when this page is active.
---@field paths string[] Each entry is a repository itself, or a directory scanned for its immediate git-repository children.

---@class GitSuite.Config.Dashboard
---@field base_dir    string  Directory `:Git dashboard`/`:Git dashboard update` scan by default. Defaults to `$REPOS_DIR`.
---@field extra_paths string[]  Repositories merged onto the default page's scan; each entry must itself be a repository.
---@field groups      GitSuite.Config.Dashboard.Group[]  Additional named pages, see `GitSuite.Config.Dashboard.Group`.

--- The **resolved** configuration, as `config.get()` returns it: DEFAULTS
--- deep-merged with the user's `setup()` table. Every field below is
--- therefore always present.
---@class GitSuite.Config
---@field features GitSuite.Config.Features
---@field commands GitSuite.Config.Commands
---@field keymaps  GitSuite.Config.Keymaps
---@field browse   GitSuite.Config.Browse
---@field branch   GitSuite.Config.Branch
---@field dashboard GitSuite.Config.Dashboard
---@field progress_style string  Indicator style for `:Git dashboard`/`:Git dashboard update`; "auto" (default), "notify", "statusline", "fidget", "float" or "kit".

--- The partial shape a caller hands to `require("gitsuite").setup(opts)`.
---@class GitSuite.Opts
---@field features? table
---@field commands? table
---@field keymaps?  table
---@field browse?   table
---@field branch?   table
---@field dashboard? table
---@field progress_style? string

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

--- `GitsuiteStatusChanged` -- after a hunk stage (single hunk or whole
--- buffer) actually writes to the git index. Not fired for a hunk reset:
--- gitsigns' reset only rewrites the buffer's in-memory lines, never the
--- index or the file on disk, so `git status` has not moved.
---@class GitSuite.Event.StatusChanged
---@field dir string  Repo root the change happened in.
