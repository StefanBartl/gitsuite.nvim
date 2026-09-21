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
  },
  browse = {
    -- Additional self-hosted GitHub/GitLab/Codeberg(Gitea) instances, keyed
    -- by host, e.g. { ["git.example.org"] = "gitlab" }. Empty by default --
    -- only the three public hosts are recognized out of the box.
    hosts = {},
  },
}

return DEFAULTS
