---@module 'gitsuite.features.dashboard.actions'
---@brief Single-repository git push/pull/fetch/update for the dashboard.
---@description
--- Thin adapters over `lib.nvim.git`'s write primitives (`push_async`,
--- `pull_async`, `fetch_async`, `update_async`), reshaped from
--- `(opts, on_done, git_cmd)` to `(repo, on_done)` -- the shape
--- `gitsuite.features.dashboard.view`'s row/bulk actions already call,
--- ported unchanged from reposcope.nvim's own `utils.repo_actions`.
---
--- Every action answers `on_done(ok, err, detail, skipped)`
--- (`GitSuiteDashboardActionDone`). `detail` is a short phrase for the batch's
--- closing summary (`gitsuite.features.dashboard.bulk_report`) saying what
--- changed ("pulled 3 commits", "fetched new refs"); `nil` on success means
--- nothing did. `skipped` is the reason a successful action had nothing to work
--- on (a sync without an upstream). fetch/pull/update build `detail` from the
--- `changed` flag `lib.nvim.git`'s functions report (where that flag is unknown,
--- the action is reported as having done its work rather than as a no-op);
--- push and sync build it from commit counts read with `git rev-list`.

local git = require("lib.nvim.git")
local commits = require("gitsuite.features.dashboard.bulk_report").commits

---@alias GitSuiteDashboardActionDone fun(ok: boolean, err: string|nil, detail: string|nil, skipped: string|nil): nil

---@class GitSuiteDashboardActions
local M = {}

---Wraps `on_done` for a `lib.nvim.git` call that reports `changed`.
---@param on_done GitSuiteDashboardActionDone
---@param label string The detail when something (or possibly something) changed
---@return fun(ok: boolean, err: string|nil, changed: boolean|nil): nil
local function by_changed(on_done, label)
  return function(ok, err, changed)
    if not ok then
      on_done(false, err)
    elseif changed == false then
      on_done(true, nil)
    else
      on_done(true, nil, label)
    end
  end
end

---Environment for the one `git` call below whose error text is read: the same wording on every machine,
---whatever language git is set to.
local C_LOCALE = { LC_ALL = "C", LANGUAGE = "C" }

---Pulls the current branch of `repo` from its upstream (fast-forward only).
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.pull(repo, on_done)
  git.pull_async({ dir = repo }, by_changed(on_done, "pulled new commits"))
end

---Fetches `repo`'s remote-tracking refs (does not change the working tree).
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.fetch(repo, on_done)
  git.fetch_async({ dir = repo }, by_changed(on_done, "fetched new refs"))
end

---Fetches every remote of `repo` and then fast-forwards the current branch
----- the same pair `:Git dashboard update` runs across a whole page,
---expressed for a single repository so the bulk queue and a lone `gu` keymap
---agree on exactly what "update" means.
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.update(repo, on_done)
  git.update_async({ dir = repo }, by_changed(on_done, "fast-forwarded"))
end

---How far the current branch of `repo` is from its upstream, as the last fetch left it.
---
---`on_done(ahead, behind)` with the two commit counts; `on_done(nil, nil, nil)` for a repository with nothing
---to compare with (no upstream configured, or a detached HEAD): there is nothing to bring level, which is not
---an error; `on_done(nil, nil, err)` when git could not tell.
---@param repo string Absolute path to the repository
---@param on_done fun(ahead: integer|nil, behind: integer|nil, err: string|nil): nil
---@return nil
local function ahead_behind(repo, on_done)
  git.run_async(
    { "rev-list", "--left-right", "--count", "HEAD...@{u}" },
    { dir = repo, read_only = true, env = C_LOCALE },
    function(res)
      if res.ok then
        local ahead, behind = (res.stdout or ""):match("^%s*(%d+)%s+(%d+)%s*$")
        if ahead and behind then
          on_done(tonumber(ahead), tonumber(behind), nil)
        else
          on_done(nil, nil, "unexpected output of git rev-list: " .. vim.trim(res.stdout or ""))
        end
        return
      end
      local text = vim.trim(res.stderr or "")
      if text:find("no upstream", 1, true) or text:find("does not point to a branch", 1, true) then
        on_done(nil, nil, nil)
      else
        on_done(
          nil,
          nil,
          text ~= "" and text or ("git rev-list failed (exit code %d)"):format(res.code)
        )
      end
    end
  )
end

---The remote-tracking refs of `repo` and where they point, `nil` when git could not list them.
---@param repo string Absolute path to the repository
---@param on_done fun(refs: table<string, string>|nil): nil
---@return nil
local function tracking_refs(repo, on_done)
  git.run_async(
    { "for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes" },
    { dir = repo, read_only = true, env = C_LOCALE },
    function(res)
      if not res.ok then
        on_done(nil)
        return
      end
      ---@type table<string, string>
      local refs = {}
      for name, sha in (res.stdout or ""):gmatch("(%S+) (%x+)") do
        refs[name] = sha
      end
      on_done(refs)
    end
  )
end

---How many commits a finished push sent, from the remote-tracking refs before and after it (`git push`
---moves the ones of the refs it updated). That is what the push really did, whatever its destination: in a
---triangular workflow (`remote.pushDefault` naming a fork) that is not the upstream, and `@{push}` cannot
---even be resolved under `push.default=simple`.
---
---`on_done(0)` when no ref moved; `on_done(nil)` when the count is unknown (a ref was created, or a listing
---or the count failed).
---@param repo string Absolute path to the repository
---@param before table<string, string>|nil
---@param on_done fun(n: integer|nil): nil
---@return nil
local function pushed_count(repo, before, on_done)
  if not before then
    on_done(nil)
    return
  end
  tracking_refs(repo, function(after)
    if not after then
      on_done(nil)
      return
    end
    ---@type string[], string[]
    local new, old = {}, {}
    for name, sha in pairs(after) do
      if before[name] == nil then
        on_done(nil)
        return
      elseif before[name] ~= sha then
        new[#new + 1] = sha
        old[#old + 1] = before[name]
      end
    end
    if #new == 0 then
      on_done(0)
      return
    end
    local args = { "rev-list", "--count" }
    vim.list_extend(args, new)
    args[#args + 1] = "--not"
    vim.list_extend(args, old)
    git.run_async(args, { dir = repo, read_only = true, env = C_LOCALE }, function(res)
      local n = res.ok and (res.stdout or ""):match("^%s*(%d+)%s*$") or nil
      on_done(n and tonumber(n) or nil)
    end)
  end)
end

---Pushes the current branch of `repo` (`git push`, to wherever git's config sends it) and reports what the
---push sent: nothing when no remote-tracking ref moved, "pushed N commits", or "pushed" when the count is
---unknown.
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.push(repo, on_done)
  tracking_refs(repo, function(before)
    git.push_async({ dir = repo }, function(ok, err)
      if not ok then
        on_done(false, err)
        return
      end
      pushed_count(repo, before, function(n)
        if n == 0 then
          on_done(true, nil)
        else
          on_done(true, nil, n and ("pushed " .. commits(n)) or "pushed")
        end
      end)
    end)
  end)
end

---Brings `repo` level with its upstream in whichever direction it is off, in one go: fetch every remote, then
---
---  * behind only  -> `git pull --ff-only`
---  * ahead only   -> `git push`
---  * level, or no upstream to compare with -> nothing more (the fetch is all)
---  * both ahead and behind (diverged) -> **neither**: fast-forward is impossible and a push would be refused
---    or, forced, would throw the upstream's commits away. It is reported as a failure that names the counts,
---    so the repository shows up in the batch's list of what needs a person.
---
---The counts are read after the fetch, so they are the remote's state now, not the dashboard's of a moment
---ago.
---
---The summary detail names the direction and the count ("pulled 3 commits", "pushed 1 commit"; the push
---count is read against `@{push}`, like `M.push`); a repository with nothing to compare with is reported as
---skipped, a level one as unchanged.
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.sync(repo, on_done)
  git.fetch_async({ dir = repo }, function(fetched, ferr)
    if not fetched then
      on_done(false, ferr)
      return
    end
    ahead_behind(repo, function(ahead, behind, err)
      if err then
        on_done(false, err)
      elseif ahead == nil or behind == nil then
        on_done(true, nil, nil, "no upstream or detached HEAD")
      elseif ahead == 0 and behind == 0 then
        on_done(true, nil)
      elseif behind == 0 then
        M.push(repo, on_done)
      elseif ahead == 0 then
        git.pull_async({ dir = repo }, function(ok, perr)
          on_done(ok, perr, ok and ("pulled " .. commits(behind)) or nil)
        end)
      else
        on_done(
          false,
          ("diverged: %d ahead, %d behind - neither pulled nor pushed"):format(ahead, behind)
        )
      end
    end)
  end)
end

return M
