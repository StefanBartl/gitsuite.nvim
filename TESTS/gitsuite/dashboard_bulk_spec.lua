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
end)

describe("gitsuite.features.dashboard.view: bulk does not block settled rows", function()
  local G = dofile(dir_of_spec .. "spec_guard.lua")()
  G.install({
    { "gitsuite.util.notify", "notify", "success" },
    { "gitsuite.util.progress", "create" },
    { "gitsuite.features.dashboard.actions", "fetch", "pull", "push" },
    { "gitsuite.features.dashboard.status", "dashboard_one" },
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
end)
