-- TESTS/gitsuite/dashboard_bulk_report_spec.lua -- the closing notification of a dashboard
-- batch (gitsuite.features.dashboard.bulk_report): what changed per repository, what failed and
-- why, what was skipped, the rest only counted.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

describe("gitsuite.features.dashboard.bulk_report.format", function()
  local report = require("gitsuite.features.dashboard.bulk_report")

  it("a batch where nothing changed is one line of counts", function()
    local msg, failed =
      report.format("fetch", { { name = "a", ok = true }, { name = "b", ok = true } }, 2)
    assert.is_false(failed)
    assert.equals("fetch: 2 repositories done, 0 changed, 2 unchanged", msg)
  end)

  it("lists the changed ones under the counts, in the order given", function()
    local msg, failed = report.format("pull", {
      { name = "a", ok = true, detail = "pulled new commits" },
      { name = "b", ok = true },
      { name = "c", ok = true, detail = "pulled new commits" },
    }, 3)
    assert.is_false(failed)
    assert.equals(
      table.concat({
        "pull: 3 repositories done, 2 changed, 1 unchanged",
        "",
        "Changed:",
        "  a: pulled new commits",
        "  c: pulled new commits",
      }, "\n"),
      msg
    )
  end)

  it("failures come first, trimmed, and flag the message", function()
    local msg, failed = report.format("push", {
      { name = "a", ok = false, err = "  rejected\n" },
      { name = "b", ok = false },
    }, 2)
    assert.is_true(failed)
    assert.equals(
      table.concat({
        "push: 2 of 2 failed, 0 changed, 0 unchanged",
        "",
        "Failed:",
        "  a: rejected",
        "  b: unknown error",
      }, "\n"),
      msg
    )
  end)

  it("keeps a multi-line git error on its repository's one line", function()
    local rejected = table.concat({
      "To /tmp/remote.git",
      " ! [rejected]        main -> main (fetch first)",
      "error: failed to push some refs to '/tmp/remote.git'",
      "hint: Updates were rejected because the remote contains work that you do not",
      "hint: have locally.",
      "",
    }, "\n")
    local msg = report.format("push", {
      { name = "a", ok = false, err = rejected },
      { name = "b", ok = false, err = "Some text\nfatal: unable to access 'x'\n" },
      { name = "c", ok = false, err = "\n  first\nsecond\n" },
    }, 3)
    assert.equals(
      table.concat({
        "push: 3 of 3 failed, 0 changed, 0 unchanged",
        "",
        "Failed:",
        "  a: ! [rejected]        main -> main (fetch first)",
        "  b: fatal: unable to access 'x'",
        "  c: first",
      }, "\n"),
      msg
    )
  end)

  it("names a cancelled tail and agrees in number for one repository", function()
    local msg = report.format("sync", { { name = "a", ok = true, detail = "pushed 1 commit" } }, 3)
    assert.truthy(
      msg:find(
        "sync: 1 repository done, 1 changed, 0 unchanged, 2 not started (cancelled)",
        1,
        true
      ),
      msg
    )
    assert.equals("1 commit", report.commits(1))
    assert.equals("4 commits", report.commits(4))
  end)
end)
