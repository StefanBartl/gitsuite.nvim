---@module 'gitsuite.features.plugins.report_ui.keys'
--- The keys of the report tab, in ONE table. The window binds them from it,
--- the winbar legend and the `?` list are made from it, and a spec compares it
--- with the "Plugins report keys" section of `docs/BINDINGS.md` (`doc_rows`),
--- so the four can never say different things. Pure: no window here; the
--- window maps `action` to what it does.

local M = {}

---@class GitSuite.ReportUi.Key
---@field keys string[]        Every lhs; several keys share one action (`run(lhs)` tells them apart).
---@field action string        What the window does (`window.lua` holds the handlers).
---@field desc string          The keymap's `desc`, the `?` line and the BINDINGS cell.
---@field label? string        Short "key word" for the winbar legend; nil = only under `?`.
---@field views? string[]      Views the key works in; nil = all. The legend only shows those of the current view.

---@type GitSuite.ReportUi.Key[]
M.KEYS = {
  {
    keys = { "<CR>" },
    action = "open",
    label = "<CR> open",
    desc = "On a plugin: its detail. On a commit in the digest: its plugin's detail, cursor on the commit",
  },
  {
    keys = { "<BS>" },
    action = "back",
    views = { "digest", "detail" },
    label = "<BS> back",
    desc = "Back to the overview",
  },
  {
    keys = { "D" },
    action = "digest",
    label = "D digest",
    desc = "Breaking digest: the breaking commits of every plugin in one list",
  },
  {
    keys = { "s" },
    action = "sort",
    views = { "overview" },
    label = "s sort",
    desc = "Cycle the sort: breaking first, name, number of commits, time of the update",
  },
  {
    keys = { "A" },
    action = "all",
    views = { "overview" },
    desc = "List the unchanged plugins too, or count them again",
  },
  {
    keys = { "]]", "[[" },
    action = "plugin",
    views = { "detail" },
    label = "]] next",
    desc = "Next / previous plugin's detail (in the overview's order)",
  },
  {
    keys = { "]b", "[b" },
    action = "breaking",
    label = "]b breaking",
    desc = "Next / previous breaking commit not marked as seen",
  },
  {
    keys = { "p" },
    action = "preview",
    label = "p preview",
    desc = "Show or hide the preview (follows the cursor)",
  },
  {
    keys = { "q" },
    action = "close",
    label = "q close",
    desc = "Close the report tab; the report stays, `:Git plugins` opens it again",
  },
  {
    keys = { "?" },
    action = "help",
    label = "? keys",
    desc = "List every one of these keys",
  },
}

---Whether `key` works in `view` (a view kind).
---@param key GitSuite.ReportUi.Key
---@param view string
---@return boolean
function M.applies(key, view)
  return key.views == nil or vim.tbl_contains(key.views, view)
end

---Separator between legend entries.
local SEP = "  │  "

---The winbar legend for `view`, fitted to `width` cells: entries are dropped
---from the right until it fits, except the last one (`? keys`), which says
---how to reach everything dropped. Plain text (the window adds highlights).
---@param view string
---@param width integer
---@return string
function M.legend(view, width)
  local labels = {}
  for _, k in ipairs(M.KEYS) do
    if k.label and M.applies(k, view) then labels[#labels + 1] = k.label end
  end
  if #labels == 0 then return "" end
  local pinned = table.remove(labels)
  local budget = math.max(width, 0) - 2
  local used = vim.fn.strdisplaywidth(pinned)
  local kept = {}
  for _, l in ipairs(labels) do
    local cost = vim.fn.strdisplaywidth(l) + vim.fn.strdisplaywidth(SEP)
    if used + cost > budget then break end
    kept[#kept + 1] = l
    used = used + cost
  end
  kept[#kept + 1] = pinned
  return " " .. table.concat(kept, SEP)
end

---@param key GitSuite.ReportUi.Key
---@return string
local function lhs_text(key)
  return table.concat(key.keys, " / ")
end

---The lines of the `?` list: every key, aligned.
---@return string[]
function M.help_lines()
  local widest = 0
  for _, k in ipairs(M.KEYS) do
    widest = math.max(widest, vim.fn.strdisplaywidth(lhs_text(k)))
  end
  local lines = { "", " Plugins report keys", "" }
  for _, k in ipairs(M.KEYS) do
    local lhs = lhs_text(k)
    lines[#lines + 1] = ("  %s%s   %s"):format(
      lhs,
      string.rep(" ", widest - vim.fn.strdisplaywidth(lhs)),
      k.desc
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " q / <Esc>  close this list"
  return lines
end

---The rows of the "Plugins report keys" table in `docs/BINDINGS.md`, exactly
---as they must stand there.
---@return string[]
function M.doc_rows()
  local rows = {}
  for _, k in ipairs(M.KEYS) do
    local cells = {}
    for _, lhs in ipairs(k.keys) do
      cells[#cells + 1] = "`" .. lhs .. "`"
    end
    rows[#rows + 1] = ("| %s | n | %s |"):format(table.concat(cells, " / "), k.desc)
  end
  return rows
end

return M
