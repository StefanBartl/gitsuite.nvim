-- TESTS/gitsuite/plugins_report_last_tab_q_spec.lua -- the report tab as the ONLY tab page: `q`
-- leaves an empty window instead of raising. A fixture report (TESTS/fixtures/report_ui_report.lua);
-- no process. Its sibling plugins_report_last_tab_list_close_spec.lua closes the list window instead.
--
-- Why a file of its own, as one case (`return function(H)`): the scenario needs `:tabonly` from the
-- report tab, which closes the tab page and the window the editor started with. No clean-up can
-- bring those back, so a busted case would leave a window, a tab page and a buffer to the next one
-- (the state guard on "error" says so). A one-case file runs in a child editor that ends with it
-- (`isolated = "file"`): nothing it leaves reaches another case.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

return function(H)
  local ui, window

  local function S()
    return window.state()
  end

  ---Fresh modules and a fresh fixture report, as the busted specs' `before_each` does.
  ---@return table report
  local function fresh()
    if window then window.reset() end
    for _, mod in ipairs({ "", ".window", ".keys", ".render", ".model", ".seen", ".preview" }) do
      package.loaded["gitsuite.features.plugins.report_ui" .. mod] = nil
    end
    ui = require("gitsuite.features.plugins.report_ui")
    window = require("gitsuite.features.plugins.report_ui.window")
    -- Never the real stdpath("state"): marks go to a file of this spec.
    window.set_seen_path(vim.fn.tempname() .. "/plugins_seen.json")
    return dofile(dir_of_spec .. "../fixtures/report_ui_report.lua")
  end

  ---Run the report tab's mapping for `lhs`, as a key press would.
  local function press(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(S().list_buf, "n")) do
      if m.lhs == lhs or vim.fn.keytrans(m.lhs) == lhs then
        m.callback()
        return
      end
    end
    error("no report mapping for " .. lhs)
  end

  -- q in the last tab leaves an empty window, not an error.
  do
    local report = fresh()
    ui.open(report)
    vim.cmd("silent! tabonly")
    H.eq(#vim.api.nvim_list_tabpages(), 1, "the report is the only tab")
    press("q")
    local win = vim.api.nvim_get_current_win()
    H.ok(
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= window.LIST_NAME,
      "q: the window no longer shows the list"
    )
    H.eq(vim.wo[win].winfixbuf, false, "q: the window is no longer fixed")
    H.eq(ui.open_last(), true, "q: the report opens again")
  end

  window.reset()
end
