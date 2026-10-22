---@module 'gitsuite.features.plugins.report_ui'
--- The report tab of `:Git plugins` / `:Git plugins report` (`--out=tab`, the
--- default): a list of what changed, a breaking digest and a detail per plugin,
--- with a preview that follows the cursor. The pieces:
---
---   * `model`   the state (view, sort, seen marks), pure;
---   * `render`  the views as lines, highlights and keyed items, pure;
---   * `keys`    the one table of keys (maps, legend, `?`, BINDINGS.md);
---   * `window`  the tab, its two windows and buffers.

local M = {}

---Where each changed clone's HEAD is now (read from files, no process): a
---clone that moved since the report is marked as such.
---@param report GitSuite.Plugins.Report
---@return table<string, string>
function M.heads(report)
  local gitfs = require("gitsuite.features.plugins.gitfs")
  local out = {}
  for _, e in ipairs(report.plugins or {}) do
    if type(e.dir) == "string" and e.head then
      local ok, head = pcall(gitfs.head, e.dir)
      if ok and head and head.sha then out[e.dir] = head.sha end
    end
  end
  return out
end

---Show `report` in the report tab, with the seen marks read fresh from their
---file and each clone's HEAD as it is now.
---@param report GitSuite.Plugins.Report
---@param opts? { ctx?: GitSuite.Plugins.ClassifyContext, seen_path?: string }
---@return nil
function M.open(report, opts)
  opts = opts or {}
  local ctx = opts.ctx
  if ctx == nil then
    local ok, c = pcall(require("gitsuite.features.plugins.report").context)
    ctx = ok and c or nil
  end
  local seen = require("gitsuite.features.plugins.report_ui.seen")
  local window = require("gitsuite.features.plugins.report_ui.window")
  if opts.seen_path then window.set_seen_path(opts.seen_path) end
  local path = window.state().seen_path
  local marks, info = seen.load(path)
  if info.error then
    require("gitsuite.util.notify").warn(
      ("plugins report: the seen marks cannot be read (%s); the next mark moves the file aside"):format(
        info.error
      )
    )
  end
  local m = require("gitsuite.features.plugins.report_ui.model").new(report, {
    ctx = ctx,
    ascii = require("gitsuite.config").get().plugins.ascii == true,
    seen = seen.set(marks),
    heads = M.heads(report),
  })
  window.open(m)
end

---`:Git plugins`: the report tab again if it was open in this Neovim, else the
---newest stored report -- never a scan.
---@param opts? { store_path?: string }
---@return boolean shown
function M.open_last(opts)
  opts = opts or {}
  local window = require("gitsuite.features.plugins.report_ui.window")
  local s = window.state()
  if s.model then
    M.open(s.model.report, { ctx = s.model.ctx })
    return true
  end
  local store = require("gitsuite.features.plugins.state").load(opts.store_path, { peek = true })
  local newest = store.reports and store.reports[1]
  if not newest then
    require("gitsuite.util.notify").info(
      "plugins: no report stored yet -- :Git plugins report builds one"
    )
    return false
  end
  M.open(newest)
  return true
end

return M
