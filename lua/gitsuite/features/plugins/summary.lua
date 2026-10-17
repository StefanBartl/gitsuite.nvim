---@module 'gitsuite.features.plugins.summary'
--- What one plugin's update amounts to, without AI: counts per conventional
--- type, the busiest scopes, who committed (and how much of it bots), the
--- releases in the range, what the breaking classifier found, which directories
--- changed and whether a major version was crossed -- and that as Markdown.
---
--- Pure and deterministic: a report entry and options in, a table (and lines)
--- out; equal input gives equal output, ties are broken by name. Every text that
--- came from the plugin's repository goes through `text` before it is printed.

local breaking = require("gitsuite.features.plugins.breaking")
local semver = require("gitsuite.features.plugins.semver")
local text = require("gitsuite.features.plugins.text")

local M = {}

---The line every breaking section starts with: the classifier is a heuristic,
---and silence proves nothing.
M.HEURISTIC_NOTE =
  "Breaking detection is a heuristic over commit messages: it finds about half of what a person calls breaking. 0 hits does not mean no breaking changes."

---How many entries the "top" lists keep.
M.TOP = 5

---Authors that are bots: the name says so.
---@param name string
---@return boolean
local function is_bot(name)
  local n = name:lower()
  return n:find("%[bot%]") ~= nil
    or n:find("dependabot", 1, true) ~= nil
    or n:find("renovate", 1, true) ~= nil
    or n:find("github%-actions") ~= nil
    or n:match("^bot$") ~= nil
    or n:match("%f[%w]bot$") ~= nil
end

---Count `key(item)` over `items` and return the `top` most frequent, ties by name.
---@param counts table<string, integer>
---@param top? integer
---@return { name: string, count: integer }[]
local function ranked(counts, top)
  local list = {}
  for name, count in pairs(counts) do
    list[#list + 1] = { name = name, count = count }
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  if top and #list > top then
    for i = #list, top + 1, -1 do
      list[i] = nil
    end
  end
  return list
end

---The commits of an entry that are new in the state it reports on: everything
---of a forward update, the `>` side of a diverged one, nothing of a rollback.
---@param entry table
---@return table[]
function M.new_commits(entry)
  local out = {}
  if entry.status ~= "forward" and entry.status ~= "diverged" then return out end
  for _, c in ipairs(entry.commits or {}) do
    if entry.status == "forward" or c.side == ">" then out[#out + 1] = c end
  end
  return out
end

---Stable release tags (no pre-release), highest version first.
---@param tags any
---@return { name: string, subject?: string, time?: integer, version: table }[]
local function releases(tags)
  local out = {}
  for _, t in ipairs(type(tags) == "table" and tags or {}) do
    local v = type(t) == "table" and semver.version(t.name) or nil
    if v and not v.prerelease then
      out[#out + 1] = { name = t.name, subject = t.subject, time = t.time, version = v }
    end
  end
  table.sort(out, function(a, b)
    if semver.eq(a.version, b.version) then return a.name < b.name end
    return semver.lt(b.version, a.version)
  end)
  return out
end

---@class GitSuite.Plugins.Release
---@field kind "major"|"minor"|"patch"|"first"|"none"
---@field from? string   Highest release before the update.
---@field to? string     Highest release in the update.
---@field count integer  Stable releases in the update.

---What the releases in an update say: a major jump, a minor or patch release,
---the first release, or none (then `from` is the last one before).
---@param tags? { range?: table[], before?: table[] }
---@return GitSuite.Plugins.Release|nil  nil when no tags were read.
function M.release(tags)
  if type(tags) ~= "table" then return nil end
  local inside, before = releases(tags.range), releases(tags.before)
  local last = before[1]
  local newest = inside[1]
  if not newest then return { kind = "none", from = last and last.name or nil, count = 0 } end
  local r = { to = newest.name, from = last and last.name or nil, count = #inside }
  if not last then
    r.kind = "first"
  elseif newest.version[1] > last.version[1] then
    r.kind = "major"
  elseif newest.version[2] > last.version[2] then
    r.kind = "minor"
  else
    r.kind = "patch"
  end
  return r
end

---@class GitSuite.Plugins.SummaryOpts: GitSuite.Plugins.BreakingOpts
---@field style? "none"|"conventional"  Per-plugin override of the convention check.

---@class GitSuite.Plugins.Summary
---@field commits table[]          The new commits, newest first.
---@field count integer
---@field first? integer           Oldest committer time.
---@field last? integer            Newest committer time.
---@field types { name: string, count: integer }[]   Every type, most frequent first ("other" = not conventional).
---@field scopes { name: string, count: integer }[]  Top scopes.
---@field authors { name: string, count: integer }[] Top authors.
---@field bots integer             Commits by bots.
---@field dirs { name: string, count: integer }[]    Top changed directories (when known).
---@field release? GitSuite.Plugins.Release
---@field tags { name: string, subject?: string, time?: integer }[]  Stable releases in the update, highest first.
---@field digest GitSuite.Plugins.Digest
---@field convention { conventional: integer, total: integer, recognized: boolean|nil, declared?: string }
---@field complete boolean         The commit list is the whole update (positions are exact).

---The classifier options for one plugin, from the context a report is shown in
---(`report.context()`): the global `plugins.breaking` settings merged with the
---plugin's own entry in `plugins.breaking.plugins`.
---@param ctx? GitSuite.Plugins.ClassifyContext
---@param name string
---@return GitSuite.Plugins.SummaryOpts
function M.options(ctx, name)
  ctx = ctx or {}
  local cfg = type(ctx.breaking) == "table" and ctx.breaking or {}
  local own = type(cfg.plugins) == "table" and cfg.plugins[name] or nil
  own = type(own) == "table" and own or {}
  local ignore = {}
  vim.list_extend(ignore, type(cfg.ignore) == "table" and cfg.ignore or {})
  vim.list_extend(ignore, type(own.ignore) == "table" and own.ignore or {})
  return {
    ignore = ignore,
    force = type(own.force) == "table" and own.force or nil,
    style = own.style,
    collapse_repeats = cfg.collapse_repeats,
    parsers = ctx.parsers,
    parser_plugin = type(name) == "string" and name:lower():find("treesitter", 1, true) ~= nil,
    nvim = ctx.nvim,
  }
end

---Summarize one report entry.
---@param entry table  A `GitSuite.Plugins.ReportEntry`, possibly read back from the store.
---@param opts? GitSuite.Plugins.SummaryOpts
---@return GitSuite.Plugins.Summary
function M.build(entry, opts)
  opts = opts or {}
  local commits = M.new_commits(entry)
  local complete = entry.order == "topo" and entry.status == "forward" and not entry.truncated
  local dopts = vim.tbl_extend("force", {}, opts, { positions = complete })
  local digest = breaking.digest(commits, dopts)

  local types, scopes, authors, dirs = {}, {}, {}, {}
  local bots = 0
  local first, last
  for _, c in ipairs(commits) do
    local subject = type(c.subject) == "string" and c.subject or ""
    local t = breaking.type_of(subject) or "other"
    types[t] = (types[t] or 0) + 1
    for _, s in ipairs(breaking.scopes(subject) or {}) do
      local key = s:lower()
      scopes[key] = (scopes[key] or 0) + 1
    end
    local author = type(c.author) == "string" and c.author or ""
    if author ~= "" then authors[author] = (authors[author] or 0) + 1 end
    if is_bot(author) or t == "bot" then bots = bots + 1 end
    for _, d in ipairs(type(c.dirs) == "table" and c.dirs or {}) do
      if type(d) == "string" then dirs[d] = (dirs[d] or 0) + 1 end
    end
    if type(c.time) == "number" then
      first = first and math.min(first, c.time) or c.time
      last = last and math.max(last, c.time) or c.time
    end
  end

  local convention = type(entry.convention) == "table"
      and {
        conventional = tonumber(entry.convention.conventional) or 0,
        total = tonumber(entry.convention.total) or 0,
      }
    or nil
  if convention then
    if convention.total >= breaking.CONVENTION_MIN then
      convention.recognized = convention.conventional / convention.total
        >= breaking.CONVENTION_SHARE
    end
  else
    convention = breaking.convention(vim.tbl_map(function(c)
      return c.subject
    end, commits))
  end
  if opts.style == "none" or opts.style == "conventional" then
    convention.declared = opts.style
    convention.recognized = opts.style == "conventional"
  end

  local release = M.release(entry.tags)
  local tags = {}
  for _, r in ipairs(releases(type(entry.tags) == "table" and entry.tags.range or nil)) do
    tags[#tags + 1] = { name = r.name, subject = r.subject, time = r.time }
  end

  return {
    commits = commits,
    count = #commits,
    first = first,
    last = last,
    types = ranked(types),
    scopes = ranked(scopes, M.TOP),
    authors = ranked(authors, M.TOP),
    bots = bots,
    dirs = ranked(dirs, M.TOP + 3),
    release = release,
    tags = tags,
    digest = digest,
    convention = convention,
    complete = complete,
  }
end

-- Markdown --------------------------------------------------------------------

---@param s any
---@return string
local function esc(s)
  return (text.one_line(s):gsub("[\\`<>%[%]|*_]", "\\%0"))
end

---@param s any
---@return string
local function code(s)
  return (text.one_line(s):gsub("`", "'"))
end

---@param t any
---@return string
local function day(t)
  return type(t) == "number" and os.date("%Y-%m-%d", t) --[[@as string]] or "?"
end

---@param list { name: string, count: integer }[]
---@return string
local function counts(list)
  local parts = {}
  for _, item in ipairs(list) do
    parts[#parts + 1] = ("%s %d"):format(esc(item.name), item.count)
  end
  return table.concat(parts, " · ")
end

---@param s GitSuite.Plugins.Summary
---@param i integer
---@return string
local function position(s, i)
  local p = s.digest.positions and s.digest.positions[i]
  return p and ("%d/%d"):format(p, s.digest.total) or ("?/%d"):format(s.digest.total)
end

---@param s GitSuite.Plugins.Summary
---@param i integer
---@return string
local function commit_line(s, i)
  local c = s.commits[i]
  local v = s.digest.verdicts[i]
  local line = ("- `%s` %s %s — %s"):format(
    code((tostring(c.sha or "?")):sub(1, 8)),
    position(s, i),
    day(c.time),
    esc(c.subject)
  )
  if v.relevance then line = line .. (" _(%s)_"):format(esc(v.relevance.reason)) end
  return line
end

---Indexes in the order a reader wants: oldest first when the positions are
---known (the order they were applied in), else as listed.
---@param s GitSuite.Plugins.Summary
---@param list integer[]
---@return integer[]
local function in_order(s, list)
  local out = vim.list_extend({}, list)
  if s.digest.positions then
    table.sort(out, function(a, b)
      return s.digest.positions[a] < s.digest.positions[b]
    end)
  end
  return out
end

---The release line: "MAJOR v1.9.1 → v2.0.0", "release v1.2.0 → v1.3.0", or
---"no release tag in this update (last v0.9.3)".
---@param r GitSuite.Plugins.Release
---@return string
function M.release_line(r)
  if r.kind == "none" then
    return r.from and ("no release tag in this update (last %s)"):format(code(r.from))
      or "no release tag in this update (none before either)"
  end
  if r.kind == "first" then return ("first release %s"):format(code(r.to)) end
  local word = r.kind == "major" and "MAJOR" or r.kind
  return ("%s %s → %s"):format(word, code(r.from), code(r.to))
    .. (r.count > 1 and (" (%d releases)"):format(r.count) or "")
end

---The summary of one plugin as Markdown lines (no heading of its own).
---@param s GitSuite.Plugins.Summary
---@param opts? { top_hints?: integer }
---@return string[]
function M.markdown(s, opts)
  opts = opts or {}
  local lines = {}
  local function add(l)
    lines[#lines + 1] = l
  end
  local d = s.digest

  if s.count == 0 then return lines end
  add(
    ("**Summary:** %d commit%s, %s – %s"):format(
      s.count,
      s.count == 1 and "" or "s",
      day(s.first),
      day(s.last)
    )
  )
  add("")
  add("- Types: " .. counts(s.types))
  if #s.scopes > 0 then add("- Top scopes: " .. counts(s.scopes)) end
  if #s.authors > 0 then
    add(
      ("- Authors: %s%s"):format(
        counts(s.authors),
        s.bots > 0 and (" (bots: %d of %d commits)"):format(s.bots, s.count) or ""
      )
    )
  end
  if #s.dirs > 0 then add("- Changed directories: " .. counts(s.dirs)) end
  if s.release then
    add("- Releases: " .. M.release_line(s.release))
    for _, t in ipairs(s.tags) do
      add(
        ("  - `%s` %s%s"):format(
          code(t.name),
          day(t.time),
          (t.subject and t.subject ~= "") and (" — " .. esc(t.subject)) or ""
        )
      )
    end
  end
  if s.convention.recognized == false then
    add(
      ("- No marker convention recognized (%d of %d subjects are conventional commits): the classifier sees little here."):format(
        s.convention.conventional,
        s.convention.total
      ) .. (s.convention.declared and " (set in `plugins.breaking.plugins`)" or "")
    )
  end
  add("")

  add("> " .. M.HEURISTIC_NOTE)
  add("")
  if #d.sure > 0 then
    add(("**Breaking (%d)**"):format(#d.sure))
    add("")
    for _, i in ipairs(in_order(s, d.sure)) do
      add(commit_line(s, i))
    end
    add("")
  end
  if #d.probable > 0 then
    add(("**Probably breaking (%d)**"):format(#d.probable))
    add("")
    for _, i in ipairs(in_order(s, d.probable)) do
      add(commit_line(s, i))
    end
    add("")
  end
  if #d.hints > 0 then
    local top = math.min(#d.hints, opts.top_hints or breaking.TOP_HINTS)
    add(("<details><summary>Hints (%d, top %d by score)</summary>"):format(#d.hints, top))
    add("")
    for k = 1, #d.hints do
      local i = d.hints[k]
      add(commit_line(s, i) .. (" · score %d"):format(d.verdicts[i].score))
      if k == top and #d.hints > top then
        add(("- … %d more with a lower score"):format(#d.hints - top))
        break
      end
    end
    add("")
    add("</details>")
    add("")
  end
  for _, g in ipairs(d.groups) do
    local what = g.kind == "parsers" and "parser updates" or "repeated subject"
    local extra = ""
    if g.kind == "parsers" and g.installed then
      extra = #g.installed > 0 and (" · installed: " .. esc(table.concat(g.installed, ", ")))
        or " · none of them installed"
    end
    add(
      ("<details><summary>~ %d × %s (%s%s%s)</summary>"):format(
        #g.members,
        esc(g.label),
        what,
        g.breaking > 0 and (", %d marked breaking"):format(g.breaking) or "",
        extra
      )
    )
    add("")
    for _, i in ipairs(in_order(s, g.members)) do
      add(commit_line(s, i))
    end
    add("")
    add("</details>")
    add("")
  end
  if #d.sure == 0 and #d.probable == 0 then
    add("No commit is marked breaking (see the note above).")
    add("")
  end
  return lines
end

return M
