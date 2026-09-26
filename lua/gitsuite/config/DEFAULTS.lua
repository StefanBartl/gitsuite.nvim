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
  -- Indicator style for `:Git dashboard`/`:Git dashboard update` over many
  -- repositories; "auto" picks fidget.nvim when installed, else `vim.notify`.
  -- Needs lib.nvim (always present), no-op otherwise.
  progress_style = "auto",
}

return DEFAULTS
