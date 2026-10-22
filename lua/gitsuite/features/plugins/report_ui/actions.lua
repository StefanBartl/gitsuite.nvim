---@module 'gitsuite.features.plugins.report_ui.actions'
--- What the report tab's opening keys do: the browser (a commit's page or the
--- compare page of an update), copying a hash or a URL, lazygit, the status and
--- the CHANGELOG of a clone, the breaking commits in the quickfix list.
---
--- The decisions (which URL, which hash, which commits count as seen, which
--- quickfix items) are pure functions of the model and the item under the
--- cursor; only `run_*` touch the world. Nothing here pushes, pulls or fetches:
--- the report reads. lazygit is the one exception the user asks for by name
--- (`L`): it can change the clone, the report itself never does.

local model = require("gitsuite.features.plugins.report_ui.model")
local text = require("gitsuite.features.plugins.text")

local M = {}

---Files a CHANGELOG is looked for under, in this order (case does not matter).
M.CHANGELOG_NAMES = { "changelog.md", "changelog", "changes.md", "news.md", "history.md" }

---The entry of the item under the cursor, and the commit it stands on (nil for
---a plugin line).
---@param m GitSuite.ReportUi.Model
---@param it GitSuite.ReportUi.Item|nil
---@return GitSuite.Plugins.ReportEntry|nil entry
---@return string|nil sha
function M.target(m, it)
  if not it or not it.name then return nil, nil end
  local entry = model.entry(m, it.name)
  if not entry then return nil, nil end
  return entry, it.kind == "commit" and it.sha or nil
end

---The web page for the item: a commit's page on a commit line, the compare
---page of the update on a plugin line or with `compare`; with the commits the
---user then looked at (they count as seen).
---@param m GitSuite.ReportUi.Model
---@param it GitSuite.ReportUi.Item|nil
---@param compare? boolean
---@return string|nil url
---@return string|nil err
---@return { name: string, sha: string }[] seen
function M.url(m, it, compare)
  local links = require("gitsuite.features.plugins.links")
  local entry, sha = M.target(m, it)
  if not entry then return nil, "put the cursor on a plugin or a commit", {} end
  if sha and not compare then
    local url, err = links.commit_url(entry.dir, sha)
    local new = false
    for _, k in ipairs(model.commit_keys(m, entry)) do
      if k.sha == sha then new = true end
    end
    return url, err, (url and new) and { { name = entry.name, sha = sha } } or {}
  end
  if entry.from and entry.to then
    -- A rollback went back: compared the other way round the page lists the
    -- commits it removed (from...to would be "nothing to compare").
    local base, head = entry.from, entry.to
    if entry.status == "rollback" then
      base, head = entry.to, entry.from
    end
    local url, err = links.compare_url(entry.dir, base, head)
    return url, err, url and model.commit_keys(m, entry) or {}
  end
  if entry.to then
    -- A fresh install has nothing to compare with: the commit it landed on.
    local url, err = links.commit_url(entry.dir, entry.to)
    return url, err, {}
  end
  return nil, "this plugin has no commit to show", {}
end

---The hash for `y` (short) / `Y` (full): the commit under the cursor, or on a
---plugin line the commit its update ended on.
---@param m GitSuite.ReportUi.Model
---@param it GitSuite.ReportUi.Item|nil
---@param full? boolean
---@return string|nil
function M.hash(m, it, full)
  local entry, sha = M.target(m, it)
  sha = sha or (entry and entry.to)
  if type(sha) ~= "string" or not sha:match("^%x+$") then return nil end
  return full and sha or sha:sub(1, 7)
end

---The CHANGELOG of the clone at `dir`, if it has one at its top.
---@param dir string
---@return string|nil path
function M.changelog(dir)
  if type(dir) ~= "string" or vim.fn.isdirectory(dir) ~= 1 then return nil end
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" then found[name:lower()] = name end
  end
  for _, want in ipairs(M.CHANGELOG_NAMES) do
    if found[want] then return dir .. "/" .. found[want] end
  end
  return nil
end

---Quickfix items for the breaking commits of the report (sure, then probable),
---each saying plugin, short hash and subject; `user_data` keeps the key.
---@param m GitSuite.ReportUi.Model
---@return table[]
function M.breaking_items(m)
  local items = {}
  for _, tier in ipairs({ "sure", "probable" }) do
    for _, entry in ipairs(model.entries(m)) do
      local s = model.summary(m, entry)
      for _, i in ipairs(s.digest[tier]) do
        local c = s.commits[i]
        items[#items + 1] = {
          text = ("%s  %s  [%s] %s"):format(
            text.one_line(entry.name),
            c.sha:sub(1, 7),
            tier,
            text.one_line(c.subject or "")
          ),
          user_data = { name = entry.name, sha = c.sha },
          valid = 0,
        }
      end
    end
  end
  return items
end

---The status of the clone at `dir` as lines: `git status --short --branch` and
---the last five commits, through the read-only runner (no lock, nothing
---refreshed, no program the clone's config names). A clean filter the user set
---up globally (git-lfs) may still run for a file whose stat changed.
---@param dir string
---@param on_done fun(lines: string[])
function M.status(dir, on_done)
  local gitlog = require("gitsuite.features.plugins.gitlog")
  local short, log
  local function settle()
    if short == nil or log == nil then return end
    local lines = {}
    for _, l in ipairs(short) do
      lines[#lines + 1] = "  " .. text.one_line(l)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " Recent commits"
    for _, l in ipairs(log) do
      lines[#lines + 1] = "  " .. text.one_line(l)
    end
    on_done(lines)
  end
  local function lines_of(res, err)
    if err or not res or res.code ~= 0 then
      return { "error: " .. text.one_line(err or (res and res.stderr) or "git failed") }
    end
    local out = {}
    for l in ((res.stdout or "") .. "\n"):gmatch("(.-)\n") do
      if l ~= "" then out[#out + 1] = l end
    end
    return out
  end
  gitlog.run({ "status", "--short", "--branch" }, dir, function(res, err)
    short = lines_of(res, err)
    if #short <= 1 and not (short[1] or ""):find("^error") then
      short[#short + 1] = "working tree clean"
    end
    settle()
  end)
  gitlog.run({ "log", "-n5", "--format=%h  %an  %s" }, dir, function(res, err)
    log = lines_of(res, err)
    settle()
  end)
end

return M
