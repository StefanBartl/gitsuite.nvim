-- TESTS/fixtures/report_ui_report.lua -- a stored `:Git plugins report` (`mode = "updated"`) as the
-- report tab reads it back: five changed plugins (one breaking, one with a run of repeated commits,
-- a rollback, one that could not be read, a fresh install) and two unchanged ones. Hand-written in
-- the shape `features/plugins/report.lua` stores (`GitSuite.Plugins.Report`); SHAs are fixed hex.

local T = 1790000000

local function sha(c)
  return string.rep(c, 40)
end

local function commit(c, subject, extra)
  local out = { sha = sha(c), subject = subject, body = "", author = "Ada", time = T - 3600 }
  for k, v in pairs(extra or {}) do
    out[k] = v
  end
  return out
end

return {
  version = 1,
  id = "r-fixture",
  at = T,
  mode = "updated",
  host = "fixture-host",
  sources = { "lazy" },
  plugins = {
    {
      name = "telescope.nvim",
      dir = "/lazy/telescope.nvim",
      managed_by = "lazy",
      status = "forward",
      source = "reflog",
      confidence = "exact",
      head = sha("2"),
      from = sha("1"),
      to = sha("2"),
      to_label = "v0.2.0",
      time = T - 60,
      order = "topo",
      commits = {
        commit("a", "feat(picker)!: drop the old layout API", {
          body = "BREAKING CHANGE: layout_strategy is gone.\nUse layout_config.",
          author = "Bea",
        }),
        commit("b", "fix: keep the cursor in the prompt"),
        commit("c", "docs: readme"),
      },
    },
    {
      name = "mason.nvim",
      dir = "/lazy/mason.nvim",
      managed_by = "lazy",
      status = "forward",
      source = "reflog",
      confidence = "exact",
      head = sha("4"),
      from = sha("3"),
      to = sha("4"),
      time = T - 120,
      commits = {
        commit("d", "chore(registry): update"),
        commit("e", "chore(registry): update"),
        commit("f", "chore(registry): update"),
        commit("1", "chore(registry): update"),
        commit("2", "chore(registry): update"),
        commit("0", "fix: install path on Windows"),
      },
    },
    {
      name = "gitsigns.nvim",
      dir = "/lazy/gitsigns.nvim",
      managed_by = "lazy",
      status = "rollback",
      source = "reflog",
      confidence = "exact",
      head = sha("5"),
      from = sha("6"),
      to = sha("5"),
      time = T - 30,
      commits = { commit("9", "feat: blame in the sign column") },
    },
    {
      name = "broken.nvim",
      dir = "/lazy/broken.nvim",
      managed_by = "lazy",
      status = "error",
      source = "reflog",
      confidence = "exact",
      reason = "HEAD names no commit",
    },
    {
      name = "fresh.nvim",
      dir = "/lazy/fresh.nvim",
      managed_by = "lazy",
      status = "new",
      source = "reflog",
      confidence = "exact",
      head = sha("7"),
      to = sha("7"),
    },
  },
  heads = {
    ["/lazy/telescope.nvim"] = sha("2"),
    ["/lazy/mason.nvim"] = sha("4"),
    ["/lazy/gitsigns.nvim"] = sha("5"),
    ["/lazy/fresh.nvim"] = sha("7"),
    ["/lazy/plenary.nvim"] = sha("8"),
    ["/lazy/Comment.nvim"] = sha("8"),
  },
  counts = { checked = 7, changed = 5, commits = 10, unchanged = 2, failed = 1 },
  errors = {},
}
