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
---@field readonly_kind? "newer"|"not_file"|"unopenable"|"unmovable"  What `readonly` is about, for advice that fits the cause.
---@field dropped? integer   Reports in the file that were not usable and are left out.

---@return string
function M.path()
  return vim.fn.stdpath("state") .. "/gitsuite/plugins_reports.json"
end

---@return string
function M.host()
  return uv.os_gethostname() or "unknown"
end

---Host names compared the way a machine's name is: a case-folded name without
---its domain (`Laptop`, `laptop` and `laptop.local` are one machine).
---@param host any
---@return string
local function host_key(host)
  return (tostring(host or ""):lower():match("^[^.]*"))
end

---The file a path really names: a store that is a symbolic link (a dotfiles
---manager, a synced folder) is read and written where it points; renaming a
---new file over the link would replace the link instead.
---@param path string
---@return string
local function real_path(path)
  local st = uv.fs_lstat(path)
  if st and st.type == "link" then return uv.fs_realpath(path) or path end
  return path
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

---Longest string kept from a stored report (the writer caps its own fields far
---lower; this only bounds a hand-edited or hostile file).
local MAX_STR = 8192

---@param v any
---@param max? integer
---@return string|nil
local function str(v, max)
  if type(v) ~= "string" then return nil end
  max = max or MAX_STR
  return #v <= max and v or v:sub(1, max)
end

---@param v any
---@return string|nil
local function hex(v)
  if type(v) == "string" and #v >= 7 and #v <= 64 and v:match("^%x+$") then return v end
  return nil
end

---@param v any
---@return boolean|nil
local function bool(v)
  if type(v) == "boolean" then return v end
  return nil
end

---@param v any
---@return number|nil
local function count(v)
  if type(v) == "number" and v == v and v >= 0 and v < 2 ^ 53 then return v end
  return nil
end

---One stored commit, field by field; `nil` = unusable.
---@param c any
---@return table|nil
local function normalize_commit(c)
  local sha = type(c) == "table" and hex(c.sha) or nil
  if not sha then return nil end
  return {
    sha = sha,
    subject = str(c.subject, 1024) or "",
    body = str(c.body, 4096) or "",
    author = str(c.author, 1024) or "",
    time = plausible_time(c.time) and c.time or nil,
    side = (c.side == "<" or c.side == ">") and c.side or nil,
  }
end

---One stored plugin entry, field by field (so nothing a renderer or the cache
---indexes into can be of the wrong type); `nil` = unusable. `url` is not kept:
---an older version stored it, and it may carry credentials.
---@param entry any
---@return table|nil
local function normalize_entry(entry)
  if type(entry) ~= "table" then return nil end
  local name, dir, status = str(entry.name, 1024), str(entry.dir, 4096), str(entry.status, 64)
  if not (name and dir and status) then return nil end
  local out = {
    name = name,
    dir = dir,
    status = status,
    managed_by = str(entry.managed_by, 64),
    source = str(entry.source, 32),
    confidence = str(entry.confidence, 32),
    head = hex(entry.head),
    from = hex(entry.from),
    to = hex(entry.to),
    to_label = str(entry.to_label, 512),
    reason = str(entry.reason, 2048),
    time = plausible_time(entry.time) and entry.time or nil,
    fetched_at = plausible_time(entry.fetched_at) and entry.fetched_at or nil,
    ahead = count(entry.ahead),
    behind = count(entry.behind),
    truncated = bool(entry.truncated),
    locked = bool(entry.locked),
    merges = bool(entry.merges),
  }
  if entry.commits ~= nil and is_list(entry.commits) then
    local commits = {}
    for _, c in ipairs(entry.commits) do
      local usable = normalize_commit(c)
      if usable then commits[#commits + 1] = usable end
    end
    out.commits = commits
  end
  return out
end

---@param list any
---@return string[]
local function string_list(list)
  local out = {}
  if is_list(list) then
    for _, v in ipairs(list) do
      local item = str(v, 2048)
      if item then out[#out + 1] = item end
    end
  end
  return out
end

---Make a report read from disk safe for the code that renders and reuses it:
---the file may come from another version, another tool or a hand edit, and
---every field is checked before anything indexes into it. Entries that do not
---fit are dropped, not repaired. `nil` = the report as a whole is unusable.
---@param r any
---@return table|nil
local function normalize(r)
  if type(r) ~= "table" or type(r.id) ~= "string" or #r.id > 128 or r.id:find("[%c]") then
    return nil
  end
  -- a report "from the future" would stay the newest one forever
  if not plausible_time(r.at) or r.at > os.time() + 86400 then return nil end
  if r.mode ~= "updated" and r.mode ~= "pending" then return nil end
  if not is_list(r.plugins) then return nil end

  local plugins = {}
  for _, entry in ipairs(r.plugins) do
    local usable = normalize_entry(entry)
    if usable then plugins[#plugins + 1] = usable end
  end

  local counts = {}
  for _, key in ipairs({ "checked", "changed", "commits", "unchanged", "failed" }) do
    counts[key] = count(type(r.counts) == "table" and r.counts[key] or nil) or 0
  end

  local run
  if type(r.run) == "table" then
    local first, last = r.run.first, r.run.last
    local older, n = count(r.run.older), count(r.run.plugins)
    if plausible_time(first) and plausible_time(last) and older and n then
      run = { first = first, last = last, older = older, plugins = n }
    end
  end

  local fetch
  if type(r.fetch) == "table" then
    local checked, known = count(r.fetch.checked), count(r.fetch.known)
    if checked and known then
      fetch = {
        checked = checked,
        known = known,
        oldest = plausible_time(r.fetch.oldest) and r.fetch.oldest or nil,
        newest = plausible_time(r.fetch.newest) and r.fetch.newest or nil,
      }
    end
  end

  local heads = {}
  if type(r.heads) == "table" then
    for dir, sha in pairs(r.heads) do
      if type(dir) == "string" and #dir <= 4096 and hex(sha) then heads[dir] = sha end
    end
  end

  return {
    version = count(r.version) or M.VERSION,
    id = r.id,
    at = r.at,
    mode = r.mode,
    host = str(r.host, 256) or "?",
    lazy = str(r.lazy, 64),
    sources = string_list(r.sources),
    errors = string_list(r.errors),
    run = run,
    fetch = fetch,
    plugins = plugins,
    heads = heads,
    counts = counts,
  }
end

---Read the store. Never throws; never writes except to move a broken file
---aside -- and not even that with `opts.peek` (`:checkhealth` looks, it does
---not tidy up).
---@param path? string
---@param opts? { peek?: boolean }
---@return GitSuite.Plugins.Store store
---@return GitSuite.Plugins.StoreInfo info
function M.load(path, opts)
  path = real_path(path or M.path())
  local peek = opts ~= nil and opts.peek == true
  ---@type GitSuite.Plugins.StoreInfo
  local info = {}
  local st = uv.fs_lstat(path)
  if not st then return empty(), info end
  if st.type ~= "file" or st.size > M.MAX_READ then
    info.readonly = "the report store is not a plain file of a sane size: " .. path
    info.readonly_kind = "not_file"
    return empty(), info
  end

  local f = io.open(path, "rb")
  if not f then
    -- Busy (an antivirus scan, another instance) is not "broken": leave it be.
    info.readonly = "the report store could not be opened: " .. path
    info.readonly_kind = "unopenable"
    return empty(), info
  end
  local text = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, text or "", { luanil = { object = true } })
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
        info.readonly_kind = "unmovable"
      end
    end
    return empty(), info
  end
  if data.version > M.VERSION then
    info.readonly = ("the report store was written by a newer gitsuite (format %d)"):format(
      data.version
    )
    info.readonly_kind = "newer"
    return empty(), info
  end

  local store = empty()
  local dropped = 0
  if type(data.host) == "string" and host_key(data.host) ~= host_key(M.host()) then
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
  path = real_path(path or M.path())
  local store, info = M.load(path)
  if info.readonly then return false, info.readonly, info end

  if info.dropped then
    -- The rewrite below leaves the unusable reports out: keep the file as it was
    -- once, so a report of a newer build or a hand edit is not lost for good.
    local backup = path .. ".dropped.bak"
    if not uv.fs_stat(backup) then pcall(uv.fs_copyfile, path, backup) end
  end

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

  -- Size each report once, drop the oldest until the file fits, encode once more.
  local sizes, total = {}, 64
  for i, stored in ipairs(store.reports) do
    local ok_one, one = pcall(vim.json.encode, stored)
    if not ok_one then return false, "could not encode the report: " .. tostring(one), info end
    sizes[i] = #one + 1
    total = total + sizes[i]
  end
  while total > M.MAX_BYTES and #store.reports > 1 do
    total = total - sizes[#store.reports]
    sizes[#store.reports] = nil
    table.remove(store.reports)
  end
  if total > M.MAX_BYTES then
    -- One report alone is over the cap: writing it would leave a file the next
    -- run refuses to read.
    return false, "the report is too large to store (lower plugins.max_commits)", info
  end
  local ok_enc, json = pcall(vim.json.encode, store)
  if not ok_enc then return false, "could not encode the report: " .. tostring(json), info end

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
