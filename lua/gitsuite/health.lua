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
  -- UI-59: several adapters exist, one per foreign plugin/binary this gitsuite.nvim
  -- can lean on (gitsigns, diffview, neogit, lazygit) plus `native`, which backs the
  -- OWN-implementation families (blame/diff/browse/status/conflict/branch/dashboard --
  -- see architecture.md). A single one being absent is `info`, never `warn`/`error`:
  -- `native`'s families stay usable regardless, and for the rest (`ui *`, and `hunk`'s
  -- stage/reset/toggle-deleted/inline, which has no native fallback at all) the family
  -- simply reports "not installed" when actually invoked, not here.
  local adapter = require("gitsuite.adapter")
  for _, name in ipairs({ "gitsigns", "diffview", "neogit", "lazygit", "native" }) do
    if adapter.resolve(name) then
      vim.health.ok(("%s: available"):format(name))
    else
      vim.health.info(("%s: not available"):format(name))
    end
  end

  -- `:Git plugins` reads these. A source that is not there is `info` (UI-59):
  -- `clones` needs nothing and is always available.
  vim.health.start("gitsuite: plugin sources")
  local plugin_sources = require("gitsuite.features.plugins.sources")
  for _, name in ipairs({ "lazy", "pack", "clones" }) do
    local source = adapter.resolve(name)
    if source then
      ---@diagnostic disable-next-line: undefined-field
      local refs, err = source.list({ roots = require("gitsuite.config").get().plugins.roots })
      if refs then
        local detail = ""
        if name == "lazy" then
          local version = require("gitsuite.adapter.lazy").version()
          detail = version and (", lazy.nvim " .. version) or ""
          -- The adapter was written against lazy.nvim 11.x's data layout.
          if version and not version:match("^11%.") then
            vim.health.warn(
              ("lazy.nvim %s: gitsuite's adapter was written against 11.x"):format(version),
              {
                "If :Git plugins misbehaves, update gitsuite.nvim or set plugins.sources = { 'clones' }",
              }
            )
          end
        end
        vim.health.ok(
          ("%s: available, %d plugin%s%s"):format(name, #refs, #refs == 1 and "" or "s", detail)
        )
      else
        vim.health.warn(("%s: available but unreadable: %s"):format(name, err or "?"))
      end
    else
      vim.health.info(("%s: not available"):format(name))
    end
  end
  local plugins_cfg = require("gitsuite.config").get().plugins
  vim.health.info("plugins.sources = " .. vim.inspect(plugins_cfg.sources):gsub("%s+", " "))
  for _, root in ipairs(plugins_cfg.roots) do
    if vim.fn.isdirectory(vim.fn.expand(root)) == 0 then
      vim.health.warn(("plugins.roots entry does not exist: %s"):format(root))
    end
  end
  local _, used, plugin_errors = plugin_sources.list()
  if #used > 0 then
    vim.health.ok("plugins source in use: " .. table.concat(used, ", "))
  elseif plugins_cfg.sources ~= "auto" then
    vim.health.warn(
      "none of the configured plugins.sources is available: "
        .. table.concat(plugins_cfg.sources, ", "),
      { 'Use plugins.sources = "auto", or a source from: lazy, pack, clones' }
    )
  end
  for _, e in ipairs(plugin_errors) do
    vim.health.warn("plugins source failed: " .. e)
  end

  -- The reports `:Git plugins report` keeps. Looks only: an unreadable file is
  -- reported here and moved aside by the next report, not by this check.
  vim.health.start("gitsuite: plugin reports")
  local report_state = require("gitsuite.features.plugins.state")
  local store, store_info = report_state.load(nil, { peek = true })
  if store_info.readonly then
    vim.health.warn(
      store_info.readonly,
      { "Update gitsuite.nvim, or remove " .. report_state.path() }
    )
  elseif store_info.recovered then
    vim.health.warn(
      "the report store cannot be read: " .. report_state.path(),
      { "The next `:Git plugins report` moves it to `.corrupt` and starts a new one" }
    )
  elseif store_info.foreign then
    vim.health.warn(
      ("the report store was written on another machine (%s)"):format(store_info.foreign),
      { "The next `:Git plugins report` keeps it aside (`.foreign-<host>.bak`) and starts its own" }
    )
  elseif #store.reports == 0 then
    vim.health.info("no report stored yet (run `:Git plugins report`)")
  else
    vim.health.ok(
      ("%d stored report%s, newest %s"):format(
        #store.reports,
        #store.reports == 1 and "" or "s",
        os.date("%Y-%m-%d %H:%M", store.reports[1].at)
      )
    )
  end
  if store_info.dropped then
    vim.health.warn(
      ("%d stored report(s) are not usable and are ignored"):format(store_info.dropped)
    )
  end
  local reports_cfg = require("gitsuite.config").get().plugins
  vim.health.info(
    ("plugins.mode = %s, keep_reports = %d, max_age_days = %d"):format(
      reports_cfg.mode,
      reports_cfg.keep_reports,
      reports_cfg.max_age_days
    )
  )

  vim.health.start("gitsuite: plugin state")
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
