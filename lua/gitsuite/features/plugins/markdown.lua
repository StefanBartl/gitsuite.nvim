---@module 'gitsuite.features.plugins.markdown'
--- A report as Markdown: what `:Git plugins report --out=buffer|clipboard|path`
--- shows and writes. Pure -- a report table in, lines out.
---
--- Every line says where it came from: `reflog` (exact: the clone's own record
--- of the update), `snapshot ~` (approximate: the state at the last report, used
--- when the reflog says nothing) or `pending` (the target lazy.nvim would move
--- to, as of the last fetch). Commit text comes from other people's
--- repositories and goes through `text` before it is printed.

local text = require("gitsuite.features.plugins.text")

local M = {}

---Commits listed per plugin; the stored report keeps all of them.
M.MAX_LISTED = 200

---Text from another repository as one line of Markdown prose: cleaned, and the
---characters that would make a link, an image, HTML or a code span escaped --
---a commit subject like `![x](http://host/t.png)` must stay text when the report
---is previewed or pasted somewhere that renders Markdown.
---@param s any
---@return string
local function esc(s)
  return (text.one_line(s):gsub("[\\`<>%[%]]", "\\%0"))
end

---As `esc`, for a table cell (a `|` would end it).
---@param s any
---@return string
local function cell(s)
  return (esc(s):gsub("|", "\\|"))
end

---Text inside a code span: a backtick would end it.
---@param s any
---@return string
local function code(s)
  return (text.one_line(s):gsub("`", "'"))
end

---@param sha any
---@return string
local function short(sha)
  return type(sha) == "string" and (sha:match("^%x+") or "?"):sub(1, 8) or "?"
end

---@param t any
---@return string
local function day(t)
  return type(t) == "number" and os.date("%Y-%m-%d", t) --[[@as string]] or "          "
end

---@param t any
---@return string
local function moment(t)
  return type(t) == "number" and os.date("%Y-%m-%d %H:%M:%S", t) --[[@as string]] or "?"
end

---@param t integer
---@param now integer
---@return string
local function age(t, now)
  local s = math.max(0, now - t)
  if s < 3600 then return ("%d min"):format(math.floor(s / 60)) end
  if s < 86400 then return ("%d h"):format(math.floor(s / 3600)) end
  return ("%d days"):format(math.floor(s / 86400))
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

local STATUS_LABEL = {
  forward = "updated",
  rollback = "rolled back",
  diverged = "diverged",
  same = "no commits",
  new = "newly installed",
  pinned = "pinned",
  unknown_target = "target unknown",
  from_missing = "old state gone",
  error = "error",
  no_git = "not a clone",
}

---@param entry table
---@param mode string
---@return string
local function status_label(entry, mode)
  if mode == "pending" then
    if entry.status == "forward" then return "update available" end
    if entry.status == "rollback" then return "update would roll back" end
  end
  return STATUS_LABEL[entry.status] or esc(entry.status)
end

---@param entry table
---@return string
local function source_label(entry)
  if entry.source == "snapshot" then return "snapshot ~" end
  return esc(entry.source or "?")
end

---@param entry table
---@return string
local function range_label(entry)
  if not entry.from and not entry.to_label then return "" end
  return ("`%s → %s`"):format(short(entry.from), code(entry.to_label or short(entry.to)))
end

---@param lines string[]
---@param commit table
local function commit_line(lines, commit)
  lines[#lines + 1] = ("- `%s` %s %s (%s)"):format(
    short(commit.sha),
    day(commit.time),
    esc(commit.subject),
    esc(commit.author)
  )
end

---@param lines string[]
---@param commits table[]
---@param side? string
---@param heading string
local function commit_list(lines, commits, side, heading)
  local picked = {}
  for _, commit in ipairs(commits) do
    if side == nil or commit.side == side then picked[#picked + 1] = commit end
  end
  if #picked == 0 then return end
  lines[#lines + 1] = heading
  lines[#lines + 1] = ""
  for i, commit in ipairs(picked) do
    if i > M.MAX_LISTED then
      lines[#lines + 1] = ("- … %d more (display limit %d per list; the stored report has them all)"):format(
        #picked - M.MAX_LISTED,
        M.MAX_LISTED
      )
      break
    end
    commit_line(lines, commit)
  end
  lines[#lines + 1] = ""
end

---@param report table
---@param now? integer
---@return string[] lines
function M.render(report, now)
  now = now or os.time()
  local mode = report.mode
  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
  end

  add(("# Plugin changes — %s (%s)"):format(mode, moment(report.at)))
  add("")
  add(
    ("- Host: %s · sources: %s%s"):format(
      cell(report.host or "?"),
      cell(table.concat(
        vim.tbl_filter(function(v)
          return type(v) == "string"
        end, report.sources or {}),
        ", "
      )),
      report.lazy and (" · lazy.nvim " .. cell(report.lazy)) or ""
    )
  )
  add(("- Report: `%s`"):format(code(report.id or "?")))
  if mode == "updated" then
    add(
      "- Compares the state before the last update with the current one, from each clone's own reflog."
    )
    if report.run then
      add(
        ("- Run: %s – %s (%s%s)"):format(
          moment(report.run.first),
          moment(report.run.last),
          plural(report.run.plugins or 0, "plugin"),
          (report.run.older or 0) > 0
              and ("; " .. plural(report.run.older, "earlier update") .. " not shown")
            or ""
        )
      )
    else
      add("- No update found in any clone's reflog.")
    end
  else
    add(
      "- Compares the current state with the target lazy.nvim would move to — as of each clone's last fetch. gitsuite does not fetch; `:Lazy check` does."
    )
    -- The age of the remote state is judged over EVERY clone looked at (the
    -- report carries it: up-to-date plugins are not listed); a report stored
    -- before that was recorded falls back to the plugins it lists.
    local fetch = report.fetch
    if type(fetch) ~= "table" then
      fetch = { checked = #report.plugins, known = 0 }
      for _, entry in ipairs(report.plugins) do
        local at = entry.fetched_at
        if type(at) == "number" then
          fetch.known = fetch.known + 1
          fetch.oldest = fetch.oldest and math.min(fetch.oldest, at) or at
          fetch.newest = fetch.newest and math.max(fetch.newest, at) or at
        end
      end
    end
    if fetch.oldest and fetch.newest then
      add(
        ("- Remote state: last fetched %s ago (oldest %s ago)%s."):format(
          age(fetch.newest, now),
          age(fetch.oldest, now),
          fetch.known < fetch.checked
              and ("; " .. plural(fetch.checked - fetch.known, "clone") .. " without a recorded fetch")
            or ""
        )
      )
    else
      add("- No fetch is recorded in these clones: the remote state may be old.")
    end
  end
  add(
    "- Source: `reflog` exact · `snapshot ~` approximate (state of the last report) · `pending` as of the last fetch."
  )
  add("")

  local counts = report.counts or {}
  add("## Summary")
  add("")
  add(
    ("%s checked · %s changed · %s in the report · %s unchanged or not compared"):format(
      plural(counts.checked or 0, "plugin"),
      tostring(counts.changed or 0),
      plural(counts.commits or 0, "commit"),
      tostring(counts.unchanged or 0)
    )
  )
  add("")

  local shown = report.plugins
  if #shown == 0 then
    add("Nothing to report.")
    add("")
  else
    add("| Plugin | State | Range | Commits | Source |")
    add("| --- | --- | --- | --- | --- |")
    for _, entry in ipairs(shown) do
      local n = #(entry.commits or {})
      add(
        ("| %s | %s | %s | %s | %s |"):format(
          cell(entry.name),
          cell(status_label(entry, mode)),
          range_label(entry),
          entry.commits and (tostring(n) .. (entry.truncated and "+" or "")) or "",
          source_label(entry)
        )
      )
    end
    add("")
  end

  for _, entry in ipairs(shown) do
    local has_commits = entry.commits and #entry.commits > 0
    if has_commits or entry.reason then
      add(("## %s"):format(cell(entry.name)))
      add("")
      local meta = { status_label(entry, mode) }
      if entry.time then meta[#meta + 1] = moment(entry.time) end
      meta[#meta + 1] = source_label(entry)
      if entry.locked then meta[#meta + 1] = "index.lock present (an update may be running)" end
      add(("%s %s"):format(range_label(entry), table.concat(meta, " · ")))
      add("")
      if entry.reason then
        add(esc(entry.reason))
        add("")
      end
      if has_commits then
        if entry.status == "rollback" then
          commit_list(
            lines,
            entry.commits,
            nil,
            mode == "pending" and "Commits the update would remove:"
              or "Commits no longer installed:"
          )
        elseif entry.status == "diverged" then
          commit_list(
            lines,
            entry.commits,
            ">",
            mode == "pending" and "The update would add:" or "Only in the new state:"
          )
          commit_list(
            lines,
            entry.commits,
            "<",
            mode == "pending" and "The update would remove:" or "Only in the old state:"
          )
        else
          commit_list(
            lines,
            entry.commits,
            nil,
            mode == "pending" and "Commits not installed yet:" or "Commits in this update:"
          )
        end
        if entry.truncated then
          add(
            "(Cut at the configured `plugins.max_commits`; there are more commits in this range.)"
          )
          add("")
        end
      end
    end
  end

  for _, e in ipairs(report.errors or {}) do
    add("> " .. esc(e))
  end
  return lines
end

return M
