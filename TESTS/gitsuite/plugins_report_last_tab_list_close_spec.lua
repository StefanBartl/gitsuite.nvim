-- TESTS/gitsuite/plugins_report_last_tab_list_close_spec.lua -- the report tab as the ONLY tab
-- page: closing its list window hands the preview window back instead of raising. A fixture report
-- (TESTS/fixtures/report_ui_report.lua); no process. Its sibling plugins_report_last_tab_q_spec.lua
-- presses `q` instead.
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

  -- Closing the list in the only tab hands the preview window back.
  do
    local report = fresh()
    ui.open(report)
    vim.cmd("silent! tabonly")
    vim.api.nvim_win_close(S().list_win, true)
    vim.wait(100)
    local win = vim.api.nvim_get_current_win()
    H.eq(#vim.api.nvim_list_wins(), 1, "list closed: one window left")
    H.eq(vim.wo[win].winfixbuf, false, "list closed: the preview window is no longer fixed")
    H.ok(
      vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= window.PREVIEW_NAME,
      "list closed: the window no longer shows the preview"
    )
    H.ok(pcall(vim.cmd, "enew"), "list closed: the window takes another buffer")
  end

  window.reset()
end
