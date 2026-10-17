---@module 'gitsuite.health'
--- :checkhealth gitsuite provider.
---
--- Lua module name is "gitsuite" (matches the repo name, no collision to
--- work around -- see README/UI-62), so this file at `lua/gitsuite/health.lua`
--- is exactly where `:checkhealth gitsuite` looks.

local M = {}

---Optional dependencies: each one only enables a feature, so a missing one is
---`info`, never `warn`/`error` (UI-59).
---@return nil
local function check_soft_dependencies()
  vim.health.start("gitsuite: optional dependencies")
  local soft = {
    {
      "color_my_ascii",
      "color_my_ascii.api.fences",
      "color_my_ascii.nvim",
      "conflict scan ignores marker examples inside fenced code blocks",
      "a fenced block showing conflict markers is reported as a conflict",
    },
    {
      "insights",
      "insights.conflicts",
      "insights.nvim",
      ":Git conflict list (repo-wide quickfix scan)",
      ":Git conflict list is unavailable",
    },
    {
      "pickers",
      "pickers.engines",
      "pickers.nvim",
      "branch picker through the configured picker engine",
      "the branch picker falls back to vim.ui.select",
    },
    {
      "terminal",
      "terminal",
      "terminal.nvim",
      ":Git ui lazygit runs as a terminal.nvim terminal (its backend, one per project)",
      ":Git ui lazygit opens in gitsuite.nvim's own float",
    },
  }
  for _, dep in ipairs(soft) do
    if pcall(require, dep[2]) then
      vim.health.ok(("%s found: %s"):format(dep[1], dep[4]))
    else
      vim.health.info(("%s not installed: %s"):format(dep[1], dep[5]))
    end
  end
end

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
    vim.health.ok("ui.nvim detected (:Git dashboard and :Git plugins log available)")
  else
    vim.health.error(
      "ui.nvim not found -- :Git dashboard and :Git plugins log will fail",
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

  check_soft_dependencies()

  -- `:Git plugins` reads these. A source that is not there is `info` (UI-59):
  -- `clones` needs nothing and is always available.
  vim.health.start("gitsuite: plugin sources")
  local plugin_sources = require("gitsuite.features.plugins.sources")
  for _, name in ipairs({ "lazy", "pack", "clones" }) do
    local source = adapter.resolve(name)
    if source then
      -- (a throwing adapter is a finding, not the end of this check)
      local called, refs, err = pcall(source.list, {
        roots = require("gitsuite.config").get().plugins.roots,
      })
      if not called then
        refs, err = nil, tostring(refs)
      end
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
  if #plugins_cfg.roots > 0 then
    -- Resolved the way the `clones` source resolves them (`~`, `$VAR`, `%VAR%`),
    -- not with `expand()`, which would also run backtick commands and read
    -- wildcards in a config string.
    local resolved_ok, resolved = pcall(function()
      return require("gitsuite.adapter.clones").roots({ roots = plugins_cfg.roots })
    end)
    if resolved_ok then
      local is_dir = require("lib.nvim.fs.is_dir")
      for i, abs in ipairs(resolved) do
        if not is_dir(abs) then
          vim.health.warn(("plugins.roots entry does not exist: %s"):format(plugins_cfg.roots[i]))
        end
      end
    else
      vim.health.warn("plugins.roots could not be resolved: " .. tostring(resolved))
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
    local advice = {
      newer = "Update gitsuite.nvim, or remove " .. report_state.path(),
      not_file = "Replace " .. report_state.path() .. " by a regular file (or remove it)",
      unopenable = "Close whatever holds " .. report_state.path() .. " open and try again",
      unmovable = "Remove or rename " .. report_state.path() .. " by hand",
    }
    vim.health.warn(
      store_info.readonly,
      { advice[store_info.readonly_kind] or ("Check " .. report_state.path()) }
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
  vim.health.info(
    ("fetch: only on `report --mode=pending --fetch` (fetch_jobs = %d, fetch_timeout_ms = %d, asks from %d clones on)"):format(
      reports_cfg.fetch_jobs,
      reports_cfg.fetch_timeout_ms,
      reports_cfg.fetch_confirm
    )
  )
  local last_fetch
  for _, stored in ipairs(store.reports) do
    if stored.fetched then
      last_fetch = stored.fetched
      break
    end
  end
  if last_fetch and #last_fetch.failed > 0 then
    vim.health.warn(
      ("the last --fetch (%s) failed for %d of %d clones (the report lists them)"):format(
        os.date("%Y-%m-%d %H:%M", last_fetch.at),
        #last_fetch.failed,
        last_fetch.clones
      )
    )
  elseif last_fetch then
    vim.health.ok(
      ("the last --fetch (%s) fetched %d of %d clones"):format(
        os.date("%Y-%m-%d %H:%M", last_fetch.at),
        last_fetch.fetched,
        last_fetch.clones
      )
    )
  end
  if reports_cfg.after_sync == "off" then
    vim.health.info("lazy integration: off (plugins.after_sync)")
  else
    local status = require("gitsuite.integrations.lazy").status()
    if status.registered then
      vim.health.ok(
        ("lazy integration: %s (listening on User LazySync)"):format(reports_cfg.after_sync)
      )
    else
      vim.health.info(
        ("lazy integration: %s, not listening yet (gitsuite's setup() has not run)"):format(
          reports_cfg.after_sync
        )
      )
    end
  end

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
