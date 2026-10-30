---@module 'gitsuite.features.dashboard.repo_state'
---@brief Per-repository lock and bulk-phase state machine for the dashboard.
---@description
--- A bulk action (`gf`, `gp`, `gu`, ...) walks the dashboard's repositories one
--- after another. Waiting for the whole walk before any single repository may be
--- touched again wastes the time it takes to finish the other forty -- the first
--- ten are long done and one of them may well have commits to pull. So instead of
--- one global "a bulk is running" flag, every repository carries its own state:
---
---   pending  -> queued by the running bulk, not started yet
---   fetching -> the bulk's git call on it is in flight (the name is the common
---               `gf` case; a bulk push/update uses the same phase)
---   done     -> the bulk is through with it, its row was re-read
---   failed   -> the bulk's git call on it failed (no process left on it)
---
--- A repository without a phase is not part of a running bulk at all.
---
--- On top of that sits a per-repository lock (a try-lock keyed by path, not a
--- global semaphore): whoever starts a `git` process that writes to a repository
--- holds its lock until that process has returned, so two processes never touch
--- the same repository at once -- while different repositories run in parallel.
---
--- `acquire` combines both: a row action may start only on a repository that is
--- not locked and whose bulk phase (if any) is settled (`done` or `failed`).
--- `failed` counts as settled because nothing runs there any more, and retrying
--- is exactly what a user wants to do with a failed row.
---
--- Pure Lua state, no `vim.*` calls: the dashboard view drives it from its own
--- callbacks, and the specs drive it directly.

---@alias GitSuiteDashboardPhase "pending"|"fetching"|"done"|"failed"

---@class GitSuiteDashboardRepoState
local M = {}

---Lock holders, keyed by repository path -> verb of the action holding it.
---@type table<string, string>
local _locks = {}

---Bulk phases, keyed by repository path. Empty while no bulk runs.
---@type table<string, GitSuiteDashboardPhase>
local _phases = {}

---Verb of the bulk currently running, or nil.
---@type string|nil
local _bulk_verb

---Generation of the latest bulk, bumped by every `begin_bulk`. A bulk's own
---callbacks pass it back, so the ones of a bulk that was superseded (its phases
---replaced by a newer bulk's while its git calls were still in flight) can
---neither write phases into the newer bulk nor end it.
---@type integer
local _generation = 0

---Takes `path`'s lock for `verb`. Never waits: the caller decides what to do
---when the repository is busy.
---@param path string Absolute repository path
---@param verb string Action taking the lock, e.g. "pull"
---@return boolean ok
---@return string|nil holder Verb already holding the lock, when `ok` is false
function M.try_lock(path, verb)
  local holder = _locks[path]
  if holder then return false, holder end
  _locks[path] = verb
  return true, nil
end

---Releases `path`'s lock. Releasing a free lock is a no-op.
---@param path string
---@return nil
function M.unlock(path)
  _locks[path] = nil
end

---The verb holding `path`'s lock, or nil when it is free.
---@param path string
---@return string|nil
function M.holder(path)
  return _locks[path]
end

---Starts a bulk over `paths`: every one of them becomes `pending`.
---@param verb string
---@param paths string[]
---@return integer generation Hand back to `set_phase`/`end_bulk` from this bulk's callbacks
function M.begin_bulk(verb, paths)
  _generation = _generation + 1
  _bulk_verb = verb
  _phases = {}
  for _, path in ipairs(paths) do
    _phases[path] = "pending"
  end
  return _generation
end

---Whether `generation` (nil: whoever asks) is the running bulk's.
---@param generation integer|nil
---@return boolean
local function _current(generation)
  return generation == nil or generation == _generation
end

---Moves `path` to `phase` within the running bulk. A no-op for a superseded
---bulk's `generation`.
---@param path string
---@param phase GitSuiteDashboardPhase
---@param generation? integer The bulk's own generation, from `begin_bulk`
---@return nil
function M.set_phase(path, phase, generation)
  if _bulk_verb and _current(generation) then _phases[path] = phase end
end

---`path`'s phase in the running bulk, or nil when it is not part of one.
---@param path string
---@return GitSuiteDashboardPhase|nil
function M.phase(path)
  return _phases[path]
end

---Verb of the running bulk, or nil.
---@return string|nil
function M.bulk_verb()
  return _bulk_verb
end

---Ends the running bulk: every phase is dropped. Locks are left alone, they
---belong to the processes that hold them. A superseded bulk's `generation`
---ends nothing: the bulk running now is not its to end.
---@param generation? integer The bulk's own generation, from `begin_bulk`
---@return boolean ended
function M.end_bulk(generation)
  if not _current(generation) then return false end
  _bulk_verb = nil
  _phases = {}
  return true
end

---Progress of the running bulk.
---@return { total: integer, pending: integer, fetching: integer, done: integer, failed: integer }
function M.counts()
  local c = { total = 0, pending = 0, fetching = 0, done = 0, failed = 0 }
  for _, phase in pairs(_phases) do
    c.total = c.total + 1
    c[phase] = c[phase] + 1
  end
  return c
end

---Takes `path`'s lock for a single-repository action, if that is allowed now:
---the repository must not be locked, and if a bulk includes it, the bulk must
---be through with it (`done` or `failed`).
---@param path string
---@param verb string
---@return boolean ok
---@return string|nil reason Why not, as a message fit for the user
function M.acquire(path, verb)
  local phase = _phases[path]
  if phase == "pending" then
    return false,
      ("still queued in the bulk %s - wait until its row is done"):format(_bulk_verb or "action")
  elseif phase == "fetching" then
    return false,
      ("the bulk %s is running on it right now - wait until its row is done"):format(
        _bulk_verb or "action"
      )
  end
  local ok, holder = M.try_lock(path, verb)
  if not ok then return false, ("%s already running"):format(holder) end
  return true, nil
end

---Forgets every lock and phase. For the specs; the view never calls it, since
---a lock dropped while its process still runs is the very thing this prevents.
---@return nil
function M.reset()
  _locks = {}
  M.end_bulk()
end

return M
