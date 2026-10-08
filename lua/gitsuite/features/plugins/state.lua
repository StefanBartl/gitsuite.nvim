---@module 'gitsuite.features.plugins.state'
--- Where `:Git plugins report` keeps its reports: one JSON file below
--- `stdpath("state")/gitsuite/`, per machine (clones, reflogs and the lock file
--- are machine-local; the file records the host that wrote it).
---
--- The file is an answer to "what changed", so losing it silently is worse than
--- not having it:
---   * writes are atomic (a sibling temp file renamed over the target);
---   * a file that cannot be read back is MOVED aside (`.corrupt`), never
---     overwritten, and a store from a newer gitsuite or another host is left
---     alone (the latter is set aside as `.foreign-<host>.bak` before this
---     machine starts its own);
---   * the file is read fresh before every write, so two editors adding
---     reports do not drop each other's.
---
--- Retention is a pair of caps (`keep_reports`, `max_age_days`) plus a byte cap
--- on the whole file; the newest report is never rotated out.

local atomic = require("lib.nvim.fs.write.atomic")
local uv = vim.uv or vim.loop

local M = {}

---Format version of the file; a newer one is read-only to this code.
M.VERSION = 1
---Upper bound on the file: oldest reports go first when it would be larger.
M.MAX_BYTES = 8 * 1024 * 1024
---A file larger than this is not even read.
M.MAX_READ = 64 * 1024 * 1024

---@class GitSuite.Plugins.Store
---@field version integer
---@field host string
---@field reports GitSuite.Plugins.Report[]  Newest first.

---@class GitSuite.Plugins.StoreInfo
---@field foreign? string    The host a store found on disk was written by, when it is not this machine.
---@field recovered? string  Where an unreadable file was moved to.
---@field readonly? string   Why the store must not be written (newer format, not a plain file).
---@field dropped? integer   Reports in the file that were not usable and are left out.

---@return string
function M.path()
  return vim.fn.stdpath("state") .. "/gitsuite/plugins_reports.json"
end

---@return string
function M.host()
  return uv.os_gethostname() or "unknown"
end

---@return GitSuite.Plugins.Store
local function empty()
  return { version = M.VERSION, host = M.host(), reports = {} }
end

---Move `path` aside to `<path><suffix>`, never over an earlier backup.
---@param path string
---@param suffix string
---@return string|nil moved_to
local function move_aside(path, suffix)
  local target = path .. suffix
  if uv.fs_stat(target) then target = ("%s%s.%d"):format(path, suffix, os.time()) end
  if uv.fs_rename(path, target) then return target end
  return nil
end

---Latest time a stored report may claim (year 2100); see `gitfs.MAX_TIME`.
local MAX_TIME = 4102444800

---@param n any
---@return boolean
local function plausible_time(n)
  return type(n) == "number" and n == n and n >= 0 and n <= MAX_TIME
end

---@param list any
---@return boolean
local function is_list(list)
  return type(list) == "table" and (next(list) == nil or vim.islist(list))
end

---Make a report read from disk safe for the code that renders and reuses it:
---the file may come from another version, another tool or a hand edit, and
---every field is checked before anything indexes into it. Entries that do not
---fit are dropped, not repaired. `nil` = the report as a whole is unusable.
---@param r any
---@return table|nil
local function normalize(r)
  if type(r) ~= "table" or type(r.id) ~= "string" or r.id:find("[%c]") then return nil end
  -- a report "from the future" would stay the newest one forever
  if not plausible_time(r.at) or r.at > os.time() + 86400 then return nil end
  if r.mode ~= "updated" and r.mode ~= "pending" then return nil end
  if not is_list(r.plugins) then return nil end

  local plugins = {}
  for _, entry in ipairs(r.plugins) do
    if
      type(entry) == "table"
      and type(entry.name) == "string"
      and type(entry.dir) == "string"
      and type(entry.status) == "string"
    then
      if entry.commits ~= nil then
        if is_list(entry.commits) then
          local commits = {}
          for _, c in ipairs(entry.commits) do
            if type(c) == "table" and type(c.sha) == "string" then commits[#commits + 1] = c end
          end
          entry.commits = commits
        else
          entry.commits = nil
        end
      end
      for _, key in ipairs({ "time", "fetched_at" }) do
        if entry[key] ~= nil and not plausible_time(entry[key]) then entry[key] = nil end
      end
      plugins[#plugins + 1] = entry
    end
  end
  r.plugins = plugins

  if type(r.counts) ~= "table" then r.counts = {} end
  for _, key in ipairs({ "checked", "changed", "commits", "unchanged" }) do
    if type(r.counts[key]) ~= "number" then r.counts[key] = 0 end
  end
  if r.run ~= nil then
    local run = r.run
    if
      type(run) ~= "table"
      or not plausible_time(run.first)
      or not plausible_time(run.last)
      or type(run.older) ~= "number"
      or type(run.plugins) ~= "number"
    then
      r.run = nil
    end
  end
  if not is_list(r.errors) then r.errors = {} end
  if not is_list(r.sources) then r.sources = {} end
  if type(r.heads) ~= "table" then r.heads = {} end
  if type(r.host) ~= "string" then r.host = "?" end
  if r.lazy ~= nil and type(r.lazy) ~= "string" then r.lazy = nil end
  return r
end

---Read the store. Never throws; never writes except to move a broken file
---aside -- and not even that with `opts.peek` (`:checkhealth` looks, it does
---not tidy up).
---@param path? string
---@param opts? { peek?: boolean }
---@return GitSuite.Plugins.Store store
---@return GitSuite.Plugins.StoreInfo info
function M.load(path, opts)
  path = path or M.path()
  local peek = opts ~= nil and opts.peek == true
  ---@type GitSuite.Plugins.StoreInfo
  local info = {}
  local st = uv.fs_lstat(path)
  if not st then return empty(), info end
  if st.type ~= "file" or st.size > M.MAX_READ then
    info.readonly = "the report store is not a plain file of a sane size: " .. path
    return empty(), info
  end

  local f = io.open(path, "rb")
  if not f then
    -- Busy (an antivirus scan, another instance) is not "broken": leave it be.
    info.readonly = "the report store could not be opened: " .. path
    return empty(), info
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text or "", { luanil = { object = true, array = true } })
  if
    not (
      ok
      and type(data) == "table"
      and type(data.version) == "number"
      and type(data.reports) == "table"
    )
  then
    if peek then
      info.recovered = path -- unreadable; a real load would move it aside
    else
      info.recovered = move_aside(path, ".corrupt")
      if not info.recovered then
        info.readonly = "the report store is unreadable and could not be moved aside: " .. path
      end
    end
    return empty(), info
  end
  if data.version > M.VERSION then
    info.readonly = ("the report store was written by a newer gitsuite (format %d)"):format(
      data.version
    )
    return empty(), info
  end

  local store = empty()
  local dropped = 0
  if type(data.host) == "string" and data.host ~= M.host() then
    -- Another machine's store: its clones, reflogs and heads are not ours, so
    -- nothing of it is used (`add` keeps the file aside before writing).
    info.foreign = data.host
    return store, info
  end
  for _, report in ipairs(data.reports) do
    local usable = normalize(report)
    if usable then
      store.reports[#store.reports + 1] = usable
    else
      dropped = dropped + 1
    end
  end
  table.sort(store.reports, function(a, b)
    return a.at > b.at
  end)
  if dropped > 0 then info.dropped = dropped end
  return store, info
end

---Apply the retention caps to `store`, in place. The newest report always stays.
---@param store GitSuite.Plugins.Store
---@param cfg { keep_reports: integer, max_age_days: integer }
---@param now integer
function M.prune(store, cfg, now)
  table.sort(store.reports, function(a, b)
    return a.at > b.at
  end)
  local max_age = cfg.max_age_days * 86400
  local kept = {}
  for i, report in ipairs(store.reports) do
    if i == 1 or (i <= cfg.keep_reports and now - report.at <= max_age) then
      kept[#kept + 1] = report
    end
  end
  store.reports = kept
end

---Add `report` to the stored ones and write the file.
---@param report GitSuite.Plugins.Report
---@param cfg { keep_reports: integer, max_age_days: integer }
---@param path? string
---@return boolean ok
---@return string|nil err
---@return GitSuite.Plugins.StoreInfo|nil info
function M.add(report, cfg, path)
  path = path or M.path()
  local store, info = M.load(path)
  if info.readonly then return false, info.readonly, info end

  if info.foreign then
    -- Another machine's store (the state folder is synced): keep it, start ours.
    local host = info.foreign:gsub("[^%w%._%-]", "_")
    if not move_aside(path, ".foreign-" .. host .. ".bak") then
      return false, "the report store of another machine could not be moved aside", info
    end
    store = empty()
  end

  for i = #store.reports, 1, -1 do
    if store.reports[i].id == report.id then table.remove(store.reports, i) end
  end
  table.insert(store.reports, 1, report)
  M.prune(store, cfg, report.at)

  local ok_enc, json = pcall(vim.json.encode, store)
  while ok_enc and #json > M.MAX_BYTES and #store.reports > 1 do
    table.remove(store.reports)
    ok_enc, json = pcall(vim.json.encode, store)
  end
  if not ok_enc then return false, "could not encode the report: " .. tostring(json), info end
  if #json > M.MAX_BYTES then
    -- One report alone is over the cap: writing it would leave a file the next
    -- run refuses to read.
    return false, "the report is too large to store (lower plugins.max_commits)", info
  end

  local ok, err = atomic(path, json, { mkdirp = true })
  if not ok then return false, err, info end
  return true, nil, info
end

---Index of every stored plugin entry by `dir@from...to`: a range of two
---commits never changes, so a hit saves the git process for good.
---@param store GitSuite.Plugins.Store
---@return table<string, table>
function M.cache_index(store)
  local index = {}
  for _, report in ipairs(store.reports) do
    for _, entry in ipairs(report.plugins) do
      if type(entry) == "table" and entry.dir and entry.from and entry.to and entry.commits then
        local key = M.cache_key(entry.dir, entry.from, entry.to)
        if not index[key] then index[key] = entry end
      end
    end
  end
  return index
end

---@param dir string
---@param from string
---@param to string
---@return string
function M.cache_key(dir, from, to)
  return ("%s@%s...%s"):format(dir, from, to)
end

---Where `dir` stood when it was last reported: the fallback for "from" when
---the reflog says nothing (an expired or missing reflog).
---@param store GitSuite.Plugins.Store
---@param dir string
---@return string|nil head
function M.snapshot(store, dir)
  for _, report in ipairs(store.reports) do
    -- `heads` has every plugin the report looked at, changed or not.
    local head = type(report.heads) == "table" and report.heads[dir] or nil
    if type(head) == "string" and head:match("^%x+$") then return head end
  end
  return nil
end

return M
