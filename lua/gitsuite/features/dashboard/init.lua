---@module 'gitsuite.features.dashboard'
---@brief Public entry point for `:Git dashboard` and `:Git dashboard update`.
---@description
--- Resolves the configured dashboard pages -- the default (unnamed)
--- `dashboard.base_dir`/`extra_paths` scan, plus every `dashboard.groups`
--- entry, in declaration order -- reads the requested one's git status and
--- hands the result to `features.dashboard.view` for the interactive
--- command, or runs a headless bulk update for `update`.
---
--- Moved from reposcope.nvim (`:Reposcope dashboard`/`:Reposcope update`):
--- a multi-repo git-status/action panel is git tooling, not repository
--- *discovery*, which is what reposcope.nvim stays scoped to.

local config = require("gitsuite.config")
local status = require("gitsuite.features.dashboard.status")
local repos_util = require("gitsuite.features.dashboard.repos")
local actions = require("gitsuite.features.dashboard.actions")
local pages_state = require("gitsuite.state.dashboard_pages")
local progress = require("gitsuite.util.progress")
local notify = require("gitsuite.util.notify").notify

---@class GitSuiteDashboard
local M = {}

---One page `:Git dashboard` can show, and flip to/from with `<C-l>`/`<Right>`
---and `<C-h>`/`<Left>`.
---@class GitSuiteDashboardPage
---@field name string|nil `nil` for the default page (it scans `dir`/`dashboard.base_dir` instead of a fixed path list)
---@field paths string[]|nil `nil` for the default page

---Builds the ordered page list: the default page first, then every
---configured group that has a non-empty `name`, in declaration order.
---@return GitSuiteDashboardPage[]
local function build_pages()
  local pages = { { name = nil, paths = nil } }
  for _, group in ipairs(config.get().dashboard.groups or {}) do
    if type(group) == "table" and type(group.name) == "string" and group.name ~= "" then
      pages[#pages + 1] = { name = group.name, paths = group.paths or {} }
    end
  end
  return pages
end

---Reads one page's git status. The default page scans `dir`/`base_dir`
---exactly like `status.scan`; a named page resolves its (persisted-overlay
---adjusted) `paths` via `status.scan_group`.
---@param page GitSuiteDashboardPage
---@param dir string|nil Explicit directory override; only meaningful for the default page
---@param on_done fun(records: RepoDashboardRecord[], errors: string[]): nil
local function scan_page(page, dir, on_done)
  if not page.name then
    status.scan(dir, on_done)
    return
  end
  local paths = pages_state.apply(page.name, page.paths or {})
  status.scan_group(paths, on_done)
end

---Opens `:Git dashboard [dir] [--out] [--to]`.
---@param dir string|nil
---@param output GitSuiteDashboardOutputMode|nil
---@param out_path string|nil
---@return nil
function M.show(dir, output, out_path)
  local pages = build_pages()
  local view = require("gitsuite.features.dashboard.view")

  scan_page(pages[1], dir, function(records, errors)
    if #records > 0 or #pages > 1 then
      view.show(records, {
        output = output,
        path = out_path,
        dir = dir,
        pages = pages,
        page_index = 1,
        on_switch_page = function(page, on_switched)
          scan_page(page, dir, on_switched)
        end,
      })
    end
    if #errors > 0 then
      notify(
        ("%d repositor%s could not be read:\n\n%s"):format(
          #errors,
          #errors == 1 and "y" or "ies",
          table.concat(errors, "\n")
        ),
        vim.log.levels.WARN
      )
    end
  end)
end

---Updates every repository found in the resolved base directory: fetch,
---then fast-forward pull, sequentially (a rate limit or an auth-prompt
---storm is the alternative for a few dozen simultaneous network calls).
---Scoped to the default page only -- same directory-wide sweep
---`:Reposcope update` ran, not group-aware.
---
---Validation failures (missing git, inaccessible directory, no
---repositories) are reported via notification and abort early without
---invoking `on_complete`.
---@param path string|nil Optional directory override (defaults to `dashboard.base_dir`)
---@param on_complete fun(updated: integer, errors: string[]): nil|nil Called once on completion
---@return nil
function M.update_all(path, on_complete)
  if vim.fn.executable("git") ~= 1 then
    notify("Cannot update repositories: 'git' is not available in PATH", 4)
    return
  end

  local base_dir = repos_util.resolve_base_dir(path)
  if not base_dir then
    notify("No repository directory provided and dashboard.base_dir is not set", 4)
    return
  end

  local stat = (vim.uv or vim.loop).fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    notify("Repository directory is not accessible: " .. base_dir, 4)
    return
  end

  local repos = repos_util.collect_repos(base_dir)
  if #repos == 0 then
    notify("No git repositories found in " .. base_dir, 3)
    return
  end

  notify(("Updating %d repositories in %s ..."):format(#repos, base_dir), 2)

  ---@type string[]
  local errors = {}
  local updated = 0
  local index = 1

  local handle = progress.create(("updating %d repositories"):format(#repos), #repos)

  -- Cancelling stops the queue rather than killing the in-flight `git`
  -- process: a half-applied fetch is harmless and finishes in a moment
  -- anyway, whereas interrupting a `pull` mid-write is the one thing worth
  -- avoiding here. Repositories already updated stay updated, and
  -- `on_complete` still reports the real count.
  local cancelled = false
  if handle then handle:on_cancel(function()
    cancelled = true
  end) end

  local function run_next()
    local repo = repos[index]
    if not repo or cancelled then
      if handle and not cancelled then
        handle:finish(("updated %d of %d repositories"):format(updated, #repos))
      end
      vim.schedule(function()
        if on_complete then on_complete(updated, errors) end
      end)
      return
    end

    -- Named before the call, not after: the indicator should show what is
    -- currently being fetched, not what was last finished.
    if handle then
      handle:update({ text = vim.fn.fnamemodify(repo, ":t"), current = index - 1, total = #repos })
    end

    actions.update(repo, function(ok, err)
      if ok then
        updated = updated + 1
        notify("Updated " .. vim.fn.fnamemodify(repo, ":t"), 2)
      else
        errors[#errors + 1] = vim.fn.fnamemodify(repo, ":t") .. ": " .. (err or "unknown error")
      end

      index = index + 1
      run_next()
    end)
  end

  run_next()
end

return M
