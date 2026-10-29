---@module 'gitsuite.features.dashboard.actions'
---@brief Single-repository git push/pull/fetch/update for the dashboard.
---@description
--- Thin adapters over `lib.nvim.git`'s write primitives (`push_async`,
--- `pull_async`, `fetch_async`, `update_async`), reshaped from
--- `(opts, on_done, git_cmd)` to `(repo, on_done)` -- the shape
--- `gitsuite.features.dashboard.view`'s row/bulk actions already call,
--- ported unchanged from reposcope.nvim's own `utils.repo_actions`.
---
--- Every action answers `on_done(ok, err, detail)`. `detail` is a short phrase
--- for the batch's closing summary (`gitsuite.features.dashboard.bulk_report`)
--- saying what changed ("pulled 3 commits", "fetched new refs"); `nil` on
--- success means nothing did. `skipped` is the reason a successful action had
--- nothing to work on (a sync without an upstream). It is built from the `changed` flag
--- `lib.nvim.git`'s functions report; where that flag is unknown, the action
--- is reported as having done its work rather than as a no-op.

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

---Pushes the current branch of `repo` to its upstream.
---
---The commits ahead are counted first, only for the summary: a push of a level branch reports nothing, a
---push whose count git could not tell (no upstream yet) is still run and reported as "pushed".
---@param repo string Absolute path to the repository
---@param on_done GitSuiteDashboardActionDone
---@return nil
function M.push(repo, on_done)
  ahead_behind(repo, function(ahead)
    git.push_async({ dir = repo }, function(ok, err)
      if not ok then
        on_done(false, err)
      elseif ahead == 0 then
        on_done(true, nil)
      else
        on_done(true, nil, ahead and ("pushed " .. commits(ahead)) or "pushed")
      end
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
---@param repo string Absolute path to the repository
---
---The summary detail names the direction and the count ("pulled 3 commits", "pushed 1 commit"); a
---repository with nothing to compare with is reported as skipped, a level one as unchanged.
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
      elseif ahead == nil then
        on_done(true, nil, nil, "no upstream or detached HEAD")
      elseif ahead == 0 and behind == 0 then
        on_done(true, nil)
      elseif behind == 0 then
        git.push_async({ dir = repo }, function(ok, perr)
          on_done(ok, perr, ok and ("pushed " .. commits(ahead)) or nil)
        end)
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
