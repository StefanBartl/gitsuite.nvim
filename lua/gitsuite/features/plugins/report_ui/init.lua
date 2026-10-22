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

---Show `report` in the report tab.
---@param report GitSuite.Plugins.Report
---@param opts? { ctx?: GitSuite.Plugins.ClassifyContext }
---@return nil
function M.open(report, opts)
  opts = opts or {}
  local ctx = opts.ctx
  if ctx == nil then
    local ok, c = pcall(require("gitsuite.features.plugins.report").context)
    ctx = ok and c or nil
  end
  local m = require("gitsuite.features.plugins.report_ui.model").new(report, { ctx = ctx })
  require("gitsuite.features.plugins.report_ui.window").open(m)
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
    window.open(s.model)
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
