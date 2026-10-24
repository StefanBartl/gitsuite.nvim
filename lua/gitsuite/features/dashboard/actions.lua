---@module 'gitsuite.features.dashboard.actions'
---@brief Single-repository git push/pull/fetch/update/sync for the dashboard.
---@description
--- Thin adapters over `lib.nvim.git`'s write primitives (`push_async`,
--- `pull_async`, `fetch_async`, `update_async`), reshaped from
--- `(opts, on_done, git_cmd)` to `(repo, on_done)` -- the shape
--- `gitsuite.features.dashboard.view`'s row/bulk actions already call,
--- ported unchanged from reposcope.nvim's own `utils.repo_actions`.
---
--- The `changed` flag `lib.nvim.git`'s functions report is dropped here: the
--- dashboard view re-reads a row's status after every action instead of
--- trusting a boolean, so nothing here currently consumes it. Add a second
--- return value if a future caller needs it -- Lua ignores extra returns a
--- caller does not bind.
---
--- `sync` is the one exception: it is not a thin adapter, since deciding
--- pull vs. push needs the ahead/behind counts a fetch alone does not
--- return, so it reads the repository's status itself (`dashboard.status`)
--- between the fetch and whichever of pull/push it picks. It calls through
--- `status.status_only(...)` rather than binding the function into a local,
--- the same way the calls below go through `git.push_async(...)` rather than
--- a bound `local push_async = git.push_async`: a bound local freezes
--- whatever `status.status_only` was the moment this module first loaded,
--- which stops tracking a later reassignment of that field (a test mocking
--- it, for instance) the way a live field lookup does not.

local git = require("lib.nvim.git")
local status = require("gitsuite.features.dashboard.status")

---@class GitSuiteDashboardActions
local M = {}

---A tiny async mutex: `sync`'s own fetch runs at whatever concurrency the
---caller gives it (read-only, same as `gf`), but the pull or push it decides
---to run afterward is serialized across every `sync` call in flight, exactly
---as a `gp`/`gP` batch already serializes itself. Without this, a `gS` batch
---running several `sync` calls at once (`dashboard.fetch_jobs`) could end up
---running that many simultaneous pushes the moment that many repositories
---turn out to be ahead -- the rate limit / auth-prompt storm `gp`/`gP` are
---already careful to avoid.
---@type (fun(): nil)[]
local write_queue = {}
local write_busy = false

---Runs `run` now if nothing else holds the write lock, otherwise queues it.
---`run` must call the `done` it is handed exactly once, when its own git
---call has returned, to hand the lock to the next queued write (or free it).
---@param run fun(done: fun(): nil): nil
---@return nil
local function with_write_lock(run)
  local function done()
    local next_run = table.remove(write_queue, 1)
    if next_run then
      next_run()
    else
      write_busy = false
    end
  end
  if write_busy then
    write_queue[#write_queue + 1] = function()
      run(done)
    end
  else
    write_busy = true
    run(done)
  end
end

---Pushes the current branch of `repo` to its upstream.
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.push(repo, on_done)
  git.push_async({ dir = repo }, on_done)
end

---Pulls the current branch of `repo` from its upstream (fast-forward only).
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.pull(repo, on_done)
  git.pull_async({ dir = repo }, on_done)
end

---Fetches `repo`'s remote-tracking refs (does not change the working tree).
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.fetch(repo, on_done)
  git.fetch_async({ dir = repo }, on_done)
end

---Fetches every remote of `repo` and then fast-forwards the current branch
----- the same pair `:Git dashboard update` runs across a whole page,
---expressed for a single repository so the bulk queue and a lone `gu` keymap
---agree on exactly what "update" means.
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.update(repo, on_done)
  git.update_async({ dir = repo }, on_done)
end

---Fetches `repo`, then settles it against its upstream: pulls (fast-forward
---only) when the fetch left it behind, pushes when it is ahead instead, or
---does nothing when it is already level. A repository that is both ahead and
---behind is left to the pull, which reports its own fast-forward failure --
---`gS` does not guess a merge or a rebase on a diverged branch.
---@param repo string Absolute path to the repository
---@param on_done fun(ok: boolean, err: string|nil): nil
---@return nil
function M.sync(repo, on_done)
  git.fetch_async({ dir = repo }, function(ok, err)
    if not ok then
      on_done(false, err)
      return
    end
    status.status_only(repo, function(record, status_err)
      if not record then
        on_done(false, status_err or "git status failed after fetch")
        return
      end
      if record.behind > 0 then
        with_write_lock(function(done)
          git.pull_async({ dir = repo }, function(ok2, err2)
            done()
            on_done(ok2, err2)
          end)
        end)
      elseif record.ahead > 0 then
        with_write_lock(function(done)
          git.push_async({ dir = repo }, function(ok2, err2)
            done()
            on_done(ok2, err2)
          end)
        end)
      else
        on_done(true, nil)
      end
    end)
  end)
end

return M
