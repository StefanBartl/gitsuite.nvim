---@module 'gitsuite.health'
--- :checkhealth gitsuite provider.
---
--- Lua module name is "gitsuite" (matches the repo name, no collision to
--- work around -- see README/UI-62), so this file at `lua/gitsuite/health.lua`
--- is exactly where `:checkhealth gitsuite` looks.

local M = {}

---@return nil
function M.check()
  vim.health.start("gitsuite")

  -- lib.nvim, diff.nvim and ui.nvim are HARD dependencies (LUA-01) --
  -- gitsuite.nvim has no fallback for any of them, so a missing one is
  -- `error`, not `warn`.
  if pcall(require, "lib.nvim.bindings.usercmd.composer") then
    vim.health.ok("lib.nvim detected (:Git command layer available)")
  else
    vim.health.error(
      "lib.nvim not found -- :Git will fail to register",
      { 'Install "StefanBartl/lib.nvim" as a dependency' }
    )
  end

  if pcall(require, "diff.core") then
    vim.health.ok("diff.nvim detected (:Git diff * available)")
  else
    vim.health.error(
      "diff.nvim not found -- :Git diff * will fail",
      { 'Install "StefanBartl/diff.nvim" as a dependency' }
    )
  end

  if pcall(require, "ui.kit") then
    vim.health.ok("ui.nvim detected (:Git dashboard available)")
  else
    vim.health.error(
      "ui.nvim not found -- :Git dashboard will fail",
      { 'Install "StefanBartl/ui.nvim" as a dependency' }
    )
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git executable on PATH")
  else
    vim.health.error("git executable not on PATH -- gitsuite.nvim needs it for everything", {
      "Install git",
    })
  end

  vim.health.start("gitsuite: adapters")
  -- UI-59: several adapters exist per family (gitsigns vs. native for hunks,
  -- lazygit/neogit/diffview for the ui launcher); a single one being absent
  -- is `info`, never `warn`/`error` -- there is always a working alternative
  -- (native.lua) or the family is simply not usable until you pick one, which
  -- `:Git ui *` says for itself when invoked.
  local adapter = require("gitsuite.adapter")
  for _, name in ipairs({ "gitsigns", "diffview", "neogit", "lazygit", "native" }) do
    if adapter.resolve(name) then
      vim.health.ok(("%s: available"):format(name))
    else
      vim.health.info(("%s: not available"):format(name))
    end
  end

  if vim.g.loaded_gitsuite then
    vim.health.ok(
      "plugin loaded (vim.g.loaded_gitsuite = " .. tostring(vim.g.loaded_gitsuite) .. ")"
    )
  else
    -- UI-60: under cmd-lazy loading, "not loaded yet" is the normal state
    -- before the first `:Git ...` invocation, not a problem.
    vim.health.info(
      "plugin guard not set yet (:Git hasn't been invoked, or call require('gitsuite').setup())"
    )
  end

  vim.health.start("gitsuite: setup() options")
  local cfg_issues = require("gitsuite.config").issues()
  if #cfg_issues == 0 then
    vim.health.ok("No unknown or invalid setup() options")
  else
    for _, issue in ipairs(cfg_issues) do
      vim.health.warn(issue)
    end
  end

  local ok_composer, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if ok_composer then
    local cfg = require("gitsuite.config").get()
    composer.checkhealth(cfg.commands.git)
  end

  ---------------------------------------------------------------------------
  -- dashboard.extra_paths (repositories shown on `:Git dashboard`'s default
  -- page outside the normal dashboard.base_dir/$REPOS_DIR scan). Moved from
  -- reposcope.nvim along with the dashboard itself.
  ---------------------------------------------------------------------------
  vim.health.start("gitsuite: dashboard")
  local extra_paths = require("gitsuite.config").get().dashboard.extra_paths or {}
  if #extra_paths == 0 then
    vim.health.info("dashboard.extra_paths is empty (no extra repositories configured)")
  else
    local repos_util = require("gitsuite.features.dashboard.repos")
    local expand = require("lib.nvim.cross.fs.expand_path")
    local bad = {}
    for _, raw in ipairs(extra_paths) do
      local resolved = vim.fn.fnamemodify(expand(raw), ":p"):gsub("[\\/]+$", "")
      if not repos_util.is_git_repo(resolved) then bad[#bad + 1] = raw end
    end
    if #bad == 0 then
      vim.health.ok(
        ("dashboard.extra_paths: %d configured repositor%s resolve to real git repositories"):format(
          #extra_paths,
          #extra_paths == 1 and "y" or "ies"
        )
      )
    else
      vim.health.warn(
        "dashboard.extra_paths entries that are not git repositories: " .. table.concat(bad, ", "),
        { "Check the path exists and has a .git directory/file" }
      )
    end
  end
end

return M
