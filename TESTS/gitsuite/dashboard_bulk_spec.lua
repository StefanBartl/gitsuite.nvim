-- TESTS/gitsuite/dashboard_bulk_spec.lua -- acting on settled dashboard rows while a bulk
-- action (gf/gp/gu) still works through the rest: per-repository phases and lock
-- (gitsuite.features.dashboard.repo_state) and the view's use of them.
--
-- No network and no real git: the actions and the row re-read are fakes, and each fake git
-- call is either completed by hand (to pin down an exact interleaving) or after a timer
-- (simulated delay).
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite.features.dashboard.repo_state", function()
  local state

  before_each(function()
    package.loaded["gitsuite.features.dashboard.repo_state"] = nil
    state = require("gitsuite.features.dashboard.repo_state")
  end)

  it("try_lock is per repository and reports the holder", function()
    assert.is_true(state.try_lock("/a", "pull"))
    local ok, holder = state.try_lock("/a", "fetch")
    assert.is_false(ok)
    assert.equals("pull", holder)
    assert.is_true(state.try_lock("/b", "fetch"), "another repository is independent")
    state.unlock("/a")
    assert.is_true(state.try_lock("/a", "fetch"))
  end)

  it("acquire refuses pending and fetching rows, allows done and failed ones", function()
    state.begin_bulk("fetch", { "/p", "/f", "/d", "/x" })
    state.set_phase("/f", "fetching")
    state.set_phase("/d", "done")
    state.set_phase("/x", "failed")

    local ok, why = state.acquire("/p", "pull")
    assert.is_false(ok)
    assert.truthy(why:find("queued", 1, true), why)
    ok, why = state.acquire("/f", "pull")
    assert.is_false(ok)
    assert.truthy(why:find("running on it", 1, true), why)
    assert.is_true(state.acquire("/d", "pull"))
    assert.is_true(state.acquire("/x", "fetch"))
    ok, why = state.acquire("/d", "push")
    assert.is_false(ok, "the lock taken above still holds")
    assert.truthy(why:find("pull already running", 1, true), why)

    assert.same({ total = 4, pending = 1, fetching = 1, done = 1, failed = 1 }, state.counts())
    state.end_bulk()
    assert.is_nil(state.phase("/p"))
    assert.is_nil(state.bulk_verb())
    assert.equals("pull", state.holder("/d"), "ending the bulk leaves locks to their holders")
  end)

  it("a stale bulk's callbacks touch neither the phases nor the end of a newer bulk", function()
    local first = state.begin_bulk("fetch", { "/a", "/b" })
    state.set_phase("/a", "fetching", first)
    local second = state.begin_bulk("pull", { "/b", "/c" })
    assert.is_not.equal(first, second)

    state.set_phase("/a", "done", first)
    state.set_phase("/b", "done", first)
    assert.is_nil(state.phase("/a"), "the first bulk no longer writes phases")
    assert.equals("pending", state.phase("/b"))
    assert.is_false(state.end_bulk(first), "the first bulk cannot end the second")
    assert.equals("pull", state.bulk_verb())
    assert.equals("pending", state.phase("/c"))

    state.set_phase("/b", "done", second)
    assert.equals("done", state.phase("/b"))
    assert.is_true(state.end_bulk(second))
    assert.is_nil(state.bulk_verb())
  end)
end)

describe("gitsuite.features.dashboard.view: bulk does not block settled rows", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { "gitsuite.util.notify", "notify", "success" },
    { "gitsuite.util.progress", "create" },
    { "gitsuite.features.dashboard.actions", "fetch", "pull", "push", "sync" },
    { "gitsuite.features.dashboard.status", "dashboard_one", "scan" },
    { "ui.kit", "confirm" },
  })

  local view, state, actions
  local messages
  -- Fake git: calls waiting to be completed, calls per verb, and the
  -- concurrency high-water marks per repository and overall.
  local waiting, calls, inflight, max_same_repo, max_total, total_inflight

  local function record(name)
    return {
      name = name,
      path = "/fake/" .. name,
      branch = "main",
      ahead = 0,
      behind = 0,
      has_upstream = true,
      dirty = 0,
      state = "clean",
    }
  end

  ---A fake async git action: counts concurrency and waits for `release`.
  ---@param verb string
  ---@param delay_ms integer|nil Complete by itself after this delay (nil: by hand)
  ---@param fails table<string, boolean>|nil Paths whose call fails
  local function fake(verb, delay_ms, fails)
    return function(path, on_done)
      calls[#calls + 1] = verb .. " " .. path
      inflight[path] = (inflight[path] or 0) + 1
      total_inflight = total_inflight + 1
      max_same_repo = math.max(max_same_repo, inflight[path])
      max_total = math.max(max_total, total_inflight)
      local function complete(ok)
        inflight[path] = inflight[path] - 1
        total_inflight = total_inflight - 1
        on_done(ok, (not ok) and (verb .. " exploded") or nil)
      end
      if delay_ms then
        vim.defer_fn(function()
          complete(not (fails and fails[path]))
        end, delay_ms)
      else
        waiting[verb .. " " .. path] = complete
      end
    end
  end

  local function release(key, ok)
    local complete = waiting[key]
    assert.is_not_nil(complete, "no call waiting: " .. key)
    waiting[key] = nil
    complete(ok)
  end

  local function bufnr()
    return vim.fn.bufnr("gitsuite://dashboard")
  end

  local function press(lhs, line)
    if line then vim.api.nvim_win_set_cursor(0, { line, 0 }) end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr(), "n")) do
      if m.lhs == lhs then
        m.callback()
        return
      end
    end
    error("no dashboard mapping for " .. lhs)
  end

  local function wait_for(pred, what)
    assert.is_true(vim.wait(2000, pred, 5), "timed out waiting for " .. what)
  end

  local function last_message()
    return messages[#messages] or ""
  end

  local function row_text(name)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr(), 0, -1, false)) do
      if l:find(name, 1, true) then return l end
    end
    return ""
  end

  before_each(function()
    messages, waiting, calls, inflight = {}, {}, {}, {}
    max_same_repo, max_total, total_inflight = 0, 0, 0
    -- The interleavings below are pinned down for one fetch at a time; the
    -- parallel fetch has its own cases.
    require("gitsuite.config").setup({ dashboard = { fetch_jobs = 1 } })

    local notify_mod = require("gitsuite.util.notify")
    notify_mod.notify = function(msg)
      messages[#messages + 1] = msg
    end
    notify_mod.success = notify_mod.notify
    require("gitsuite.util.progress").create = function()
      return nil
    end
    require("ui.kit").confirm = function(o)
      o.on_answer(true)
    end
    -- The row re-read: an instant fake record, no git process.
    require("gitsuite.features.dashboard.status").dashboard_one = function(path, on_done)
      on_done(record(vim.fn.fnamemodify(path, ":t")))
    end

    package.loaded["gitsuite.features.dashboard.repo_state"] = nil
    package.loaded["gitsuite.features.dashboard.view"] = nil
    state = require("gitsuite.features.dashboard.repo_state")
    view = require("gitsuite.features.dashboard.view")
    actions = require("gitsuite.features.dashboard.actions")
  end)

  after_each(function()
    state.reset()
    local buf = bufnr()
    if buf ~= -1 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end)

  it("refuses unsettled rows, runs a settled row in parallel, never two calls per repo", function()
    actions.fetch = fake("fetch")
    actions.pull = fake("pull")
    view.show({ record("r1"), record("r2"), record("r3") }, { output = "buffer" })

    press("gf")
    assert.equals("fetching", state.phase("/fake/r1"))
    assert.equals("pending", state.phase("/fake/r2"))
    assert.truthy(row_text("r2"):find("fetch queued", 1, true), row_text("r2"))
    assert.truthy(row_text("r1"):find("fetch...", 1, true), row_text("r1"))
    assert.truthy(view.summary({}):find("fetch 0/3", 1, true), view.summary({}))

    -- r2 is still queued, r1 is being fetched: both refuse, nothing starts.
    press("P", 3)
    assert.truthy(last_message():find("r2: still queued", 1, true), last_message())
    press("P", 2)
    assert.truthy(last_message():find("r1: the bulk fetch is running on it", 1, true))
    assert.same({ "fetch /fake/r1" }, calls)

    release("fetch /fake/r1", true)
    wait_for(function()
      return state.phase("/fake/r1") == "done" and state.phase("/fake/r2") == "fetching"
    end, "r1 done, r2 fetching")

    -- r1 is done: its pull runs while the bulk still fetches r2.
    press("P", 2)
    assert.same({ "fetch /fake/r1", "fetch /fake/r2", "pull /fake/r1" }, calls)
    assert.equals(2, max_total, "the pull ran alongside the bulk fetch")
    assert.truthy(row_text("r1"):find("pull...", 1, true), row_text("r1"))

    -- The lock: a second action on r1 while its pull runs is refused.
    press("f", 2)
    assert.truthy(last_message():find("r1: pull already running", 1, true), last_message())

    release("fetch /fake/r2", false)
    wait_for(function()
      return state.phase("/fake/r2") == "failed"
    end, "r2 failed")
    assert.truthy(row_text("r2"):find("fetch failed", 1, true), row_text("r2"))
    assert.truthy(view.summary({}):find("fetch 2/3", 1, true), view.summary({}))

    release("pull /fake/r1", true)
    release("fetch /fake/r3", true)
    wait_for(function()
      return state.bulk_verb() == nil and state.holder("/fake/r1") == nil
    end, "bulk and pull finished")

    assert.equals(1, max_same_repo, "never two git calls on one repository at once")
    local joined = table.concat(messages, "\n")
    assert.truthy(joined:find("fetch: 1 of 3 failed", 1, true), joined)
    assert.truthy(joined:find("r2: fetch exploded", 1, true), joined)
    assert.is_nil(row_text("r2"):find("failed", 1, true), "phases are gone after the bulk")
  end)

  it("with simulated delays and a failing repository every row settles", function()
    actions.fetch = fake("fetch", 30, { ["/fake/r2"] = true })
    actions.pull = fake("pull", 30)
    view.show({ record("r1"), record("r2"), record("r3"), record("r4") }, { output = "buffer" })

    press("gf")
    wait_for(function()
      return state.phase("/fake/r1") == "done"
    end, "r1 done")
    assert.is_not.equal("done", state.phase("/fake/r4"), "the bulk is still running")
    press("P", 2)
    assert.equals("pull /fake/r1", calls[#calls])

    wait_for(function()
      return state.bulk_verb() == nil and state.holder("/fake/r1") == nil
    end, "everything finished")
    assert.equals(1, max_same_repo)
    assert.equals(2, max_total)
    local joined = table.concat(messages, "\n")
    assert.truthy(joined:find("fetch: 1 of 4 failed", 1, true), joined)
    assert.truthy(joined:find("r1: pull done", 1, true), joined)
  end)

  it("the bulk waits for a repository somebody else holds the lock of", function()
    actions.fetch = fake("fetch")
    view.show({ record("r1"), record("r2") }, { output = "buffer" })

    press("gf")
    assert.is_true(state.try_lock("/fake/r2", "other"))
    release("fetch /fake/r1", true)
    vim.wait(300, function()
      return false
    end)
    assert.same({ "fetch /fake/r1" }, calls, "r2 is not fetched while locked")
    assert.equals("pending", state.phase("/fake/r2"))

    state.unlock("/fake/r2")
    wait_for(function()
      return waiting["fetch /fake/r2"] ~= nil
    end, "r2 fetch to start")
    release("fetch /fake/r2", true)
    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")
  end)

  it("gf runs dashboard.fetch_jobs fetches at once, in row order, and settles every row", function()
    require("gitsuite.config").setup({ dashboard = { fetch_jobs = 2 } })
    actions.fetch = fake("fetch")
    view.show({ record("r1"), record("r2"), record("r3"), record("r4") }, { output = "buffer" })

    press("gf")
    assert.same({ "fetch /fake/r1", "fetch /fake/r2" }, calls)
    assert.equals("pending", state.phase("/fake/r3"))

    -- r2 finishing first frees a slot for r3 while r1 is still running.
    release("fetch /fake/r2", true)
    wait_for(function()
      return waiting["fetch /fake/r3"] ~= nil
    end, "r3 fetch to start")
    assert.equals("fetching", state.phase("/fake/r1"))
    release("fetch /fake/r1", false)
    wait_for(function()
      return waiting["fetch /fake/r4"] ~= nil
    end, "r4 fetch to start")
    assert.truthy(view.summary({}):find("fetch 2/4", 1, true), view.summary({}))
    release("fetch /fake/r3", true)
    release("fetch /fake/r4", true)
    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")

    assert.equals(2, max_total, "never more than fetch_jobs at once")
    assert.equals(1, max_same_repo)
    local joined = table.concat(messages, "\n")
    assert.truthy(joined:find("fetch: 1 of 4 failed", 1, true), joined)
  end)

  it(
    "gS syncs every repository, dashboard.fetch_jobs at once, and lists the one that failed",
    function()
      require("gitsuite.config").setup({ dashboard = { fetch_jobs = 2 } })
      actions.sync = fake("sync")
      -- Marks are ignored, as with the other g-forms: nothing is marked here, and all four are synced.
      view.show({ record("r1"), record("r2"), record("r3"), record("r4") }, { output = "buffer" })

      press("gS")
      assert.same({ "sync /fake/r1", "sync /fake/r2" }, calls)
      assert.equals("pending", state.phase("/fake/r3"))
      assert.equals("sync", state.bulk_verb())

      release("sync /fake/r2", true)
      wait_for(function()
        return waiting["sync /fake/r3"] ~= nil
      end, "r3 sync to start")
      release("sync /fake/r1", false)
      wait_for(function()
        return waiting["sync /fake/r4"] ~= nil
      end, "r4 sync to start")
      release("sync /fake/r3", true)
      release("sync /fake/r4", true)
      wait_for(function()
        return state.bulk_verb() == nil
      end, "bulk finished")

      assert.equals(2, max_total, "never more than fetch_jobs at once")
      assert.equals(1, max_same_repo)
      local joined = table.concat(messages, "\n")
      assert.truthy(joined:find("sync: 1 of 4 failed", 1, true), joined)
      assert.truthy(joined:find("r1: sync exploded", 1, true), joined)
    end
  )

  it("gS ends with a summary: per repository what happened, unchanged ones counted", function()
    require("gitsuite.config").setup({ dashboard = { fetch_jobs = 4 } })
    -- What each fake sync reports; r2 and r5 are level and must only be counted.
    local outcome = {
      r1 = { true, nil, "pulled 3 commits" },
      r2 = { true },
      r3 = { false, "diverged: 1 ahead, 2 behind - neither pulled nor pushed" },
      r4 = { true, nil, nil, "no upstream or detached HEAD" },
      r5 = { true },
      r6 = { true, nil, "pushed 1 commit" },
    }
    actions.sync = function(path, on_done)
      local o = outcome[vim.fn.fnamemodify(path, ":t")]
      -- Finishing in reverse order must not reorder the summary.
      vim.defer_fn(function()
        on_done(o[1], o[2], o[3], o[4])
      end, path:find("r1", 1, true) and 60 or 5)
    end
    local list = {}
    for i = 1, 6 do
      list[i] = record("r" .. i)
    end
    view.show(list, { output = "buffer" })

    press("gS")
    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")

    local msg = last_message()
    assert.truthy(msg:find("sync: 1 of 6 failed, 2 changed, 1 skipped, 2 unchanged", 1, true), msg)
    local want = table.concat({
      "Failed:",
      "  r3: diverged: 1 ahead, 2 behind - neither pulled nor pushed",
      "Changed:",
      "  r1: pulled 3 commits",
      "  r6: pushed 1 commit",
      "Skipped:",
      "  r4: no upstream or detached HEAD",
    }, "\n")
    assert.truthy(msg:find(want, 1, true), msg)
    assert.is_nil(msg:find("r2", 1, true), "unchanged repositories are only counted")
    assert.is_nil(msg:find("r5", 1, true), "unchanged repositories are only counted")
  end)

  it("gS asks before it starts, and an answer of no starts nothing", function()
    actions.sync = fake("sync")
    local question
    require("ui.kit").confirm = function(o)
      question = o.question
      o.on_answer(false)
    end
    view.show({ record("r1"), record("r2") }, { output = "buffer" })

    press("gS")
    assert.truthy(question and question:find("Sync 2 repositories", 1, true), question)
    assert.same({}, calls)
    assert.is_nil(state.bulk_verb())
  end)

  it("gS has a description, which is what the ? help lists", function()
    view.show({ record("r1") }, { output = "buffer" })
    local desc
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr(), "n")) do
      if m.lhs == "gS" then desc = m.desc end
    end
    assert.truthy(desc and desc:find("Sync every repository", 1, true), tostring(desc))
  end)

  it("push stays one at a time whatever fetch_jobs says", function()
    require("gitsuite.config").setup({ dashboard = { fetch_jobs = 4 } })
    actions.push = fake("push")
    view.show({ record("r1"), record("r2"), record("r3") }, { output = "buffer" })

    press("gp")
    wait_for(function()
      return #calls > 0
    end, "first push")
    assert.equals(1, #calls)
    assert.equals(1, max_total)
    for _, key in ipairs(vim.tbl_keys(waiting)) do
      release(key, true)
    end
    wait_for(function()
      return #calls == 2
    end, "second push")
    for _, key in ipairs(vim.tbl_keys(waiting)) do
      release(key, true)
    end
    wait_for(function()
      return #calls == 3
    end, "third push")
    for _, key in ipairs(vim.tbl_keys(waiting)) do
      release(key, true)
    end
    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")
    assert.equals(1, max_total)
  end)

  -- GS: gitsuite.nvim/dashboard-zweiter-lauf-haengt -- close the dashboard while
  -- a batch still runs, open it again (a fresh scan, a fresh buffer): the new
  -- dashboard takes the running batch over instead of starting a second one,
  -- and every one of its rows settles once that batch is through.
  it("a dashboard reopened mid-batch follows the running batch and settles every row", function()
    actions.fetch = fake("fetch", 30)
    view.show({ record("r1"), record("r2"), record("r3") }, { output = "buffer" })

    press("gf")
    wait_for(function()
      return state.phase("/fake/r1") == "done"
    end, "r1 done")

    -- Closing the popup wipes its buffer; reopening scans again into a new one.
    vim.api.nvim_buf_delete(bufnr(), { force = true })
    view.show({ record("r1"), record("r2"), record("r3") }, { output = "buffer" })
    assert.truthy(row_text("r3"):find("fetch queued", 1, true), row_text("r3"))

    -- No second batch on top of the running one.
    press("gf")
    assert.truthy(last_message():find("already running", 1, true), last_message())

    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")
    assert.same({ "fetch /fake/r1", "fetch /fake/r2", "fetch /fake/r3" }, calls)
    for _, name in ipairs({ "r1", "r2", "r3" }) do
      local row = row_text(name)
      assert.is_nil(row:find("queued", 1, true), row)
      assert.is_nil(row:find("fetch...", 1, true), row)
      assert.truthy(row:find("clean", 1, true), row)
    end
  end)

  -- The reopened dashboard's own scan runs alongside the batch: a repository it
  -- read before the batch's fetch of it landed carries the state from before
  -- that fetch. The batch's re-read of it is newer and must win, or the row
  -- shows "nothing behind" for good although the fetch just found new commits.
  it("a dashboard reopened mid-batch keeps the re-reads its own scan raced", function()
    actions.fetch = fake("fetch")
    -- After the fetch the remote has moved on: every re-read is two behind.
    require("gitsuite.features.dashboard.status").dashboard_one = function(path, on_done)
      local r = record(vim.fn.fnamemodify(path, ":t"))
      r.behind = 2
      on_done(r)
    end
    -- The view binds `dashboard_one` when it is loaded.
    package.loaded["gitsuite.features.dashboard.view"] = nil
    view = require("gitsuite.features.dashboard.view")
    view.show({ record("r1"), record("r2") }, { output = "buffer" })
    press("gf")
    vim.api.nvim_buf_delete(bufnr(), { force = true })

    -- `:Git dashboard` again: its scan is in flight while r1's fetch lands.
    local scanned
    require("gitsuite.features.dashboard.status").scan = function(_, on_done)
      scanned = on_done
    end
    require("gitsuite.features.dashboard").show(nil, "buffer")
    assert.is_not_nil(scanned, "the reopened dashboard scans")
    -- The scan read both repositories before the fetch moved anything.
    local scan_result = { record("r1"), record("r2") }
    release("fetch /fake/r1", true)
    wait_for(function()
      return state.phase("/fake/r1") == "done" and waiting["fetch /fake/r2"] ~= nil
    end, "r1 done")
    scanned(scan_result, {})
    assert.truthy(row_text("r1"):find("↓2", 1, true), row_text("r1"))

    release("fetch /fake/r2", true)
    wait_for(function()
      return state.bulk_verb() == nil
    end, "bulk finished")
    for _, name in ipairs({ "r1", "r2" }) do
      assert.truthy(row_text(name):find("↓2", 1, true), row_text(name))
    end
  end)

  local function line_of(name)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr(), 0, -1, false)) do
      if l:find(name, 1, true) then return i end
    end
    error("no row for " .. name)
  end

  -- GS: gitsuite.nvim/dashboard-zeilenaktions-spinner-per-index-statt-per-pfad-fal
  -- -- a row action's spinner belongs to its repository, not to its row: a
  -- dashboard opened again (fresh scan, discovery order) while the action runs
  -- shows it on that repository and lets every other row run its own action.
  it("a row action's spinner follows its repository into a reopened dashboard", function()
    actions.pull = fake("pull")
    view.show({ record("rc"), record("ra"), record("rb") }, { output = "buffer" })
    press("s") -- by name: ra, rb, rc
    press("P", line_of("rc"))
    assert.same({ "pull /fake/rc" }, calls)

    vim.api.nvim_buf_delete(bufnr(), { force = true })
    view.show({ record("rc"), record("ra"), record("rb") }, { output = "buffer" })
    assert.truthy(row_text("rc"):find("pull...", 1, true), row_text("rc"))
    assert.is_nil(row_text("rb"):find("pull...", 1, true), row_text("rb"))

    press("P", line_of("rb"))
    assert.same({ "pull /fake/rc", "pull /fake/rb" }, calls)

    release("pull /fake/rc", true)
    release("pull /fake/rb", true)
    wait_for(function()
      return state.holder("/fake/rc") == nil and state.holder("/fake/rb") == nil
    end, "both pulls finished")
    for _, name in ipairs({ "ra", "rb", "rc" }) do
      assert.is_nil(row_text(name):find("pull...", 1, true), row_text(name))
    end
  end)

  -- Same task: after a page switch the rows on screen were a copy of the page's
  -- scan, so a re-read and a re-sort changed only the copy and `reopen()` (back
  -- from a README) showed the stale, unsorted scan.
  it("reopen after a page switch shows the re-read and sorted rows", function()
    require("gitsuite.features.dashboard.status").dashboard_one = function(path, on_done)
      local r = record(vim.fn.fnamemodify(path, ":t"))
      r.behind = 2
      on_done(r)
    end
    package.loaded["gitsuite.features.dashboard.view"] = nil
    view = require("gitsuite.features.dashboard.view")
    view.show({ record("r1") }, {
      output = "buffer",
      pages = { { name = "one" }, { name = "two" } },
      page_index = 1,
      on_switch_page = function(_, on_done)
        on_done({ record("rc"), record("ra"), record("rb") }, {})
      end,
    })
    press("<Right>")
    wait_for(function()
      return row_text("rc") ~= ""
    end, "page two loaded")
    press("s") -- by name: ra, rb, rc
    press("r", line_of("rb"))
    wait_for(function()
      return row_text("rb"):find("↓2", 1, true) ~= nil
    end, "rb re-read")

    vim.api.nvim_buf_delete(bufnr(), { force = true })
    assert.is_true(view.reopen())
    assert.equals(2, line_of("ra"))
    assert.equals(4, line_of("rc"))
    assert.truthy(row_text("rb"):find("↓2", 1, true), row_text("rb"))
  end)
end)

-- GS: gitsuite.nvim/git-dashboard-startablauf-optimieren -- the popup used to
-- open only once every repository had been read; now it opens first and
-- fills in as each one resolves.
describe("gitsuite.features.dashboard.view: live popup", function()
  local view

  before_each(function()
    package.loaded["gitsuite.features.dashboard.view"] = nil
    package.loaded["gitsuite.features.dashboard.repo_state"] = nil
    view = require("gitsuite.features.dashboard.view")
    require("gitsuite.features.dashboard.repo_state").reset()
  end)

  after_each(function()
    pcall(view.live_abort)
  end)

  ---@param name string
  ---@param overrides table|nil
  local function rec(name, overrides)
    return vim.tbl_extend("force", {
      name = name,
      path = "/fake/" .. name,
      branch = "main",
      ahead = 0,
      behind = 0,
      has_upstream = true,
      dirty = 0,
      state = "clean",
      last_commit = nil,
    }, overrides or {})
  end

  ---The live popup's window, found by its filetype rather than by whatever
  ---happens to be the current window -- the same lookup `show_popup`'s reuse
  ---path has to survive, since nothing here pins the window as "current".
  ---@return integer|nil
  local function dashboard_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "gitsuite-dashboard" then return win end
    end
    return nil
  end

  it("is a no-op for every output mode but popup", function()
    assert.is_false(view.live_begin("buffer"))
    assert.is_false(view.live_begin("split"))
    assert.is_false(view.live_begin("clipboard"))
    assert.is_nil(dashboard_win())
    -- Nowhere to write to, must not raise.
    view.live_discover({ "/fake/r1" })
    view.live_record("/fake/r1", rec("r1"), nil)
  end)

  it(
    "opens before any repository is known, fills in as each one resolves, "
      .. "and show() reuses its window for the final table",
    function()
      assert.is_true(view.live_begin("popup"))
      local winid = dashboard_win()
      assert.is_not_nil(winid, "the live popup opened a window")
      local bufnr = vim.api.nvim_win_get_buf(winid)
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
      end

      assert.is_nil(text():find("r1", 1, true), "nothing is known yet: " .. text())
      local narrow_width = vim.api.nvim_win_get_config(winid).width

      view.live_discover({ "/fake/r1", "/fake/r2" })
      assert.truthy(text():find("r1", 1, true), text())
      assert.truthy(text():find("r2", 1, true), text())
      assert.truthy(text():find("scanning", 1, true), text())
      -- Sized for the final row count right away (header + 2 rows, +1 for
      -- the winbar legend): nothing still unread can grow the table
      -- lengthwise once it does come back.
      assert.equals(4, vim.api.nvim_win_get_config(winid).height)
      -- Regression: the window used to stay sized for its one-line
      -- "Scanning repositories ..." placeholder forever -- wide enough for
      -- that short line, but not for the table, which goes on growing while
      -- every row stayed clipped to a sliver of the real table.
      local discover_width = vim.api.nvim_win_get_config(winid).width
      assert.is_true(
        discover_width > narrow_width,
        ("table (width %d) must be wider than the placeholder (width %d)"):format(
          discover_width,
          narrow_width
        )
      )
      for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        assert.is_true(
          vim.fn.strdisplaywidth(line) <= discover_width - 2,
          ("line clipped by the window: %q wider than width %d"):format(line, discover_width)
        )
      end

      view.live_record("/fake/r1", rec("r1"), nil)
      assert.is_nil(text():match("r1[^\n]*scanning"), "r1's placeholder is gone: " .. text())
      assert.truthy(text():match("r2[^\n]*scanning"), "r2 is still unresolved: " .. text())

      -- A long branch name on a resolved row must widen the window again --
      -- the row count was fixed at discovery, but no single row's own width
      -- was, since that depends on data read AFTER discovery.
      local long_branch = "claude/" .. ("x"):rep(40)
      view.live_record("/fake/r2", rec("r2", { branch = long_branch }), nil)
      -- `_elide_middle` keeps the head and cuts the middle, so only a short
      -- head prefix is guaranteed to survive verbatim.
      assert.truthy(text():find(long_branch:sub(1, 10), 1, true), text())
      local widened = vim.api.nvim_win_get_config(winid).width
      assert.is_true(
        widened > discover_width,
        ("window (width %d) must widen for the long branch (was %d)"):format(
          widened,
          discover_width
        )
      )
      for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        assert.is_true(
          vim.fn.strdisplaywidth(line) <= widened - 2,
          ("line clipped by the window: %q wider than width %d"):format(line, widened)
        )
      end

      local win_count = #vim.api.nvim_list_wins()
      view.show({ rec("r1"), rec("r2") }, { output = "popup" })

      assert.equals(winid, dashboard_win(), "the live window is reused, not replaced")
      assert.equals(win_count, #vim.api.nvim_list_wins(), "no second popup was stacked on top")
      assert.is_nil(text():find("scanning", 1, true), "the final table replaced the placeholders")
      assert.truthy(text():find("r1", 1, true), text())

      vim.api.nvim_win_close(winid, true)
    end
  )
end)

-- GS: gitsuite.nvim/dashboard-kontextmenue -- <RightMouse> on the dashboard
-- opens a menu built from the same ROW_KEYMAPS entries the keys run, acting
-- on the marked set when one exists, otherwise the row under the mouse
-- pointer (not wherever the cursor happened to be).
describe("gitsuite.features.dashboard.view: context menu", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { "lib.nvim.contextmenu", "bind_buffer" },
    { vim.fn, "getmousepos", "mode", "line" },
  })

  local view, state, config
  local captured_get_items

  local function rec(name, overrides)
    return vim.tbl_extend("force", {
      name = name,
      path = "/fake/" .. name,
      branch = "main",
      ahead = 0,
      behind = 0,
      has_upstream = true,
      dirty = 0,
      state = "clean",
      last_commit = nil,
    }, overrides or {})
  end

  local function bufnr()
    return vim.fn.bufnr("gitsuite://dashboard")
  end

  ---Names of every non-heading, non-separator item, in order.
  ---@param items table[]
  local function item_names(items)
    local names = {}
    for _, item in ipairs(items) do
      if not item.__heading and not item.separator then names[#names + 1] = item.name end
    end
    return names
  end

  ---The item named `name`, or nil.
  local function find_item(items, name)
    for _, item in ipairs(items) do
      if item.name == name then return item end
    end
    return nil
  end

  before_each(function()
    captured_get_items = nil
    require("lib.nvim.contextmenu").bind_buffer = function(_, get_items, _opts)
      captured_get_items = get_items
    end

    package.loaded["gitsuite.features.dashboard.view"] = nil
    package.loaded["gitsuite.features.dashboard.repo_state"] = nil
    state = require("gitsuite.features.dashboard.repo_state")
    state.reset()
    view = require("gitsuite.features.dashboard.view")
    config = require("gitsuite.config")
    config.setup({})
  end)

  after_each(function()
    state.reset()
    local buf = bufnr()
    if buf ~= -1 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    config.setup({})
  end)

  it("binds a get_items provider by default", function()
    view.show({ rec("r1") }, { output = "buffer" })
    assert.is_function(captured_get_items)
  end)

  it("does not bind at all when dashboard.context_menu = false", function()
    config.setup({ dashboard = { context_menu = false } })
    view.show({ rec("r1") }, { output = "buffer" })
    assert.is_nil(captured_get_items)
  end)

  it("a click on a row moves the cursor there and offers that repository's own actions", function()
    view.show({ rec("r1"), rec("r2") }, { output = "buffer" })
    -- Line 1 is the header, so line 3 is r2's row (see `_mark_rows`'s own doc).
    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 3, column = 1 }
    end
    vim.fn.mode = function()
      return "n"
    end

    local items = captured_get_items()

    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1], "cursor moved to the clicked row")
    local names = item_names(items)
    for _, expected in ipairs({ "Open", "Push", "Pull", "Fetch", "Status", "Mark" }) do
      assert.truthy(
        vim.tbl_contains(names, expected),
        expected .. " missing: " .. vim.inspect(names)
      )
    end
    assert.is_nil(find_item(items, "Clear marks"), "no marks: nothing to clear")
    -- The heading names the target.
    assert.equals("r2", items[1].name)
    assert.truthy(vim.tbl_contains(names, "Fetch all"), "whole-dashboard group is always offered")
  end)

  it("a locked/running repository's row actions name the reason instead of the key hint", function()
    view.show({ rec("r1") }, { output = "buffer" })
    state.begin_bulk("fetch", { "/fake/r1" })
    state.set_phase("/fake/r1", "fetching")

    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 2, column = 1 }
    end
    vim.fn.mode = function()
      return "n"
    end

    local items = captured_get_items()
    local fetch_item = find_item(items, "Fetch")
    assert.is_not_nil(fetch_item)
    assert.truthy(fetch_item.rtxt:find("running", 1, true), fetch_item.rtxt)
    assert.is_not_nil(fetch_item.hl, "a busy row's action is visually muted")
  end)

  it("marked repositories: bulk actions only, heading names the count", function()
    view.show({ rec("r1"), rec("r2"), rec("r3") }, { output = "buffer" })
    -- Mark r1 and r2 through the real `m` key, exactly as a user would.
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr(), "n")) do
      if m.lhs == "m" then
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        m.callback()
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        m.callback()
      end
    end

    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 4, column = 1 }
    end
    vim.fn.mode = function()
      return "n"
    end

    local items = captured_get_items()
    assert.equals("2 marked repositories", items[1].name)
    local names = item_names(items)
    assert.same({
      "Push",
      "Pull",
      "Fetch",
      "Clear marks",
      "Fetch all",
      "Pull all…",
      "Push all",
      "Update all",
      "Sync all",
    }, names)
  end)

  it("a Visual selection at click time is converted to marks first", function()
    view.show({ rec("r1"), rec("r2"), rec("r3") }, { output = "buffer" })
    vim.fn.mode = function()
      return "v"
    end
    vim.fn.line = function(what)
      return what == "v" and 2 or 3 -- lines 2..3: r1 and r2
    end

    local items = captured_get_items()
    assert.equals("2 marked repositories", items[1].name)

    -- The marks it produced persist like any other mark: a later click in
    -- Normal mode still sees them, regardless of where it lands.
    vim.fn.mode = function()
      return "n"
    end
    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 4, column = 1 }
    end
    local later = captured_get_items()
    assert.equals("2 marked repositories", later[1].name)
  end)
end)
