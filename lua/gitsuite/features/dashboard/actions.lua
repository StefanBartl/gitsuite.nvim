---@module 'gitsuite.features.dashboard.actions'
---@brief Single-repository git push/pull/fetch/update for the dashboard.
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

local git = require("lib.nvim.git")

---@class GitSuiteDashboardActions
local M = {}

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

---Environment for the one `git` call below whose error text is read: the same wording on every machine,
---whatever language git is set to.
local C_LOCALE = { LC_ALL = "C", LANGUAGE = "C" }

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
---@param on_done fun(ok: boolean, err: string|nil): nil
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
      elseif ahead == nil or (ahead == 0 and behind == 0) then
        on_done(true, nil)
      elseif behind == 0 then
        git.push_async({ dir = repo }, on_done)
      elseif ahead == 0 then
        git.pull_async({ dir = repo }, on_done)
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
