---@module 'gitsuite.config.DEFAULTS'
--- Immutable default configuration for gitsuite.nvim.
---
--- Pure data only (LUA-06): no env-/FS-lookup at module level. A default that
--- needs to be *computed* (e.g. resolved from an environment variable) is
--- resolved in config/init.lua's M.get()/M.setup(), never here.

---@type GitSuite.Config
local DEFAULTS = {
  features = {
    conflict = true,
    hunk = true,
    blame = true,
    diff = true,
    browse = true,
    branch = true,
    ui = true,
    status = true,
  },
  commands = {
    git = "Git",
  },
  keymaps = {
    blame_full = "<leader>gb",
    ui_lazygit = "<leader>lg",
    hunk_inline = "<leader>di",
    diffview_open = "<leader>dv",
    diffview_close = "<leader>dc",
    diff_history = "<leader>dh",
  },
  browse = {
    -- Additional self-hosted GitHub/GitLab/Codeberg(Gitea) instances, keyed
    -- by host, e.g. { ["git.example.org"] = "gitlab" }. Empty by default --
    -- only the three public hosts are recognized out of the box.
    hosts = {},
  },
  branch = {
    -- GS-24, opt-in: save/load the window/tab layout (sessions.nvim,
    -- optional soft dep) around a branch.switch() checkout. Off by default
    -- -- an automatic load can discard unsaved buffers.
    sessions = false,
  },
  dashboard = {
    -- Placeholder, overwritten in config/init.lua right after this table is
    -- required (via lib.nvim's env snapshot, `$REPOS_DIR`) -- kept out of
    -- this table so requiring DEFAULTS.lua alone stays pure data.
    base_dir = "",
    -- Repository paths shown on the default dashboard page in addition to
    -- whatever `base_dir`'s scan finds -- e.g. a Neovim config, which is a
    -- git repository of its own but never itself a checkout cloned into
    -- `base_dir`. Each entry must itself be a repository; one that isn't is
    -- reported and skipped (see docs/configuration.md).
    extra_paths = {},
    -- Named pages the dashboard can flip between (`<C-l>`/`<Right>` next,
    -- `<C-h>`/`<Left>` previous, alongside the default `base_dir` page).
    -- Each entry is `{ name = string, paths = string[] }`; a path is either
    -- a repository itself or a directory scanned for its immediate
    -- git-repository children (the same rule `extra_paths`' entries do NOT
    -- get -- see docs/configuration.md).
    groups = {},
  },
  -- `:Git plugins` -- the history of the clones a plugin manager installed.
  plugins = {
    -- "auto" = the first available of lazy.nvim, vim.pack, plain clones; or an
    -- explicit list of those names (their union, deduplicated).
    sources = "auto",
    -- Folders of clones for the "clones" source; empty = stdpath("data")/lazy
    -- and stdpath("data")/site/pack/*/{start,opt}, resolved at run time.
    roots = {},
    -- Commits `:Git plugins log` shows when no count is given.
    log_limit = 50,
    -- Timeout of each git process in milliseconds: a clone on a network drive
    -- or a stalled antivirus scan must not hang the editor's request forever.
    timeout_ms = 30000,
    -- `:Git plugins report`: which clones. false = only third-party plugins the
    -- manager updates; true also takes `dir`-mode ones (usually your own repos).
    include_local = false,
    -- What the report compares: "updated" = the previous state with the current
    -- one (what the last update changed, from each clone's reflog); "pending" =
    -- the current state with the target lazy.nvim would move to (as of the last
    -- fetch -- gitsuite never fetches).
    mode = "updated",
    -- Commits kept per plugin in a report; more are cut and marked as such.
    max_commits = 1000,
    -- git processes at once while a report is built (a Windows machine with a
    -- virus scanner is happier with few).
    parallel = 4,
    -- Plugins whose update times lie at most this many seconds apart belong to
    -- one update run (one `:Lazy sync`).
    run_window_s = 300,
    -- Merge commits in a report: false = left out of the commit lists.
    merges = false,
    -- Stored reports (newest first): how many, and for how many days.
    keep_reports = 20,
    max_age_days = 365,
  },
  -- Indicator style for `:Git dashboard`/`:Git dashboard update` over many
  -- repositories; "auto" picks fidget.nvim when installed, else `vim.notify`.
  -- Needs lib.nvim (always present), no-op otherwise.
  progress_style = "auto",
}

return DEFAULTS
