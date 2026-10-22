---@module 'gitsuite.features.plugins.report_ui.model'
--- The state of the report tab: which report, which view, how it is sorted,
--- what has been seen. Pure: no window, no process, no file. Every transition
--- returns a new model (the summaries are shared, they never change for a
--- report), so a renderer can be handed any model and a spec can step through
--- them.
---
--- Keys are plugin names and full commit SHAs, never line numbers: the line a
--- thing stands on is the renderer's business and is found again after every
--- render (`render.*().items`).

local summary = require("gitsuite.features.plugins.summary")

local M = {}

---Sort keys in the order `s` cycles through them.
M.SORTS = { "breaking", "name", "commits", "time" }

---@alias GitSuite.ReportUi.View
---| { kind: "overview" }
---| { kind: "digest" }
---| { kind: "detail", name: string }

---@class GitSuite.ReportUi.Model
---@field report GitSuite.Plugins.Report
---@field ctx? GitSuite.Plugins.ClassifyContext  Classifier context (`report.context()`).
---@field view GitSuite.ReportUi.View
---@field sort string           One of `M.SORTS`.
---@field show_all boolean      The unchanged plugins are listed, not counted.
---@field seen table<string, true>  `name@sha` of the commits marked as seen.
---@field heads? table<string, string>  Clone dir -> where its HEAD is now (nil: not checked).
---@field ascii? boolean        Glyphs in plain ASCII.
---@field cache table           Summaries per plugin name, shared between models of one report.

---@param report GitSuite.Plugins.Report
---@param opts? { ctx?: GitSuite.Plugins.ClassifyContext, seen?: table<string, true>, sort?: string, heads?: table<string, string>, ascii?: boolean }
---@return GitSuite.ReportUi.Model
function M.new(report, opts)
  opts = opts or {}
  report = M.unique_names(report)
  local sort = opts.sort
  if not vim.tbl_contains(M.SORTS, sort) then sort = M.SORTS[1] end
  return {
    report = report,
    ctx = opts.ctx,
    view = { kind = "overview" },
    sort = sort,
    show_all = false,
    seen = opts.seen or {},
    heads = opts.heads,
    ascii = opts.ascii,
    cache = {},
  }
end

---`report` with every entry named once: two clones of one name (a `dir`
---plugin next to an installed one) would share a summary, a detail and their
---seen marks. A later one gets its folder added (`name (dir)`); the report is
---copied only then, the common case keeps the very table.
---@param report GitSuite.Plugins.Report
---@return GitSuite.Plugins.Report
function M.unique_names(report)
  local seen, dup = {}, false
  for _, e in ipairs(report.plugins or {}) do
    if seen[e.name] then dup = true end
    seen[e.name] = true
  end
  if not dup then return report end
  local out = vim.tbl_extend("force", {}, report, { plugins = {} })
  local used = {}
  for _, e in ipairs(report.plugins) do
    local copy = e
    if used[e.name] then
      copy = vim.tbl_extend("force", {}, e, { name = ("%s (%s)"):format(e.name, tostring(e.dir)) })
    end
    used[copy.name] = true
    out.plugins[#out.plugins + 1] = copy
  end
  return out
end

---A copy of `m` with `changes` applied.
---@param m GitSuite.ReportUi.Model
---@param changes table
---@return GitSuite.ReportUi.Model
local function with(m, changes)
  return vim.tbl_extend("force", {}, m, changes)
end

---The key a seen mark is stored under.
---@param name string
---@param sha string
---@return string
function M.seen_key(name, sha)
  return name .. "@" .. sha
end

---The summary of one entry (new commits, digest, release), computed once per
---report.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return GitSuite.Plugins.Summary
function M.summary(m, entry)
  local s = m.cache[entry.name]
  if not s then
    s = summary.build(entry, summary.options(m.ctx, entry.name))
    m.cache[entry.name] = s
  end
  return s
end

---The commits an entry's range removed: everything it lists that is not new
---(a rollback, the `<` side of a diverged clone).
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return table[]
function M.removed(m, entry)
  local new = {}
  for _, c in ipairs(M.summary(m, entry).commits) do
    new[c] = true
  end
  local out = {}
  for _, c in ipairs(entry.commits or {}) do
    if not new[c] then out[#out + 1] = c end
  end
  return out
end

---Whether `sha` of plugin `name` is marked as seen.
---@param m GitSuite.ReportUi.Model
---@param name string
---@param sha string
---@return boolean
function M.is_seen(m, name, sha)
  return m.seen[M.seen_key(name, sha)] == true
end

---New commits of `entry` that are not marked as seen.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return integer
function M.unseen(m, entry)
  local n = 0
  for _, c in ipairs(M.summary(m, entry).commits) do
    if not M.is_seen(m, entry.name, c.sha) then n = n + 1 end
  end
  return n
end

---Breaking counts of an entry: `sure`, `probable`.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return integer sure
---@return integer probable
function M.breaking(m, entry)
  local d = M.summary(m, entry).digest
  return #d.sure, #d.probable
end

---The clone moved since the report: its HEAD now is not where the report
---left it. Unknown (no `heads` handed in, or no recorded head) is not moved.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return boolean
function M.moved(m, entry)
  if not m.heads or not entry.head then return false end
  local now = m.heads[entry.dir]
  return now ~= nil and now ~= entry.head
end

---@type table<string, fun(m: GitSuite.ReportUi.Model, a: GitSuite.Plugins.ReportEntry, b: GitSuite.Plugins.ReportEntry): boolean|nil>
local LESS = {
  breaking = function(m, a, b)
    local sa, pa = M.breaking(m, a)
    local sb, pb = M.breaking(m, b)
    if sa ~= sb then return sa > sb end
    if pa ~= pb then return pa > pb end
  end,
  name = function() end,
  commits = function(m, a, b)
    local ca, cb = M.summary(m, a).count, M.summary(m, b).count
    if ca ~= cb then return ca > cb end
  end,
  time = function(_, a, b)
    local ta, tb = a.time or 0, b.time or 0
    if ta ~= tb then return ta > tb end
  end,
}

---The entries the report lists (every one of them changed or could not be
---read), in the model's sort order; ties go by name.
---@param m GitSuite.ReportUi.Model
---@return GitSuite.Plugins.ReportEntry[]
function M.entries(m)
  local list = {}
  for _, e in ipairs(m.report.plugins or {}) do
    if e.status ~= "same" then list[#list + 1] = e end
  end
  local less = LESS[m.sort] or LESS.name
  table.sort(list, function(a, b)
    local r = less(m, a, b)
    if r ~= nil then return r end
    return a.name:lower() < b.name:lower()
  end)
  return list
end

---Names of the plugins the report looked at that did not change, sorted.
---@param m GitSuite.ReportUi.Model
---@return string[]
function M.unchanged(m)
  local listed = {}
  for _, e in ipairs(m.report.plugins or {}) do
    if e.status ~= "same" then listed[e.dir] = true end
  end
  local names = {}
  for dir in pairs(m.report.heads or {}) do
    if not listed[dir] then names[#names + 1] = vim.fs.basename(dir) end
  end
  table.sort(names, function(a, b)
    return a:lower() < b:lower()
  end)
  return names
end

---The entry of plugin `name`, or nil.
---@param m GitSuite.ReportUi.Model
---@param name string
---@return GitSuite.Plugins.ReportEntry|nil
function M.entry(m, name)
  for _, e in ipairs(m.report.plugins or {}) do
    if e.name == name then return e end
  end
end

---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Model
function M.next_sort(m)
  local i = 1
  for k, s in ipairs(M.SORTS) do
    if s == m.sort then i = k end
  end
  return with(m, { sort = M.SORTS[i % #M.SORTS + 1] })
end

---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Model
function M.toggle_all(m)
  return with(m, { show_all = not m.show_all })
end

---@param m GitSuite.ReportUi.Model
---@param view GitSuite.ReportUi.View
---@return GitSuite.ReportUi.Model
function M.show(m, view)
  if view.kind == "detail" and not M.entry(m, view.name) then return m end
  return with(m, { view = view })
end

---The detail of the plugin `delta` places after (or before) the one shown,
---in the overview's order, wrapping. Outside a detail view: unchanged.
---@param m GitSuite.ReportUi.Model
---@param delta integer
---@return GitSuite.ReportUi.Model
function M.step_plugin(m, delta)
  if m.view.kind ~= "detail" then return m end
  local list = M.entries(m)
  if #list == 0 then return m end
  local at
  for i, e in ipairs(list) do
    if e.name == m.view.name then at = i end
  end
  -- (the plugin shown is not in the list any more: start at either end)
  local next_i = at and ((at - 1 + delta) % #list + 1) or (delta > 0 and 1 or #list)
  return with(m, { view = { kind = "detail", name = list[next_i].name } })
end

---Mark (or, with `seen = false`, unmark) commits as seen. `keys` are
---`{ name, sha }` pairs.
---@param m GitSuite.ReportUi.Model
---@param keys { name: string, sha: string }[]
---@param seen? boolean default true
---@return GitSuite.ReportUi.Model
function M.mark(m, keys, seen)
  local set = vim.tbl_extend("force", {}, m.seen)
  for _, k in ipairs(keys) do
    set[M.seen_key(k.name, k.sha)] = (seen ~= false) or nil
  end
  return with(m, { seen = set })
end

---The `{ name, sha }` pairs of every new commit of `entry`.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return { name: string, sha: string }[]
function M.commit_keys(m, entry)
  local out = {}
  for _, c in ipairs(M.summary(m, entry).commits) do
    out[#out + 1] = { name = entry.name, sha = c.sha }
  end
  return out
end

return M
