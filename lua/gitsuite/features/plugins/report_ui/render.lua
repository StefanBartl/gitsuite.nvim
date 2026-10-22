---@module 'gitsuite.features.plugins.report_ui.render'
--- The views of the report tab as text: a model in, `{ lines, marks, items }`
--- out. Pure -- no buffer, no window, no process -- so every view is tested
--- against a fixture report.
---
---   * `lines`  the buffer text; the first line is always a summary of the view;
---   * `marks`  highlights, `{ line, col, end_col, hl }` (0-based line, byte
---              columns), applied by the window as extmarks;
---   * `items`  what a line stands for, by key (`{ kind, name?, sha? }`), indexed
---              by 1-based line number. Built anew on every render: nothing may
---              hold on to a line number across renders.
---
--- A state is always a glyph AND a word ("! breaking"), never colour alone; the
--- glyphs have an ASCII fallback (`model.ascii`). Commit text comes from other
--- people's repositories and goes through `text` before it is printed.

local model = require("gitsuite.features.plugins.report_ui.model")
local text = require("gitsuite.features.plugins.text")

local M = {}

---Glyphs: `[1]` Unicode, `[2]` ASCII.
local GLYPH = {
  breaking = { "!", "!" },
  forward = { "↑", "^" },
  rollback = { "↓", "v" },
  diverged = { "⇅", "~" },
  new = { "+", "+" },
  pinned = { "·", "." },
  error = { "✗", "x" },
  other = { "?", "?" },
  moved = { "↻", "@" },
  unseen = { "•", "*" },
  seen = { " ", " " },
}

---@param m GitSuite.ReportUi.Model
---@param key string
---@return string
local function glyph(m, key)
  return GLYPH[key][m.ascii and 2 or 1]
end

---@class GitSuite.ReportUi.Item
---@field kind "summary"|"plugin"|"commit"|"group"|"unchanged"|"section"|"blank"
---@field name? string
---@field sha? string

---@class GitSuite.ReportUi.Mark
---@field line integer     0-based
---@field col integer      byte column, 0-based
---@field end_col integer  exclusive
---@field hl string

---@class GitSuite.ReportUi.Rendered
---@field lines string[]
---@field marks GitSuite.ReportUi.Mark[]
---@field items table<integer, GitSuite.ReportUi.Item>

---A builder: lines with their item and highlighted spans.
local function builder()
  local r = { lines = {}, marks = {}, items = {} }
  ---Append a line made of `parts` (`{ text, hl? }` or a plain string).
  ---@param item GitSuite.ReportUi.Item|nil
  ---@param parts (string|{ [1]: string, [2]: string|nil })[]
  function r.add(item, parts)
    local row = #r.lines
    local buf, col = {}, 0
    for _, p in ipairs(parts) do
      local s, hl = p, nil
      if type(p) == "table" then
        s, hl = p[1], p[2]
      end
      buf[#buf + 1] = s
      if hl and #s > 0 then
        r.marks[#r.marks + 1] = { line = row, col = col, end_col = col + #s, hl = hl }
      end
      col = col + #s
    end
    -- A part left empty (no count after a range) must not leave trailing blanks.
    r.lines[row + 1] = (table.concat(buf):gsub("%s+$", ""))
    r.items[row + 1] = item or { kind = "blank" }
  end
  function r.blank()
    r.add(nil, { "" })
  end
  return r
end

---@param s string
---@param width integer
---@return string
local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w >= width then return s end
  return s .. string.rep(" ", width - w)
end

---@param sha any
---@return string
local function short(sha)
  return type(sha) == "string" and sha:sub(1, 7) or "?"
end

---@param t any
---@return string
local function day(t)
  return type(t) == "number" and os.date("%Y-%m-%d", t) or "?"
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---`from..to`, the target's tag or branch after it.
---@param entry GitSuite.Plugins.ReportEntry
---@return string
local function range(entry)
  if not entry.from and not entry.to then return "" end
  -- A fresh install has no "from": only where it landed.
  local s = entry.from and ("%s..%s"):format(short(entry.from), short(entry.to)) or short(entry.to)
  if type(entry.to_label) == "string" and entry.to_label ~= "" then
    s = s .. " (" .. text.one_line(entry.to_label) .. ")"
  end
  return s
end

---Glyph, word and highlight of an entry's state; breaking wins over the
---direction, an error over everything.
---@param m GitSuite.ReportUi.Model
---@param entry GitSuite.Plugins.ReportEntry
---@return string glyph
---@return string word
---@return string hl
local function state_of(m, entry)
  local st = entry.status
  if st == "error" or st == "no_git" then
    return glyph(m, "error"), st == "no_git" and "no clone" or "error", "GitSuitePluginsError"
  end
  local sure, probable = model.breaking(m, entry)
  if sure > 0 then return glyph(m, "breaking"), "breaking", "GitSuitePluginsBreaking" end
  if probable > 0 then return glyph(m, "breaking"), "maybe", "GitSuitePluginsProbable" end
  local pending = m.report.mode == "pending"
  if st == "forward" then
    return glyph(m, "forward"), pending and "available" or "updated", "GitSuitePluginsForward"
  end
  if st == "rollback" then return glyph(m, "rollback"), "rollback", "GitSuitePluginsRollback" end
  if st == "diverged" then return glyph(m, "diverged"), "diverged", "GitSuitePluginsRollback" end
  if st == "new" then return glyph(m, "new"), "new", "GitSuitePluginsForward" end
  if st == "pinned" then return glyph(m, "pinned"), "pinned", "GitSuitePluginsDim" end
  return glyph(m, "other"), text.one_line(st or "unknown"), "GitSuitePluginsDim"
end

---The first line of every view.
---@param m GitSuite.ReportUi.Model
---@param r table builder
---@param what string
local function summary_line(m, r, what)
  local rep = m.report
  local changed, commits, breaking, unseen = 0, 0, 0, 0
  for _, e in ipairs(model.entries(m)) do
    changed = changed + 1
    commits = commits + model.summary(m, e).count
    breaking = breaking + (model.breaking(m, e))
    unseen = unseen + model.unseen(m, e)
  end
  local parts = {
    ("plugins %s · %s · %s"):format(
      rep.mode or "?",
      type(rep.at) == "number" and os.date("%Y-%m-%d %H:%M", rep.at) or "?",
      what
    ),
    (" · %s changed, %s"):format(changed, plural(commits, "commit")),
  }
  if breaking > 0 then parts[#parts + 1] = (", %d breaking"):format(breaking) end
  if unseen > 0 then parts[#parts + 1] = (", %d unseen"):format(unseen) end
  r.add({ kind = "summary" }, { { table.concat(parts), "GitSuitePluginsHeader" } })
end

---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Rendered
function M.render_overview(m)
  local r = builder()
  summary_line(m, r, "overview")
  r.blank()

  local entries = model.entries(m)
  if #entries == 0 then
    r.add({ kind = "blank" }, { { "No plugin changed since the last sync", "GitSuitePluginsDim" } })
  end

  local width = 0
  for _, e in ipairs(entries) do
    width = math.max(width, vim.fn.strdisplaywidth(text.one_line(e.name)))
  end
  for _, e in ipairs(entries) do
    local g, word, hl = state_of(m, e)
    local s = model.summary(m, e)
    local parts = {
      { g .. " " .. pad(word, 9), hl },
      " ",
      { pad(text.one_line(e.name), width), "GitSuitePluginsName" },
      "  ",
    }
    if e.status == "error" or e.status == "no_git" then
      parts[#parts + 1] = { text.one_line(e.reason or "could not be read"), "GitSuitePluginsError" }
    else
      local rg = range(e)
      if rg ~= "" then
        parts[#parts + 1] = { rg, "GitSuitePluginsSha" }
        parts[#parts + 1] = "  "
      end
      local removed = #model.removed(m, e)
      if s.count > 0 then parts[#parts + 1] = plural(s.count, "commit") end
      if removed > 0 then
        parts[#parts + 1] = (s.count > 0 and ", " or "") .. ("%d removed"):format(removed)
      end
      local unseen = model.unseen(m, e)
      if unseen > 0 then
        parts[#parts + 1] = ", "
        parts[#parts + 1] =
          { ("%s %d unseen"):format(glyph(m, "unseen"), unseen), "GitSuitePluginsUnseen" }
      end
    end
    if model.moved(m, e) then
      parts[#parts + 1] = "  "
      parts[#parts + 1] = { glyph(m, "moved") .. " moved since the report", "GitSuitePluginsStale" }
    end
    r.add({ kind = "plugin", name = e.name }, parts)
  end

  local unchanged = model.unchanged(m)
  if #unchanged > 0 then
    r.blank()
    if m.show_all then
      r.add(
        { kind = "section" },
        { { ("%d unchanged"):format(#unchanged), "GitSuitePluginsSection" } }
      )
      for _, name in ipairs(unchanged) do
        r.add(
          { kind = "unchanged", name = name },
          { "  ", { text.one_line(name), "GitSuitePluginsDim" } }
        )
      end
    else
      r.add(
        { kind = "unchanged" },
        { { ("%d unchanged (A lists them)"):format(#unchanged), "GitSuitePluginsDim" } }
      )
    end
  end
  return r
end

---One commit row: seen glyph, short SHA, subject; `with_name` puts the
---plugin's name in front (the digest is flat over all plugins).
---@param m GitSuite.ReportUi.Model
---@param r table builder
---@param name string
---@param c table commit
---@param opts { indent?: string, name_width?: integer, tag?: string, removed?: boolean }
local function commit_row(m, r, name, c, opts)
  -- A removed commit is not something new to read: it carries no seen state.
  local seen = opts.removed or model.is_seen(m, name, c.sha)
  local parts = { opts.indent or "  " }
  parts[#parts + 1] = seen and glyph(m, "seen") or { glyph(m, "unseen"), "GitSuitePluginsUnseen" }
  parts[#parts + 1] = " "
  if opts.name_width then
    parts[#parts + 1] = { pad(text.one_line(name), opts.name_width), "GitSuitePluginsName" }
    parts[#parts + 1] = "  "
  end
  parts[#parts + 1] = { short(c.sha), "GitSuitePluginsSha" }
  parts[#parts + 1] = " "
  if opts.tag then
    parts[#parts + 1] = { opts.tag, "GitSuitePluginsBreaking" }
    parts[#parts + 1] = " "
  end
  parts[#parts + 1] = text.one_line(c.subject or "")
  r.add({ kind = "commit", name = name, sha = c.sha }, parts)
end

---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Rendered
function M.render_digest(m)
  local r = builder()
  summary_line(m, r, "breaking digest")

  local tiers = {
    { key = "sure", title = "BREAKING" },
    { key = "probable", title = "PROBABLY BREAKING" },
    { key = "hints", title = "HINTS" },
  }
  local rows = { sure = {}, probable = {}, hints = {} }
  local width = 0
  for _, e in ipairs(model.entries(m)) do
    local s = model.summary(m, e)
    for _, t in ipairs(tiers) do
      for _, i in ipairs(s.digest[t.key]) do
        rows[t.key][#rows[t.key] + 1] = { name = e.name, commit = s.commits[i] }
        width = math.max(width, vim.fn.strdisplaywidth(text.one_line(e.name)))
      end
    end
  end

  local any = false
  for _, t in ipairs(tiers) do
    local list = rows[t.key]
    if #list > 0 then
      any = true
      r.blank()
      r.add(
        { kind = "section" },
        { { ("%s (%d)"):format(t.title, #list), "GitSuitePluginsSection" } }
      )
      for _, row in ipairs(list) do
        commit_row(m, r, row.name, row.commit, { name_width = width })
      end
    end
  end
  if not any then
    r.blank()
    r.add(
      { kind = "blank" },
      { { "No commit of this report looks breaking", "GitSuitePluginsDim" } }
    )
  end
  return r
end

---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Rendered
function M.render_detail(m)
  local r = builder()
  local entry = m.view.kind == "detail" and model.entry(m, m.view.name) or nil
  if not entry then
    summary_line(m, r, "detail")
    r.blank()
    r.add({ kind = "blank" }, { { "This plugin is not in the report", "GitSuitePluginsDim" } })
    return r
  end
  local name = text.one_line(entry.name)
  summary_line(m, r, name)
  r.blank()

  local g, word, hl = state_of(m, entry)
  local head = {
    { g .. " " .. word, hl },
    "  ",
    { name, "GitSuitePluginsName" },
  }
  local rg = range(entry)
  if rg ~= "" then
    head[#head + 1] = "  "
    head[#head + 1] = { rg, "GitSuitePluginsSha" }
  end
  if model.moved(m, entry) then
    head[#head + 1] = "  "
    head[#head + 1] = { glyph(m, "moved") .. " moved since the report", "GitSuitePluginsStale" }
  end
  r.add({ kind = "plugin", name = entry.name }, head)
  if entry.reason then
    r.add(
      { kind = "plugin", name = entry.name },
      { "  ", { text.one_line(entry.reason), "GitSuitePluginsDim" } }
    )
  end

  local s = model.summary(m, entry)
  local d = s.digest
  local shown = {}

  local function section(title, n)
    r.blank()
    r.add(
      { kind = "section", name = entry.name },
      { { ("%s (%d)"):format(title, n), "GitSuitePluginsSection" } }
    )
  end

  local breaking = {}
  for _, i in ipairs(d.sure) do
    breaking[#breaking + 1] = { i = i, tag = "[sure]" }
  end
  for _, i in ipairs(d.probable) do
    breaking[#breaking + 1] = { i = i, tag = "[probable]" }
  end
  if #breaking > 0 then
    section("BREAKING", #breaking)
    for _, b in ipairs(breaking) do
      shown[b.i] = true
      commit_row(m, r, entry.name, s.commits[b.i], { tag = b.tag })
    end
  end

  if #d.groups > 0 then
    local n = 0
    for _, grp in ipairs(d.groups) do
      n = n + #grp.members
    end
    section("GROUPED", n)
    for gi, grp in ipairs(d.groups) do
      local label = grp.kind == "parsers" and "parser updates"
        or text.one_line(grp.label or grp.key)
      r.add(
        { kind = "group", name = entry.name, sha = s.commits[grp.members[1]].sha },
        { "  ", { ("%s ×%d"):format(label, #grp.members), "GitSuitePluginsGroup" } }
      )
      for _, i in ipairs(grp.members) do
        if d.grouped[i] == gi and not shown[i] then
          shown[i] = true
          commit_row(m, r, entry.name, s.commits[i], { indent = "    " })
        end
      end
    end
  end

  local other = {}
  for i = 1, #s.commits do
    if not shown[i] then other[#other + 1] = i end
  end
  if #other > 0 then
    section("OTHER", #other)
    for _, i in ipairs(other) do
      local v = d.verdicts[i]
      commit_row(
        m,
        r,
        entry.name,
        s.commits[i],
        { tag = v and v.tier == "hint" and "[hint]" or nil }
      )
    end
  end

  local removed = model.removed(m, entry)
  if #removed > 0 then
    section(entry.status == "diverged" and "ONLY ON THE OLD SIDE" or "REMOVED", #removed)
    for _, c in ipairs(removed) do
      commit_row(m, r, entry.name, c, { removed = true })
    end
  end
  return r
end

---The preview of one commit. `files` is what the file list knows so far:
---nil (not asked yet), `"loading"`, a list of `{ status, path }`, or
---`{ error = string }`.
---@param m GitSuite.ReportUi.Model
---@param name string
---@param sha string
---@param files? "loading"|{ status: string, path: string }[]|{ error: string }
---@return GitSuite.ReportUi.Rendered
function M.render_preview(m, name, sha, files)
  local r = builder()
  local entry = model.entry(m, name)
  local commit, verdict
  if entry then
    local s = model.summary(m, entry)
    for i, c in ipairs(s.commits) do
      if c.sha == sha then
        commit, verdict = c, s.digest.verdicts[i]
      end
    end
    if not commit then
      for _, c in ipairs(entry.commits or {}) do
        if c.sha == sha then commit = c end
      end
    end
  end
  if not commit then
    r.add({ kind = "blank" }, { { "No commit under the cursor", "GitSuitePluginsDim" } })
    return r
  end

  local item = { kind = "commit", name = name, sha = sha }
  r.add(item, { { text.one_line(commit.subject or ""), "GitSuitePluginsHeader" } })
  r.add(item, {
    { text.one_line(commit.author or "?"), "GitSuitePluginsName" },
    " · ",
    day(commit.time),
    " · ",
    { sha, "GitSuitePluginsSha" },
  })
  if verdict and verdict.tier then
    r.add(item, {
      { ("%s %s"):format(glyph(m, "breaking"), verdict.tier), "GitSuitePluginsBreaking" },
      #verdict.rules > 0 and ("  (%s)"):format(table.concat(verdict.rules, ", ")) or "",
    })
  end
  if model.is_seen(m, name, sha) then r.add(item, { { "seen", "GitSuitePluginsDim" } }) end

  local body = type(commit.body) == "string" and vim.trim(commit.body) or ""
  if body ~= "" then
    r.blank()
    for _, l in ipairs((text.lines(body, 200))) do
      r.add(item, { l })
    end
  end

  r.blank()
  if files == nil or files == "loading" then
    r.add(item, { { "Files: loading...", "GitSuitePluginsDim" } })
  elseif type(files) == "table" and files.error then
    r.add(item, { { "Files: " .. text.one_line(files.error), "GitSuitePluginsDim" } })
  else
    r.add(item, { { ("Files (%d)"):format(#files), "GitSuitePluginsSection" } })
    for _, f in ipairs(files) do
      r.add(
        item,
        { "  ", { text.one_line(f.status), "GitSuitePluginsSha" }, " ", text.one_line(f.path) }
      )
    end
  end
  return r
end

---The view the model shows.
---@param m GitSuite.ReportUi.Model
---@return GitSuite.ReportUi.Rendered
function M.render(m)
  if m.view.kind == "digest" then return M.render_digest(m) end
  if m.view.kind == "detail" then return M.render_detail(m) end
  return M.render_overview(m)
end

---The line of `key` in `rendered` (`{ name, sha? }`): the commit line when
---`sha` is given, else the first line of that plugin. For the cursor restore
---after a render.
---@param rendered GitSuite.ReportUi.Rendered
---@param key { name?: string, sha?: string }
---@return integer|nil line 1-based
function M.find(rendered, key)
  for i = 1, #rendered.lines do
    local it = rendered.items[i]
    if key.sha then
      if it.kind == "commit" and it.sha == key.sha and it.name == key.name then return i end
    elseif key.name and it.name == key.name and (it.kind == "plugin" or it.kind == "unchanged") then
      return i
    end
  end
end

return M
