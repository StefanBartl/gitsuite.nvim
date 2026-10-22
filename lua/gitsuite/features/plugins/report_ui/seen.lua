---@module 'gitsuite.features.plugins.report_ui.seen'
--- Which commits of the report were marked as seen: `plugins_seen.json` below
--- `stdpath("state")/gitsuite/`, one entry per `name@sha` with the time it was
--- marked. A file of its own, not part of the report store: marks outlive the
--- reports they were made in (a new range of the same plugin shows only its new
--- commits as unseen).
---
--- Two editors may mark at the same time, so the file is read fresh before every
--- write and the change is merged into what is there, never written over it.
--- Writes are atomic. A file that cannot be read is moved aside (`.corrupt`),
--- never overwritten; one from a newer gitsuite is left alone (read only).
--- Marks older than `plugins.seen_ttl_days` are dropped on the next write.

local atomic = require("lib.nvim.fs.write.atomic")

local M = {}

---Format version of the file.
M.VERSION = 1

---Largest file read (about 30 000 marks).
M.MAX_BYTES = 4 * 1024 * 1024

---Latest plausible time of a mark (year 2100).
local MAX_TIME = 4102444800

---@return string
function M.path()
  return vim.fn.stdpath("state") .. "/gitsuite/plugins_seen.json"
end

---@param path string
---@return string|nil text  nil: there is no file
---@return string|nil err
local function read(path)
  local st = vim.uv.fs_stat(path)
  if not st then return nil, nil end
  if st.type ~= "file" then return nil, "not a regular file" end
  if st.size > M.MAX_BYTES then return nil, "too large" end
  local f = io.open(path, "rb")
  if not f then return nil, "cannot be opened" end
  local text = f:read("*a")
  f:close()
  return text or "", nil
end

---A mark key as stored: a plugin name (no `@`, no control characters) and a
---full or abbreviated hex SHA.
---@param k any
---@return boolean
local function valid_key(k)
  if type(k) ~= "string" or #k > 300 then return false end
  -- (the SHA is after the LAST `@`: a plugin folder may hold one)
  local name, sha = k:match("^(.+)@(%x+)$")
  return name ~= nil and not name:find("%c") and #sha >= 7 and #sha <= 64
end

---@class GitSuite.ReportUi.SeenInfo
---@field error? string    The file could not be used (it is left where it is until a write moves it aside).
---@field unreadable? boolean  It could not even be read (not its content): a write leaves it alone.
---@field newer? boolean   Written by a newer gitsuite: read only.

---Read the marks: `name@sha -> time`. Entries that are no mark are skipped.
---@param path? string
---@return table<string, integer> marks
---@return GitSuite.ReportUi.SeenInfo info
function M.load(path)
  path = path or M.path()
  local text, err = read(path)
  if err then return {}, { error = err, unreadable = true } end
  if not text then return {}, {} end
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.seen) ~= "table" then
    return {}, { error = "not a seen-marks file" }
  end
  local info = {}
  if type(data.version) == "number" and data.version > M.VERSION then info.newer = true end
  local marks = {}
  for k, t in pairs(data.seen) do
    if valid_key(k) and type(t) == "number" and t > 0 and t <= MAX_TIME then
      marks[k] = math.floor(t)
    end
  end
  return marks, info
end

---The marks as a set, for the model.
---@param marks table<string, integer>
---@return table<string, true>
function M.set(marks)
  local out = {}
  for k in pairs(marks) do
    out[k] = true
  end
  return out
end

---Drop marks older than `ttl_days`.
---@param marks table<string, integer>
---@param ttl_days integer
---@param now integer
---@return table<string, integer>
function M.prune(marks, ttl_days, now)
  local cutoff = now - ttl_days * 86400
  local out = {}
  for k, t in pairs(marks) do
    if t >= cutoff then out[k] = t end
  end
  return out
end

---Merge `changes` into the file: `key -> true` marks, `key -> false` unmarks.
---Reads the file fresh first, so marks another editor wrote meanwhile stay.
---@param changes table<string, boolean>
---@param opts? { path?: string, ttl_days?: integer, now?: integer }
---@return table<string, integer>|nil marks  What the file holds now; nil when it was not written.
---@return string|nil err
function M.update(changes, opts)
  opts = opts or {}
  local path = opts.path or M.path()
  local now = opts.now or os.time()
  local ttl = opts.ttl_days or require("gitsuite.config").get().plugins.seen_ttl_days

  local marks, info = M.load(path)
  if info.newer then
    return nil, "the seen marks were written by a newer gitsuite (left as they are)"
  end
  if info.unreadable then
    return nil, ("the seen marks cannot be read (%s); left as they are"):format(info.error)
  end
  if info.error then
    -- Kept, not overwritten: whatever it was, it goes aside before a fresh file.
    local target = path .. ".corrupt"
    local n = 0
    while vim.uv.fs_stat(target) do
      n = n + 1
      target = ("%s.corrupt.%d.%d"):format(path, now, n)
    end
    if not vim.uv.fs_rename(path, target) then
      return nil,
        ("the seen marks cannot be read (%s) and could not be moved aside"):format(info.error)
    end
  end

  for k, on in pairs(changes) do
    if valid_key(k) then marks[k] = on and now or nil end
  end
  marks = M.prune(marks, ttl, now)

  local ok_enc, json = pcall(vim.json.encode, { version = M.VERSION, seen = marks })
  if not ok_enc then return nil, "could not encode the seen marks" end
  local ok, err = atomic(path, json, { mkdirp = true })
  if not ok then return nil, "could not write the seen marks: " .. tostring(err) end
  return marks, nil
end

return M
