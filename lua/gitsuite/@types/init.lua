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

--- `:Git plugins` -- reading the history of the clones a plugin manager installed.
---@class GitSuite.Config.Plugins
---@field sources    "auto"|string[]  Where the installed plugins come from: "auto" (the first available of lazy, pack, clones) or an explicit list of `"lazy"`, `"pack"`, `"clones"`.
---@field roots      string[]  Folders of clones the `clones` source scans; empty = `stdpath("data")/lazy` and `stdpath("data")/site/pack/*/{start,opt}`.
---@field log_limit  integer   Commits `:Git plugins log` lists when no count is given.
---@field timeout_ms integer   Per-`git` timeout of `:Git plugins` (a clone on a network drive can hang).

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
---@field plugins  GitSuite.Config.Plugins
---@field progress_style string  Indicator style for `:Git dashboard`/`:Git dashboard update`; "auto" (default), "notify", "statusline", "fidget", "float" or "kit".

--- The partial shape a caller hands to `require("gitsuite").setup(opts)`.
---@class GitSuite.Opts
---@field features? table
---@field commands? table
---@field keymaps?  table
---@field browse?   table
---@field branch?   table
---@field dashboard? table
---@field plugins? table
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

--- How a plugin manager pins a plugin; every field is whatever its spec said.
---@class GitSuite.Plugins.Spec
---@field branch? string
---@field tag? string
---@field commit? string
---@field version? string|boolean|table  A version range string (`"1.*"`), `false`, or a `vim.VersionRange`.
---@field pin boolean

--- One installed plugin, as a source adapter lists it.
---@class GitSuite.Plugins.Ref
---@field name string        Plugin name (the clone's folder name for the `clones` source).
---@field dir string         Absolute path of the clone.
---@field url? string        Where it was cloned from, when the source knows.
---@field managed_by "lazy"|"pack"|"clones"
---@field is_local boolean   A `dir`-mode plugin (lazy.nvim never updates it) -- usually one of your own.
---@field spec GitSuite.Plugins.Spec

--- A source of installed plugins: an adapter that can also list them.
---@class GitSuite.PluginSource : GitSuite.Adapter
---@field list fun(opts?: table): GitSuite.Plugins.Ref[]|nil, string|nil

--- What a `:Git plugins` target resolves to: an installed plugin or a folder.
---@class GitSuite.Plugins.Target
---@field kind "plugin"|"path"
---@field name string   Plugin name, or the folder's name.
---@field dir string    Absolute path of the clone.
---@field ref? GitSuite.Plugins.Ref  Set for `kind = "plugin"`.
