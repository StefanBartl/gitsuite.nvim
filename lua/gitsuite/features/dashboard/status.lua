---@module 'gitsuite.features.dashboard.status'
---@brief Collects a compact git status summary for one or many local repositories.
---@description
--- For each git repository found in (or equal to) a base directory, or named
--- by a configured `dashboard.groups` entry, this module runs
--- `git status --porcelain=v2 --branch` and distills the machine-readable
--- output into a small record — current branch, ahead/behind counts
--- relative to the upstream, and the number of uncommitted changes.
---
--- The default page's base directory is resolved via
--- `gitsuite.features.dashboard.repos.resolve_base_dir` (explicit override >
--- `dashboard.base_dir`, itself defaulted from `$REPOS_DIR`). If the
--- resolved path is itself a git repository, only that single repository is
--- reported; otherwise its immediate subdirectories are scanned.
--- `dashboard.extra_paths` merges in repositories outside that scan (each
--- entry must itself be a repository -- an invalid one is reported and
--- skipped, never silently scanned as a directory).
---
--- A configured group's `paths` apply the more permissive per-entry rule
--- `resolve_group_repos` already uses for the default scan's own base
--- directory: each entry is either itself a repository, or a directory
--- whose immediate git-repository children are all included.
---
--- Reading is side-effect free, so each repository is queried through a
--- non-blocking job and the aggregated records are handed back once all
--- queries finish, preserving discovery order.
---
--- Live feedback while the repositories are being read goes through
--- `gitsuite.util.progress` (nil if its own internal lib.nvim.progress
--- lookup ever fails): a single `git status` is fast, but a directory of
--- several dozen clones adds up to a noticeable wait with no output.
---
--- Ported from reposcope.nvim's `utils.repo_dashboard` (dashboard moved to
--- gitsuite.nvim; see `repos.lua`'s module doc for why).

---@class RepoDashboardRecord
---@field name string Repository directory name (tail of the path)
---@field path string Absolute path to the repository
---@field branch string Current branch, or "(detached)" when HEAD is detached
---@field ahead integer Commits ahead of the upstream (0 when no upstream)
---@field behind integer Commits behind the upstream (0 when no upstream)
---@field has_upstream boolean Whether the current branch tracks an upstream
---@field dirty integer Number of changed/untracked entries in the working tree
---@field state "clean"|"dirty"|"ahead"|"behind"|"diverged" Derived summary state
---@field last_commit integer|nil Unix timestamp of HEAD's commit date (nil on an empty repo)

---@class GitSuiteDashboardStatus
local M = {}

-- Vim Utilities
local fnamemodify = vim.fn.fnamemodify
local uv = vim.uv or vim.loop
local expand = require("lib.nvim.cross.fs.expand_path")
local unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes")
local is_windows = require("lib.nvim.cross.platform.is_windows")
-- Utils
local notify = require("gitsuite.util.notify").notify
local config = require("gitsuite.config")
-- Shared repository discovery helpers
local repos_util = require("gitsuite.features.dashboard.repos")
local resolve_base_dir = repos_util.resolve_base_dir
local collect_repos = repos_util.collect_repos
local is_git_repo = repos_util.is_git_repo
-- Progress indicator; see util/progress.lua on why its handle can be nil
local progress = require("gitsuite.util.progress")

---Ceiling for a single `git` call. A repository that never answers (a network
---mount, a stuck credential helper) must not hold the whole scan, and its
---progress indicator, open forever: on expiry `vim.system` kills the process
---and reports exit code 124.
local GIT_TIMEOUT_MS = 60000
local TIMEOUT_EXIT_CODE = 124

---Upper bound on repositories read at the same time. Each read starts two `git`
---processes, so an unbounded fan-out over a few dozen clones means a hundred
---simultaneous processes, which starves the machine (Windows in particular).
local MAX_PARALLEL = 8

---Builds the `git status` argv for one repository.
---`--no-optional-locks` keeps a read-only overview from taking `index.lock`,
---which `git status` otherwise does to refresh the index. Without it, scanning
---a repository somebody is committing in (or that gitsigns/lazygit is polling)
---makes their `git` fail with "Unable to create index.lock".
---@param ... string Arguments following `status`
---@return string[]
local function status_argv(...)
  return { "git", "--no-optional-locks", "status", ... }
end

---Turns a failed `git` result into a one-line error message.
---@param res { code: integer, stderr?: string }
---@param what string Short name of the call, e.g. "git status"
---@return string
local function failure_text(res, what)
  if res.code == TIMEOUT_EXIT_CODE then
    return ("%s timed out after %ds"):format(what, GIT_TIMEOUT_MS / 1000)
  end
  local stderr = res.stderr or ""
  return stderr ~= "" and stderr or (what .. " failed")
end

---@private
---@internal
---Derives a single summary state from the parsed status fields.
---Precedence: dirty working tree first, then upstream divergence.
---@param dirty integer Number of changed entries
---@param ahead integer Commits ahead of upstream
---@param behind integer Commits behind upstream
---@return "clean"|"dirty"|"ahead"|"behind"|"diverged"
local function derive_state(dirty, ahead, behind)
  if dirty > 0 then
    return "dirty"
  elseif ahead > 0 and behind > 0 then
    return "diverged"
  elseif ahead > 0 then
    return "ahead"
  elseif behind > 0 then
    return "behind"
  end
  return "clean"
end

---@private
---@internal
---Parses `git status --porcelain=v2 --branch` output into a status record.
---Header lines start with `# branch.*`; every other non-empty line is a changed
---entry, so the working tree is dirty when at least one such line is present.
---@param repo string Absolute path to the repository (used for the display name)
---@param out string Raw stdout from the status command
---@return RepoDashboardRecord
local function parse_status(repo, out)
  local branch = "(detached)"
  local ahead, behind = 0, 0
  local has_upstream = false
  local dirty = 0

  for line in (out .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      if line:sub(1, 1) == "#" then
        local head = line:match("^# branch%.head (.+)$")
        if head then
          branch = head
        elseif line:match("^# branch%.upstream ") then
          has_upstream = true
        else
          local a, b = line:match("^# branch%.ab %+(%-?%d+) %-(%d+)$")
          if a then
            ahead, behind = tonumber(a) or 0, tonumber(b) or 0
          end
        end
      else
        dirty = dirty + 1
      end
    end
  end

  return {
    name = fnamemodify(repo, ":t"),
    path = repo,
    branch = branch,
    ahead = ahead,
    behind = behind,
    has_upstream = has_upstream,
    dirty = dirty,
    state = derive_state(dirty, ahead, behind),
  }
end

---@private
---@internal
---Reads the commit timestamp of HEAD. Separate from `git status`, which does
---not carry it; an empty repository has no HEAD and yields nil rather than an
---error, since "no commits yet" is a legitimate state for a fresh clone target.
---@param repo string Absolute path to the repository
---@param on_done fun(ts: integer|nil): nil
---@return nil
local function last_commit_ts(repo, on_done)
  vim.system(
    { "git", "log", "-1", "--format=%ct" },
    { cwd = repo, text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      if res.code ~= 0 then
        on_done(nil)
        return
      end
      on_done(tonumber(vim.trim(res.stdout or "")))
    end
  )
end

---@private
---@internal
---Queries the git status of a single repository, plus HEAD's commit date.
---The two git calls are independent, so they run concurrently and the record is
---handed back once both have returned.
---@param repo string Absolute path to the repository
---@param on_done fun(record: RepoDashboardRecord|nil, err: string|nil): nil
---@return nil
local function status_repo(repo, on_done)
  ---@type RepoDashboardRecord|nil
  local record
  ---@type string|nil
  local err
  local ts
  local got_status, got_ts = false, false

  local function settle()
    if not (got_status and got_ts) then return end
    if record then record.last_commit = ts end
    on_done(record, err)
  end

  vim.system(
    status_argv("--porcelain=v2", "--branch"),
    { cwd = repo, text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      if res.code ~= 0 then
        err = failure_text(res, "git status")
      else
        record = parse_status(repo, res.stdout or "")
      end
      got_status = true
      settle()
    end
  )

  last_commit_ts(repo, function(value)
    ts = value
    got_ts = true
    settle()
  end)
end

---Queries the git status of a single repository (no discovery, no progress
---indicator). Used to refresh one row after an interactive push/pull/fetch
---rather than re-reading every repository in the directory.
---@param repo string Absolute path to the repository
---@param on_done fun(record: RepoDashboardRecord|nil, err: string|nil): nil
---@return nil
function M.dashboard_one(repo, on_done)
  status_repo(repo, on_done)
end

---Collects a human-readable detail view of one repository: the porcelain
---short status plus the last few commits. Unlike `dashboard_one` this is not
---parsed into a record — it is meant to be shown verbatim, the way `git
---status` would print it.
---@param repo string Absolute path to the repository
---@param on_done fun(lines: string[]): nil Always called, with an error line on failure
---@return nil
function M.dashboard_detail(repo, on_done)
  local short, log
  local function settle()
    if short == nil or log == nil then return end

    -- `--branch` always emits a leading "## <branch>" line, so emptiness of the
    -- raw output is not a usable "is it clean" test: the entry lines are the
    -- ones that don't start with "##".
    local lines, entries = {}, 0
    for line in (short .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then
        lines[#lines + 1] = "  " .. line
        if line:sub(1, 2) ~= "##" then entries = entries + 1 end
      end
    end
    if entries == 0 then lines[#lines + 1] = "  working tree clean" end

    lines[#lines + 1] = ""
    lines[#lines + 1] = " Recent commits"
    if log ~= "" then
      for line in (log .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then lines[#lines + 1] = "  " .. line end
      end
    else
      lines[#lines + 1] = "  (no commits yet)"
    end

    on_done(lines)
  end

  vim.system(
    status_argv("--short", "--branch"),
    { cwd = repo, text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      short = (res.code == 0) and vim.trim(res.stdout or "")
        or ("error: " .. vim.trim(failure_text(res, "git status")))
      settle()
    end
  )

  vim.system(
    { "git", "log", "-5", "--format=%h  %<(18,trunc)%an  %s" },
    { cwd = repo, text = true, timeout = GIT_TIMEOUT_MS },
    function(res)
      log = (res.code == 0) and vim.trim(res.stdout or "") or ""
      settle()
    end
  )
end

---@private
---@internal
---Repository paths configured outside the normal `base_dir` scan
---(`dashboard.extra_paths`) that should still show up in the default
---dashboard page -- e.g. a Neovim config, which is a git repository in its
---own right but is never itself one of the checkouts cloned into
---`dashboard.base_dir`/`$REPOS_DIR`, so the scan above never finds it.
---
---Returned paths are absolute, deduplicated against `existing` (an entry
---already discovered by the scan is not repeated) and validated as actual
---git repositories -- one that no longer exists, or never was a repository,
---is reported and skipped rather than aborting the whole dashboard over a
---single stale config entry. Unlike a configured *group*'s `paths`
---(`resolve_group_repos`), an `extra_paths` entry is never scanned as a
---directory of repositories -- it must itself be one.
---@param existing string[] Absolute repository paths already collected by the scan
---@return string[] extra Absolute paths to add
local function extra_repo_paths(existing)
  local static_paths = (config.get().dashboard and config.get().dashboard.extra_paths) or {}
  -- The default page's own `a`/`x` overlay (see `state/dashboard_pages.lua`)
  -- -- keyed by "" (the empty page name), same as `features.dashboard.init`
  -- keys the named-group pages by `page.name`.
  local configured = require("gitsuite.state.dashboard_pages").apply("", static_paths)
  if #configured == 0 then return {} end

  ---@param path string
  ---@return string
  local function dedup_key(path)
    local key = unify_slashes(path)
    if is_windows() then key = key:lower() end
    return key
  end

  ---@type table<string, boolean>
  local seen = {}
  for _, p in ipairs(existing) do
    seen[dedup_key(fnamemodify(p, ":p"):gsub("[\\/]+$", ""))] = true
  end

  ---@type string[]
  local extra = {}
  for _, raw in ipairs(configured) do
    local resolved = fnamemodify(expand(raw), ":p"):gsub("[\\/]+$", "")
    local key = dedup_key(resolved)
    if not seen[key] then
      seen[key] = true
      if is_git_repo(resolved) then
        extra[#extra + 1] = resolved
      else
        notify("dashboard.extra_paths entry is not a git repository, skipped: " .. resolved, 3)
      end
    end
  end
  return extra
end

---@private
---@internal
---Shared core: reads the git status of every repository in `repos` (bounded
---parallelism, progress indicator, stable discovery-ordered result) and hands
---the compacted record list back via `on_complete`. Both the default page
---(`M.scan`) and a configured group (`M.scan_group`) resolve their own
---repository list and then call this with it.
---@param repos string[]
---@param progress_text string Shown while reading, e.g. "reading git state of 12 repositories"
---@param on_complete fun(records: RepoDashboardRecord[], errors: string[]): nil
---@return nil
local function read_statuses(repos, progress_text, on_complete)
  if #repos == 0 then
    on_complete({}, {})
    return
  end

  -- Indexed by discovery order so the dashboard stays stable despite async completion.
  ---@type table<integer, RepoDashboardRecord>
  local indexed = {}
  ---@type string[]
  local errors = {}
  local total = #repos
  local remaining = total

  local handle = progress.create(progress_text, total)

  local function finish()
    remaining = remaining - 1
    if handle then
      handle:update({
        text = ("%d of %d read"):format(total - remaining, total),
        current = total - remaining,
        total = total,
      })
    end
    if remaining > 0 then return end
    if handle then handle:finish(("read %d of %d repositories"):format(total - #errors, total)) end
    ---@type RepoDashboardRecord[]
    local records = {}
    for i = 1, total do
      if indexed[i] then records[#records + 1] = indexed[i] end
    end
    vim.schedule(function()
      on_complete(records, errors)
    end)
  end

  -- A bounded worker pool: MAX_PARALLEL reads start up front, and every
  -- completion starts the next repository in discovery order.
  local next_index = 1
  local function launch_next()
    if next_index > total then return end
    local i = next_index
    next_index = next_index + 1
    local repo = repos[i]
    status_repo(repo, function(record, err)
      if record then
        indexed[i] = record
      else
        errors[#errors + 1] = fnamemodify(repo, ":t") .. ": " .. (err or "unknown error")
      end
      finish()
      launch_next()
    end)
  end

  for _ = 1, math.min(MAX_PARALLEL, total) do
    launch_next()
  end
end

---Collects the git status of every repository in the resolved base directory
---(the default, unnamed dashboard page), plus whatever `dashboard.extra_paths`
---adds (see `extra_repo_paths` above) -- merged in regardless of whether the
---scan found anything at all, so a directory with no checkouts but a
---configured extra path still produces a dashboard.
---If the resolved path is itself a repository, only that one is reported
---(extra_paths are still merged in on top of it).
---Validation failures (missing git, inaccessible directory, no repositories) are
---reported via notification and abort early without invoking `on_complete`.
---@param path string|nil Optional directory or single-repo override (defaults to `dashboard.base_dir`)
---@param on_complete fun(records: RepoDashboardRecord[], errors: string[]): nil|nil Called once on completion
---@return nil
function M.scan(path, on_complete)
  if vim.fn.executable("git") ~= 1 then
    notify("Cannot read repository status: 'git' is not available in PATH", 4)
    return
  end

  local base_dir = resolve_base_dir(path)
  if not base_dir then
    notify("No repository directory provided and dashboard.base_dir is not set", 4)
    return
  end

  local stat = uv.fs_stat(base_dir)
  if not stat or stat.type ~= "directory" then
    notify("Repository directory is not accessible: " .. base_dir, 4)
    return
  end

  -- A path that is itself a repository is reported on its own; otherwise scan children.
  local repos = is_git_repo(base_dir) and { base_dir } or collect_repos(base_dir)
  vim.list_extend(repos, extra_repo_paths(repos))
  if #repos == 0 then
    notify("No git repositories found in " .. base_dir, 3)
    return
  end

  notify(("Reading git state of %d repositories in %s ..."):format(#repos, base_dir), 2)
  read_statuses(
    repos,
    ("reading git state of %d repositories"):format(#repos),
    function(records, errors)
      if on_complete then on_complete(records, errors) end
    end
  )
end

---Collects the git status of a configured `dashboard.groups` entry: each of
---`paths` is resolved via `resolve_group_repos` (itself if a repository,
---otherwise its immediate git-repository children), deduplicated, then read
---exactly like `M.scan`'s repositories.
---@param paths string[] A group's configured paths
---@param on_complete fun(records: RepoDashboardRecord[], errors: string[]): nil
---@return nil
function M.scan_group(paths, on_complete)
  if vim.fn.executable("git") ~= 1 then
    notify("Cannot read repository status: 'git' is not available in PATH", 4)
    return
  end

  local repos = repos_util.resolve_group_repos(paths)
  if #repos == 0 then
    notify("No git repositories found for this dashboard group", 3)
    on_complete({}, {})
    return
  end

  notify(("Reading git state of %d repositories ..."):format(#repos), 2)
  read_statuses(repos, ("reading git state of %d repositories"):format(#repos), on_complete)
end

return M
