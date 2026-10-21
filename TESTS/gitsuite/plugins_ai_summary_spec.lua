-- TESTS/gitsuite/plugins_ai_summary_spec.lua -- the optional AI summary of a plugin's update:
-- the `plugins.summarize` hook, the digest it gets, the labelled answer.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.

local NOW = 1790000000

local function entry(subjects, bodies)
  local commits = {}
  for i, s in ipairs(subjects) do
    commits[i] = {
      sha = ("%040x"):format(i),
      subject = s,
      body = bodies and bodies[i] or "",
      author = "Alice",
      time = NOW - i * 60,
      side = ">",
    }
  end
  return {
    name = "demo.nvim",
    dir = "/secret/place/demo.nvim",
    status = "forward",
    order = "topo",
    commits = commits,
  }
end

local function report(plugins)
  return {
    version = 1,
    id = "r-ai-1",
    at = NOW,
    mode = "updated",
    plugins = plugins,
    heads = {},
    counts = { checked = #plugins, changed = #plugins, commits = 3, unchanged = 0 },
    errors = {},
  }
end

describe("gitsuite.features.plugins.ai_summary", function()
  local AI, config, state, store
  local bufs = {}

  local function scratch()
    local b = vim.api.nvim_create_buf(false, true)
    bufs[#bufs + 1] = b
    return b
  end

  before_each(function()
    for _, m in ipairs({ "ai_summary", "markdown", "state" }) do
      package.loaded["gitsuite.features.plugins." .. m] = nil
    end
    config = require("gitsuite.config")
    config.setup({})
    AI = require("gitsuite.features.plugins.ai_summary")
    state = require("gitsuite.features.plugins.state")
    store = vim.fn.tempname() .. "_reports.json"
  end)

  after_each(function()
    config.setup({})
    pcall(vim.uv.fs_unlink, store)
    for _, b in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    bufs = {}
  end)

  it("is off by default: no hook, no key", function()
    assert.is_nil(AI.hook())
    local buf = scratch()
    assert.is_false(AI.attach(buf, report({}), function() end))
    assert.are.same({}, vim.api.nvim_buf_get_keymap(buf, "n"))
    assert.is_nil(package.loaded["ai"], "nothing required an AI plugin")
  end)

  it("takes a function or false, nothing else", function()
    config.setup({ plugins = { summarize = "yes" } })
    assert.is_nil(AI.hook())
    assert.is_true(#config.issues() > 0)
    config.setup({ plugins = { summarize = function() end } })
    assert.is_function(AI.hook())
    config.setup({ plugins = { summarize = false } })
    assert.is_nil(AI.hook())
  end)

  it("maps the key only with a hook", function()
    config.setup({ plugins = { summarize = function() end, summarize_key = "gX" } })
    local buf = scratch()
    assert.is_true(AI.attach(buf, report({}), function() end))
    local found
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == "gX" then found = map end
    end
    assert.is_truthy(found, "the configured key is mapped in the buffer")
  end)

  describe("digest", function()
    it("is marked untrusted and carries only the flagged commits' messages", function()
      local e = entry(
        { "feat!: drop the old api", "fix: typo", "chore: bump", "refactor!: rename" },
        { "BREAKING CHANGE: gone\n" .. ("x"):rep(2000), "secret body of a fix", "", "" }
      )
      local d = assert(AI.digest(e))
      assert.is_true(d.untrusted)
      assert.is_string(d.note)
      assert.are.equal("demo.nvim", d.plugin)
      assert.are.equal(4, d.commit_count)
      local subjects = {}
      for _, c in ipairs(d.commits) do
        subjects[#subjects + 1] = c.subject
        assert.is_true(#c.body <= AI.MAX_BODY + 4, "a body is cut")
      end
      table.sort(subjects)
      assert.are.same({ "feat!: drop the old api", "refactor!: rename" }, subjects)
      local flat = vim.inspect(d)
      assert.is_nil(flat:find("secret body", 1, true), "an unflagged commit's body is not sent")
      assert.is_nil(flat:find("/secret/place", 1, true), "no path of this machine")
    end)

    it("cleans control characters of commit text", function()
      local e = entry({ "feat!: x\27[31m red" }, { "line\0one\27]0;title\7" })
      local d = assert(AI.digest(e))
      local c = d.commits[1]
      assert.is_nil(c.subject:find("\27", 1, true))
      assert.is_nil(c.body:find("[%z\1-\8\11-\31\127]"))
    end)

    it("says why there is nothing to digest", function()
      local d, err = AI.digest({ name = "x", commits = {} })
      assert.is_nil(d)
      assert.is_string(err)
    end)

    it("is capped in size", function()
      local subjects = {}
      for i = 1, 100 do
        subjects[i] = "feat!: break " .. i
      end
      local d = assert(AI.digest(entry(subjects)))
      assert.are.equal(AI.MAX_COMMITS, #d.commits)
      assert.are.equal(100 - AI.MAX_COMMITS, d.commits_omitted)
    end)
  end)

  describe("request", function()
    local function run(hook, e)
      config.setup({ plugins = { summarize = hook } })
      local rep = report({ e or entry({ "feat!: drop x", "fix: y", "chore: z" }) })
      assert(state.add(rep, { keep_reports = 20, max_age_days = 365 }, store))
      local got, got_err, finished
      AI.request(rep, "demo.nvim", {
        store_path = store,
        timeout_ms = 300,
        on_done = function(ai, err)
          got, got_err, finished = ai, err, true
        end,
      })
      vim.wait(2000, function()
        return finished
      end, 10)
      return rep, got, got_err, finished
    end

    it("stores a labelled answer on the entry and in the report store", function()
      local seen
      local rep, ai = run(function(input, done)
        seen = input
        done("Dropped the old API; update your calls.", nil, { provider = "claude" })
      end)
      assert.is_true(seen.untrusted)
      assert.are.equal("claude", ai.provider)
      assert.are.equal("Dropped the old API; update your calls.", ai.text)
      assert.is_number(ai.at)
      assert.are.equal(ai.text, rep.plugins[1].ai_summary.text)
      local loaded = state.load(store)
      assert.are.equal(1, #loaded.reports)
      assert.are.equal("claude", loaded.reports[1].plugins[1].ai_summary.provider)
    end)

    it("keeps the report where it is in the history", function()
      local older = report({ entry({ "feat!: a" }) })
      older.id, older.at = "r-older", NOW - 1000
      local cfg = { keep_reports = 20, max_age_days = 365 }
      assert(state.add(older, cfg, store))
      run(function(_, done)
        done("text", nil, { provider = "p" })
      end)
      local loaded = state.load(store)
      assert.are.equal("r-ai-1", loaded.reports[1].id, "the newer report stays first")
      assert.are.equal("r-older", loaded.reports[2].id)
    end)

    it("renders the answer as a marked quote that never becomes markup", function()
      local rep = run(function(_, done)
        done("Use `rm -rf`!\n<script>alert(1)</script>\n[x](http://evil)", nil, { provider = "p" })
      end)
      local lines = require("gitsuite.features.plugins.markdown").render(rep, NOW)
      local text = table.concat(lines, "\n")
      assert.is_truthy(text:find("**AI text** (p,", 1, true), "labelled with provider and time")
      assert.is_truthy(text:find("not verified; never executed", 1, true))
      assert.is_nil(text:find("<script>", 1, true), "markup is escaped")
      assert.is_nil(text:find("[x](", 1, true), "a link is escaped")
      for _, l in ipairs(lines) do
        if l:find("script", 1, true) then
          assert.are.equal(">", l:sub(1, 1), "the text stays inside the quote")
        end
      end
    end)

    it("reports a hook error and stores nothing", function()
      local rep, ai, err = run(function(_, done)
        done(nil, "provider down")
      end)
      assert.is_nil(ai)
      assert.are.equal("provider down", err)
      assert.is_nil(rep.plugins[1].ai_summary)
    end)

    it("survives a hook that throws or stays silent", function()
      local _, ai, err = run(function()
        error("boom")
      end)
      assert.is_nil(ai)
      assert.is_truthy(err:find("boom", 1, true))
      _, ai, err = run(function() end)
      assert.is_nil(ai)
      assert.is_truthy(err:find("in time", 1, true))
    end)

    it("answers only once", function()
      local count = 0
      local _, ai = run(function(_, done)
        done("first", nil, { provider = "p" })
        done("second", nil, { provider = "p" })
      end)
      count = count + 1
      assert.are.equal("first", ai.text)
      assert.are.equal(1, count)
    end)

    it("does nothing without a hook", function()
      config.setup({})
      local called = false
      local started = AI.request(report({ entry({ "feat!: a" }) }), "demo.nvim", {
        on_done = function()
          called = true
        end,
      })
      assert.is_false(started)
      assert.is_true(called)
    end)
  end)

  it("keeps the answer when the store is read again", function()
    local rep = report({ entry({ "feat!: a" }) })
    rep.plugins[1].ai_summary = { text = "kept", provider = "p", at = NOW }
    assert(state.add(rep, { keep_reports = 20, max_age_days = 365 }, store))
    local loaded = state.load(store)
    assert.are.equal("kept", loaded.reports[1].plugins[1].ai_summary.text)
    rep.plugins[1].ai_summary = { text = 5 }
    assert(state.add(rep, { keep_reports = 20, max_age_days = 365 }, store))
    assert.is_nil(
      state.load(store).reports[1].plugins[1].ai_summary,
      "a malformed answer is dropped"
    )
  end)
end)
