-- TESTS/gitsuite/dashboard_export_spec.lua -- the reports the dashboard's `E` key exports
-- (gitsuite.features.dashboard.export): which repository lands in which report and how it reads.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

local NOW = 1000000

---@param over table
---@return RepoDashboardRecord
local function rec(over)
  return vim.tbl_extend("force", {
    name = "r",
    path = "/r",
    branch = "main",
    ahead = 0,
    behind = 0,
    has_upstream = true,
    dirty = 0,
    state = "clean",
    last_commit = NOW - 7200,
  }, over)
end

describe("gitsuite.features.dashboard.export.reports", function()
  local export = require("gitsuite.features.dashboard.export")

  local records = {
    rec({ name = "clean" }),
    rec({ name = "dirty", dirty = 4, state = "dirty" }),
    rec({ name = "behind", behind = 3, state = "behind" }),
    rec({ name = "ahead", ahead = 1, state = "ahead" }),
    rec({ name = "split", ahead = 1, behind = 2, state = "diverged" }),
    rec({ name = "pending", state = "scanning", unscanned = true }),
  }

  ---@param id string
  ---@return GitSuiteDashboardExportReport
  local function report(id)
    for _, rep in ipairs(export.reports(records)) do
      if rep.id == id then return rep end
    end
    error("no report " .. id)
  end

  it("sorts each repository into the reports it belongs to", function()
    assert.same({ 1, 2, 3, 4, 5 }, report("all").indices)
    assert.same({ 2, 3, 4, 5 }, report("attention").indices)
    assert.same({ 2 }, report("dirty").indices)
    assert.same({ 3, 5 }, report("behind").indices)
    assert.same({ 4, 5 }, report("ahead").indices)
    assert.same({ 5 }, report("diverged").indices)
  end)

  it("names the count in the choice label", function()
    assert.equals("Behind (2)", report("behind").label)
  end)

  it("leaves out repositories whose scan has not finished", function()
    for _, rep in ipairs(export.reports(records)) do
      assert.is_false(vim.tbl_contains(rep.indices, 6))
    end
  end)
end)

describe("gitsuite.features.dashboard.export.build", function()
  local export = require("gitsuite.features.dashboard.export")

  it("renders a heading and one aligned line per repository", function()
    local lines, n = export.build("behind", {
      rec({ name = "alpha", behind = 3, state = "behind" }),
      rec({ name = "be", behind = 1, state = "behind", branch = "dev" }),
      rec({ name = "gamma" }),
    }, NOW)
    assert.equals(2, n)
    assert.same({
      "Dashboard: 2 of 3 repositories (behind)",
      "",
      "alpha  main  behind  3 behind  2h",
      "be     dev   behind  1 behind  2h",
    }, lines)
  end)

  it("shows dirty file counts and combined state for the others", function()
    local lines = export.build("dirty", { rec({ name = "a", dirty = 4, state = "dirty" }) }, NOW)
    assert.equals("a  main  dirty  4 changed  2h", lines[3])
    local all = export.build("attention", {
      rec({ name = "d", ahead = 1, behind = 2, dirty = 5, state = "diverged" }),
    }, NOW)
    assert.equals("d  main  diverged  1 ahead, 2 behind, 5 changed  2h", all[3])
  end)

  it("lists a clean repository without a detail cell in the full report", function()
    local lines = export.build("all", { rec({ name = "a" }) }, NOW)
    assert.equals("a  main  clean  2h", lines[3])
  end)

  it("answers nil for an unknown report", function()
    assert.is_nil(export.build("nope", { rec({}) }, NOW))
  end)

  it("a report nobody is in is just the heading", function()
    local lines, n = export.build("ahead", { rec({}) }, NOW)
    assert.equals(0, n)
    assert.same({ "Dashboard: 0 of 1 repositories (ahead)", "" }, lines)
  end)
end)

describe("dashboard E key", function()
  it("is bound among the row keys and listed with a legend label", function()
    local src = vim.fn.readfile(
      vim.fn.fnamemodify(
        vim.api.nvim_get_runtime_file("lua/gitsuite/features/dashboard/view.lua", false)[1],
        ":p"
      )
    )
    local text = table.concat(src, "\n")
    assert.is_truthy(text:find('keys = { "E" },', 1, true))
    assert.is_truthy(text:find('label = "E Export"', 1, true))
  end)
end)
