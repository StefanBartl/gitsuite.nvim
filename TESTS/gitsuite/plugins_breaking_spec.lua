-- TESTS/gitsuite/plugins_breaking_spec.lua -- gitsuite.features.plugins.breaking:
-- the four-tier classifier, the folding of repeats and parser bumps, relevance,
-- and the fixture gate over a hand-labelled corpus of real commits.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local FIXTURES = dir_of_spec .. "../fixtures/breaking/"

---@param path string
---@return table[]
local function read_jsonl(path)
  local out = {}
  local f = assert(io.open(path, "rb"), "fixture missing: " .. path)
  for line in f:lines() do
    if line ~= "" then out[#out + 1] = vim.json.decode(line) end
  end
  f:close()
  return out
end

describe("gitsuite.features.plugins.breaking", function()
  local B

  before_each(function()
    package.loaded["gitsuite.features.plugins.breaking"] = nil
    B = require("gitsuite.features.plugins.breaking")
  end)

  ---@param subject string
  ---@param body? string
  ---@param opts? table
  local function tier(subject, body, opts)
    return B.classify({ sha = string.rep("a", 40), subject = subject, body = body or "" }, opts).tier
  end

  describe("classify", function()
    it("calls type(scope)!: sure, also with several scopes", function()
      assert.are.equal("sure", tier("feat!: drop support for Nvim 0.11"))
      assert.are.equal("sure", tier("feat(prolog,problog)!: drop support"))
      assert.are.equal("sure", tier("fix(hlsplaylist,muttrc,tmux,zathurarc)!: drop support"))
    end)

    it("does not take a ! that is not right before the colon for the marker", function()
      assert.is_nil(tier("a!b: something"))
      assert.is_nil(tier("feat(rust): add !xml injection"))
      assert.is_nil(tier("fix(actions): re-set window-local(!) foldexpr"))
      assert.is_nil(tier("fix: always silent! matchdelete()"))
      assert.is_nil(tier("fix: restore cursor", "This works now! Really."))
    end)

    it("takes the footer in upper case only as sure, in any of its spellings", function()
      for _, footer in ipairs({ "BREAKING CHANGE: x", "BREAKING-CHANGE: x", "BREAKING_CHANGE: x" }) do
        assert.are.equal("sure", tier("feat: new api", "Some text.\n\n" .. footer), footer)
      end
      assert.are.equal("probable", tier("feat: new api", "Text.\n\nbreaking change: x"))
      assert.are.equal("sure", tier("BREAKING CHANGE: Async file history (#93)"))
      assert.are.equal("probable", tier("breaking: Remove neorocks."))
    end)

    it("finds a footer in a CRLF body", function()
      local body = "feat: one\r\n\r\nBREAKING CHANGE: Requires nvim-nio to be\r\ninstalled"
      assert.are.equal("sure", tier("feat: use external nio (#337)", body))
      -- lone CRs as line breaks (old Mac style): only normalization makes this a line start
      assert.are.equal("sure", tier("feat: x", "text\rBREAKING CHANGE: y"))
    end)

    it("does not count a revert, whatever it says", function()
      local v = B.classify({ subject = 'Revert "feat!: new api"', body = "BREAKING CHANGE: x" })
      assert.is_nil(v.tier)
      assert.is_true(v.revert)
      assert.is_nil(tier("revert: a247a60", "It's breaking changes at start of line"))
    end)

    it("puts a ! on a parser bump in the bulk tier, not in sure", function()
      assert.are.equal("bulk", tier("feat(kdl)!: update parser and queries"))
      assert.are.equal("bulk", tier("feat(jinja,jinja_inline)!: update parser and queries"))
      assert.is_nil(tier("feat(diff): update parser and queries"))
      -- a footer keeps it sure
      assert.are.equal("sure", tier("feat(kdl)!: update parser and queries", "BREAKING CHANGE: x"))
    end)

    it("knows the probable rules", function()
      assert.are.equal("probable", tier("Drop support for nvim-0.9.5; add support for 0.11.0"))
      assert.are.equal("probable", tier("feat: remove dependency. Requires Neovim >= 0.9.4"))
      assert.are.equal("probable", tier("fix: enable treesitter virtual text by default (#396)"))
      assert.are.equal("probable", tier("fix!(lsp): use generic_sorter"))
      assert.are.equal("probable", tier("feat(x!): something"))
      -- but not for commits that do not reach the user
      assert.is_nil(tier("docs: by default there's no automatic toggle"))
      assert.is_nil(tier("chore(ci): bump CI to Neovim 0.12 + nvim-treesitter main API"))
    end)

    it("scores hints, and a removed Lua module counts most", function()
      local v = B.classify({ subject = "Remove Get operator", body = "" })
      assert.are.equal("hint", v.tier)
      assert.are.equal(2, v.score)
      v = B.classify({ subject = "refactor: tidy", body = "", gone = { "lua/foo/bar.lua" } })
      assert.are.equal("hint", v.tier)
      assert.are.equal(3, v.score)
      assert.is_nil(tier("fix: x", "this removes a variable"))
    end)

    it("does not let 'ignorecase' change a verdict", function()
      local saved = vim.o.ignorecase
      vim.o.ignorecase = true
      local ok, err = pcall(function()
        assert.are.equal("probable", tier("feat: x", "Text.\n\nBreaking Change: y"))
        assert.is_nil(tier("Breaking the loop early"):match("sure") and "sure" or nil)
      end)
      vim.o.ignorecase = saved
      assert(ok, err)
    end)

    it("honours ignore patterns and forced commits", function()
      local sha = "0123456789abcdef0123456789abcdef01234567"
      local v = B.classify({ sha = sha, subject = "feat!: x" }, { ignore = { [[\v^feat!]] } })
      assert.is_nil(v.tier)
      assert.is_true(v.ignored)
      v = B.classify({ sha = sha, subject = "fix: harmless" }, { force = { "0123456" } })
      assert.are.equal("sure", v.tier)
      -- a prefix shorter than 7 digits is not trusted
      v = B.classify({ sha = sha, subject = "fix: harmless" }, { force = { "0123" } })
      assert.is_nil(v.tier)
      -- an invalid pattern is skipped, not raised
      v = B.classify({ sha = sha, subject = "feat!: x" }, { ignore = { [[\v(]] } })
      assert.are.equal("sure", v.tier)
    end)
  end)

  describe("relevance", function()
    local nvim = { major = 0, minor = 12, patch = 2 }

    it("says a dropped older Neovim does not affect the running one", function()
      local v = B.classify({ subject = "feat!: drop support for Nvim 0.11" }, { nvim = nvim })
      assert.is_false(v.relevance.affects)
      assert.matches("does not affect you", v.relevance.reason)
      v = B.classify({ subject = "feat!: drop support for Nvim 0.12" }, { nvim = nvim })
      assert.is_true(v.relevance.affects)
    end)

    it("checks a required Neovim against the running one", function()
      local v = B.classify({ subject = "feat!: new picker" }, { nvim = nvim })
      assert.is_nil(v.relevance)
      v = B.classify({ subject = "chore!: requires Neovim 0.13" }, { nvim = nvim })
      assert.is_true(v.relevance.affects)
      v = B.classify({ subject = "chore!: requires Neovim 0.10" }, { nvim = nvim })
      assert.is_false(v.relevance.affects)
    end)

    it("checks a parser commit against the installed parsers", function()
      local parsers = { tmux = true }
      local v = B.classify(
        { subject = "fix(hlsplaylist,muttrc,tmux,zathurarc)!: drop support" },
        { parsers = parsers, parser_plugin = true }
      )
      assert.is_true(v.relevance.affects)
      assert.are.same({ "tmux" }, v.relevance.installed)
      v = B.classify({ subject = "feat(kdl)!: update parser and queries" }, { parsers = parsers })
      assert.is_false(v.relevance.affects)
      -- a module scope of a parser plugin is no language
      v = B.classify(
        { subject = "fix(install)!: remove gitlab codepath" },
        { parsers = parsers, parser_plugin = true }
      )
      assert.is_nil(v.relevance)
    end)

    it("claims no parser is installed only when every language was checked", function()
      local function group(commits, opts)
        for _, g in ipairs(B.digest(commits, opts).groups) do
          if g.kind == "parsers" then return g end
        end
      end
      local bumps = {
        { subject = "feat(kdl)!: update parser and queries" },
        { subject = "feat(tmux)!: update parser and queries" },
      }
      assert.are.same({}, group(bumps, { parsers = { lua = true } }).installed)
      -- no installed parsers handed in: nothing is known
      assert.is_nil(group(bumps, {}).installed)
      -- `feat(parsers)!: update kdl` names no language in its scope
      local mixed = { { subject = "feat(parsers)!: update kdl" }, bumps[2] }
      assert.is_nil(group(mixed, { parsers = { lua = true } }).installed)
      assert.are.same({ "tmux" }, group(mixed, { parsers = { tmux = true } }).installed)
    end)
  end)

  describe("convention", function()
    it("needs half of the subjects to be conventional", function()
      local c = B.convention({ "feat: a", "fix: b", "Add c", "Update d" })
      assert.is_nil(c.recognized) -- too few to tell
      c = B.convention({ "feat: a", "fix: b", "Add c", "Update d", "docs: e", "x" })
      assert.is_true(c.recognized)
      c = B.convention({ "feat: a", "Add c", "Update d", "Fix e", "y", "z" })
      assert.is_false(c.recognized)
      assert.are.equal(1, c.conventional)
      assert.are.equal(6, c.total)
    end)
  end)

  describe("digest", function()
    local function commits(subjects)
      local out = {}
      for i, s in ipairs(subjects) do
        out[i] = { sha = ("%040x"):format(i), subject = s, body = "" }
      end
      return out
    end

    it("folds a subject repeated collapse_repeats times, but never a footer commit", function()
      local list = commits({
        "bot: update lockfile",
        "bot: update lockfile",
        "bot: update lockfile",
        "bot: update lockfile",
        "bot: update lockfile",
        "fix: something",
      })
      local d = B.digest(list, { collapse_repeats = 5 })
      assert.are.equal(1, #d.groups)
      assert.are.equal(5, #d.groups[1].members)
      assert.is_nil(d.grouped[6])

      list[3].body = "BREAKING CHANGE: the lock format changed"
      d = B.digest(list, { collapse_repeats = 5 })
      assert.are.equal(0, #d.groups, "four repeats left: below the threshold")
      assert.are.same({ 3 }, d.sure)

      d = B.digest(list, { collapse_repeats = 4 })
      assert.are.equal(4, #d.groups[1].members)
      assert.is_nil(d.grouped[3], "the footer commit stays outside the group")
    end)

    it("normalizes subjects before comparing them", function()
      assert.are.equal(
        "update parser and queries",
        B.normalize_subject("feat(kdl)!: update parser and queries")
      )
      assert.are.equal(
        "update parser and queries",
        B.normalize_subject("feat: Update  parser and queries (#12)")
      )
      assert.are.equal("plain subject", B.normalize_subject("Plain subject"))
    end)

    it("numbers the commits of a complete update, oldest = 1", function()
      local d = B.digest(commits({ "c", "b", "a" }), { positions = true })
      assert.are.same({ 3, 2, 1 }, d.positions)
      d = B.digest(commits({ "c", "b", "a" }), {})
      assert.is_nil(d.positions)
    end)

    it("sorts hints by score, then by order", function()
      local list = commits({ "fix: remove x", "refactor: tidy", "fix: rename y" })
      list[2].gone = { "lua/a/b.lua" }
      local d = B.digest(list, {})
      assert.are.same({ 2, 1, 3 }, d.hints)
    end)
  end)

  describe("the reference update nvim-treesitter f873ec29..e289100f", function()
    local list = read_jsonl(FIXTURES .. "nvim-treesitter-f873ec29-e289100f.jsonl")

    it("has the counts the analysis verified", function()
      assert.are.equal(86, #list)
      local bang, same_subject = 0, 0
      for _, c in ipairs(list) do
        if c.subject:match("^[%a][%w_%-]*%b()!:") or c.subject:match("^[%a][%w_%-]*!:") then
          bang = bang + 1
        end
        if B.normalize_subject(c.subject) == "update parser and queries" then
          same_subject = same_subject + 1
        end
      end
      assert.are.equal(26, bang)
      assert.are.equal(27, same_subject)
    end)

    it("finds three sure commits (17, 43, 46 of 86) and one parser group of 23", function()
      local d = B.digest(list, {
        positions = true,
        parser_plugin = true,
        parsers = { tmux = true, kdl = true },
        nvim = { major = 0, minor = 12, patch = 2 },
      })
      local found = {}
      for _, i in ipairs(d.sure) do
        found[#found + 1] = ("%s %d/%d"):format(list[i].sha:sub(1, 8), d.positions[i], d.total)
      end
      table.sort(found)
      assert.are.same({ "78bebef1 43/86", "c82bf96f 17/86", "ddc93c67 46/86" }, found)

      local parser_groups = vim.tbl_filter(function(g)
        return g.kind == "parsers"
      end, d.groups)
      assert.are.equal(1, #parser_groups)
      assert.are.equal(23, #parser_groups[1].members)
      assert.are.equal(23, parser_groups[1].breaking)
      assert.are.equal("feat(<lang>)!: update parser and queries", parser_groups[1].label)
      assert.are.same({ "kdl", "tmux" }, parser_groups[1].installed)

      -- c82bf96f drops a Neovim older than the running one
      for _, i in ipairs(d.sure) do
        if list[i].sha:sub(1, 8) == "c82bf96f" then
          assert.is_false(d.verdicts[i].relevance.affects)
        end
      end
    end)
  end)

  describe("the fixture gate", function()
    local corpus = read_jsonl(FIXTURES .. "corpus.jsonl")

    it("is a curated corpus of 120 to 150 real commits", function()
      assert.is_true(#corpus >= 120 and #corpus <= 150, tostring(#corpus))
      local crlf, multi_scope = false, false
      for _, c in ipairs(corpus) do
        if c.body:find("\r\n", 1, true) and c.tier == "sure" then crlf = true end
        if c.tier == "sure" and c.subject:match("^%a+%([^)]*,[^)]*%)!:") then multi_scope = true end
      end
      assert.is_true(crlf, "a sure commit with a CRLF body is in the corpus")
      assert.is_true(multi_scope, "a feat(a,b)!: commit is in the corpus")
    end)

    it("classifies every commit as recorded (drift 0)", function()
      local drift = {}
      for _, c in ipairs(corpus) do
        local got = B.classify({ sha = c.sha, subject = c.subject, body = c.body, gone = c.gone }).tier
          or "none"
        if got ~= c.tier then
          drift[#drift + 1] = ("%s %s: recorded %s, now %s"):format(
            c.repo,
            c.sha:sub(1, 8),
            c.tier,
            got
          )
        end
      end
      assert.are.same({}, drift)
    end)

    it("keeps the precision of sure at 90 % or more and of probable at 35 % or more", function()
      local stats = {}
      for _, c in ipairs(corpus) do
        local s = stats[c.tier] or { n = 0, yes = 0 }
        s.n = s.n + 1
        if c.breaking then s.yes = s.yes + 1 end
        stats[c.tier] = s
      end
      assert.is_true(stats.sure.yes / stats.sure.n >= 0.90, vim.inspect(stats.sure))
      assert.is_true(stats.probable.yes / stats.probable.n >= 0.35, vim.inspect(stats.probable))
    end)
  end)
end)
