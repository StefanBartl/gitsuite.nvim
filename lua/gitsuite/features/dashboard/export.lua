---@module 'gitsuite.features.dashboard.export'
---@brief The reports the dashboard's `E` key can export, and their text.
---@description
--- `E` asks what to export, then where to. This module is the "what": it sorts
--- the dashboard's records into reports (all with their status, the dirty ones,
--- the ones behind, ...) and renders one of them as lines. The "where" (clipboard,
--- new buffer, file) lives in the view.
---
---   Dashboard: 3 of 9 repositories behind
---
---   alpha   main   behind   3 behind
---   beta    main   behind   1 behind
---
--- No buffers, windows or git: the wording is tested without a dashboard.
--- Placeholders of a scan still running (`unscanned`) have no state yet and
--- are left out of every report.

---@class GitSuiteDashboardExport
local M = {}

---One exportable report.
---@class GitSuiteDashboardExportReport
---@field id string "all"|"attention"|"dirty"|"behind"|"ahead"|"diverged"
---@field title string What the report lists, for the heading ("behind")
---@field label string Choice label with the count ("Behind (3)")
---@field indices integer[] Indices into the records the report holds

---Report ids in the order they are offered, with their label and heading text.
---`match` decides membership of a scanned record.
---@type { id: string, label: string, title: string, match: fun(r: RepoDashboardRecord): boolean }[]
local DEFS = {
  {
    id = "all",
    label = "All with status",
    title = "all",
    match = function()
      return true
    end,
  },
  {
    id = "attention",
    label = "Needs attention (not clean)",
    title = "not clean",
    match = function(r)
      return r.state ~= "clean"
    end,
  },
  {
    id = "dirty",
    label = "Dirty",
    title = "dirty",
    match = function(r)
      return (r.dirty or 0) > 0
    end,
  },
  {
    id = "behind",
    label = "Behind",
    title = "behind",
    match = function(r)
      return (r.behind or 0) > 0
    end,
  },
  {
    id = "ahead",
    label = "Ahead",
    title = "ahead",
    match = function(r)
      return (r.ahead or 0) > 0
    end,
  },
  {
    id = "diverged",
    label = "Diverged",
    title = "diverged",
    match = function(r)
      return r.state == "diverged"
    end,
  },
}

---The records a report can hold: everything a scan has read.
---@param r RepoDashboardRecord
---@return boolean
local function scanned(r)
  return not r.unscanned
end

---Compact age of a commit ("3h", "2d", "5mo"), "-" for a repository without commits.
---@param ts integer|nil
---@param now integer
---@return string
local function age(ts, now)
  if not ts then return "-" end
  local diff = math.max(now - ts, 0)
  if diff < 60 then return "now" end
  if diff < 3600 then return ("%dm"):format(math.floor(diff / 60)) end
  if diff < 86400 then return ("%dh"):format(math.floor(diff / 3600)) end
  if diff < 604800 then return ("%dd"):format(math.floor(diff / 86400)) end
  if diff < 2592000 then return ("%dw"):format(math.floor(diff / 604800)) end
  if diff < 31536000 then return ("%dmo"):format(math.floor(diff / 2592000)) end
  return ("%dy"):format(math.floor(diff / 31536000))
end

---The detail cell of a row: what makes it belong to `id`.
---@param id string
---@param r RepoDashboardRecord
---@return string
local function detail(id, r)
  if id == "behind" then return ("%d behind"):format(r.behind or 0) end
  if id == "ahead" then return ("%d ahead"):format(r.ahead or 0) end
  if id == "dirty" then return ("%d changed"):format(r.dirty or 0) end
  ---@type string[]
  local parts = {}
  if (r.ahead or 0) > 0 then parts[#parts + 1] = ("%d ahead"):format(r.ahead) end
  if (r.behind or 0) > 0 then parts[#parts + 1] = ("%d behind"):format(r.behind) end
  if (r.dirty or 0) > 0 then parts[#parts + 1] = ("%d changed"):format(r.dirty) end
  return table.concat(parts, ", ")
end

---The reports `records` offers, each with the indices it holds.
---@param records RepoDashboardRecord[]
---@return GitSuiteDashboardExportReport[]
function M.reports(records)
  ---@type GitSuiteDashboardExportReport[]
  local out = {}
  for _, def in ipairs(DEFS) do
    ---@type integer[]
    local indices = {}
    for i, r in ipairs(records) do
      if scanned(r) and def.match(r) then indices[#indices + 1] = i end
    end
    out[#out + 1] = {
      id = def.id,
      title = def.title,
      label = ("%s (%d)"):format(def.label, #indices),
      indices = indices,
    }
  end
  return out
end

---Renders report `id` as lines; `nil` when the id is unknown.
---@param id string
---@param records RepoDashboardRecord[]
---@param now? integer Current time for the age column; default `os.time()`
---@return string[]|nil lines
---@return integer|nil count Repositories listed
function M.build(id, records, now)
  now = now or os.time()
  local report
  for _, rep in ipairs(M.reports(records)) do
    if rep.id == id then report = rep end
  end
  if not report then return nil end

  local total = 0
  for _, r in ipairs(records) do
    if scanned(r) then total = total + 1 end
  end

  ---@type string[][]
  local rows = {}
  local widths = { 0, 0, 0 }
  for _, i in ipairs(report.indices) do
    local r = records[i]
    local row = { r.name, r.branch or "-", r.state, detail(id, r), age(r.last_commit, now) }
    for c = 1, 3 do
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(row[c]))
    end
    rows[#rows + 1] = row
  end

  local function pad(text, width)
    return text .. (" "):rep(width - vim.fn.strdisplaywidth(text))
  end

  ---@type string[]
  local lines = {
    ("Dashboard: %d of %d repositories (%s)"):format(#rows, total, report.title),
    "",
  }
  for _, row in ipairs(rows) do
    local line = ("%s  %s  %s"):format(
      pad(row[1], widths[1]),
      pad(row[2], widths[2]),
      pad(row[3], widths[3])
    )
    if row[4] ~= "" then line = line .. "  " .. row[4] end
    lines[#lines + 1] = ("%s  %s"):format(line, row[5])
  end
  return lines, #rows
end

return M
