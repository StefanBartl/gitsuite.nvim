---@module 'gitsuite.features.plugins.breaking'
--- Which commits of an update may break the user's setup -- a heuristic, and
--- a pure one: commits in, verdicts out, no git and no editor state (what is
--- installed and which Neovim runs are handed in).
---
--- Four tiers, measured on the newest 300 commits of 50 real plugin clones
--- (10,886 commits, 615 judged by hand):
---   * `sure`      `type(scope)!:`, a `BREAKING CHANGE:` footer (also
---                 `BREAKING-CHANGE:`/`BREAKING_CHANGE:`, upper case only) or a
---                 subject that starts with `BREAKING`. About 1 % of all
---                 commits, ~96 % of them really breaking.
---   * `probable`  "drop support/compat", "requires Neovim x", a lower-case
---                 footer, "by default" in the subject. ~0.7 %, ~42 % breaking.
---   * `hint`      remove/rename/deprecate words, a removed Lua module, the word
---                 "breaking" in the body; scored, shown folded. ~8 %, ~10 %.
---   * `bulk`      a `!` on a tree-sitter parser bump (`feat(kdl)!: update
---                 parser and queries`): formally breaking, in practice noise.
--- Reverts never count. Recall is low (sure: about a third, sure + probable:
--- about half of what a person calls breaking), so a report that finds nothing
--- must say that this proves nothing.
---
--- The rules are `vim.regex` patterns (very magic, with an explicit `\C`/`\c`
--- so 'ignorecase' cannot change a verdict), never Lua patterns: these need
--- alternation. Bodies are normalized from CRLF before anything is matched.
---
--- `digest` adds what makes a long update readable: commits whose normalized
--- subject repeats `collapse_repeats` times or more are folded into one group
--- (a commit that is `sure`, e.g. one with a `BREAKING CHANGE:` footer, is never
--- folded -- that is the footer valve), every parser bump goes into one
--- `parsers` group, and each commit gets its position "i of n" in the update.

local M = {}

---Commits whose normalized subject repeats at least this often are folded.
M.COLLAPSE_REPEATS = 5

---Below this many subjects the share of conventional commits says nothing.
M.CONVENTION_MIN = 5

---The share of conventional subjects from which a project counts as using the
---convention (and so as flagging its breaking changes).
M.CONVENTION_SHARE = 0.5

---How many hints `digest` puts in front (the rest stays reachable).
M.TOP_HINTS = 5

---@type table<string, any>
local compiled = {}

---A compiled `vim.regex`, cached by pattern.
---@param pattern string
---@return any
local function re(pattern)
  local r = compiled[pattern]
  if not r then
    r = vim.regex(pattern)
    compiled[pattern] = r
  end
  return r
end

---@param pattern string
---@param s string
---@return boolean
local function matches(pattern, s)
  return s ~= "" and re(pattern):match_str(s) ~= nil
end

-- The patterns. Every one starts with `\v` (very magic) and `\C` (case matters)
-- or `\c` (it does not).

---`type(scope)!:` -- the conventional-commit breaking marker. The `!` must come
---right before the colon: `a!b: x` or a `!` in prose is no marker.
local P_BANG = [[\v\C^[a-zA-Z][a-zA-Z0-9_-]*(\([^()]*\))?!:]]
---A conventional subject at all (`type(scope)?!?: text`).
local P_CONVENTIONAL = [[\v\C^[a-zA-Z][a-zA-Z0-9_-]*(\([^()]*\))?!?: ]]
---The footer, upper case only (git trailers are case-insensitive, but
---lower-case spellings are mostly prose).
local P_FOOTER = [[\v\C^BREAKING[ _-]CHANGES?:]]
local P_FOOTER_ANY = [[\v\c^breaking[ _-]?changes?:]]
---A subject that announces itself.
local P_PREFIX = [[\v\C^\[?BREAKING>]]
local P_PREFIX_LOWER = [[\v\c^\[?breaking>]]
---The marker in the wrong place (`fix!(lsp):`, `feat(x!):`, `feat(x)! text`):
---the author meant it, but it is no conventional marker.
local P_BANG_MISPLACED = [[\v\C^[a-zA-Z][a-zA-Z0-9_-]*(!\([^()]*\)|\([^()]*!\)|(\([^()]*\))?!\s)]]
---A tree-sitter parser bump: `feat(kdl)!: update parser and queries`,
---`feat(parsers)!: update kdl`.
local P_PARSER = [[\v\c^[a-z]+(!?\([^()]+\)!?|!)?:?\s+(update|bump)\s+(parsers?|queries)>]]
local P_PARSERS_SCOPE = [[\v\c^[a-z]+\(parsers?\)!?:\s*(update|bump)>]]
local P_REVERT = [[\v\c^(revert\s*"|revert(\([^()]*\))?!?:|reapply\s*")]]
local P_DROP = [[\v\c<drop(s|ped|ping)?\s+(the\s+)?(support|compat(ibility)?)>]]
local P_REQUIRES =
  [=[\v\c<(requires?|required|needs)\s+(neovim|nvim|vim)\s*(version\s*)?(\>\=?\s*)?v?[0-9]]=]
local P_REQUIRED = [[\v\c<(neovim|nvim)\s*v?[0-9][0-9.]*\+?\s+(is\s+)?(now\s+)?required>]]
local P_MINIMUM =
  [[\v\c<(bump|raise|increase)s?\s+(the\s+)?min(imum|imal)?\s+(supported\s+)?(neovim|nvim|vim)?\s*version>]]
local P_BY_DEFAULT = [[\v\c<by\s+default>]]
local P_REMOVE = [[\v\c<(remov(e|es|ed|ing)|renam(e|es|ed|ing)|deprecat(e|es|ed|ing|ion))>]]
local P_BREAKING_WORD = [[\v\c<breaking>]]
---With captures (`vim.fn.matchlist`): the Neovim version a "drop support"
---commit leaves behind, and the one a "requires" commit asks for.
local P_FLOOR_DROP =
  [[\v\c<(drop|remove)(s|ped|d|ping)?\s+(the\s+)?support\s+for\s+(neovim|nvim)[- ]*v?([0-9]+)\.([0-9]+)]]
local P_FLOOR_REQUIRE =
  [[\v\c<(requires?|required|needs|minimum)\s+(neovim|nvim)[- ]*(version\s*)?(\>\=?\s*)?v?([0-9]+)\.([0-9]+)]]

---Text from git with every line break as `\n` (34 of 50 measured plugins have
---CRLF in commit bodies; a `\r` would hide a footer from the line rules).
---@param s any
---@return string
function M.normalize_text(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

---@param body string
---@return string[]
local function lines_of(body)
  local out = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

---@param lines string[]
---@param pattern string
---@return boolean
local function any_line(lines, pattern)
  for _, line in ipairs(lines) do
    if matches(pattern, line) then return true end
  end
  return false
end

---The scope of a conventional subject, split at commas (`feat(a,b)!:` ->
---`{ "a", "b" }`), or nil.
---@param subject string
---@return string[]|nil
function M.scopes(subject)
  local inner = subject:match("^[%a][%w_%-]*%(([^()]*)%)!?:")
  if not inner then return nil end
  local out = {}
  for part in inner:gmatch("[^,]+") do
    local s = vim.trim(part):gsub("!$", "")
    if s ~= "" then out[#out + 1] = s end
  end
  return out
end

---The type of a conventional subject (`feat`, `fix`, ...), lower case, or nil.
---@param subject any
---@return string|nil
function M.type_of(subject)
  if type(subject) ~= "string" or not matches(P_CONVENTIONAL, subject) then return nil end
  return (subject:match("^([%a][%w_%-]*)") or ""):lower()
end

---A subject with its conventional prefix, a trailing `(#123)` and case taken
---off: what repeats when a bot or a script makes the same commit again and
---again.
---@param subject any
---@return string
function M.normalize_subject(subject)
  if type(subject) ~= "string" then return "" end
  local s = subject:gsub("^[%a][%w_%-]*%b()!?:%s*", ""):gsub("^[%a][%w_%-]*!?:%s*", "")
  s = s:gsub("%s*%(#%d+%)%s*$", ""):lower():gsub("%s+", " ")
  return vim.trim(s)
end

---@param v any
---@return { major: integer, minor: integer, patch: integer }|nil
local function as_version(v)
  if type(v) ~= "table" then return nil end
  local major, minor = tonumber(v.major or v[1]), tonumber(v.minor or v[2])
  if not major or not minor then return nil end
  return { major = major, minor = minor, patch = tonumber(v.patch or v[3]) or 0 }
end

---@param a { major: integer, minor: integer }
---@param b { major: integer, minor: integer }
---@return integer  -1, 0 or 1
local function cmp_minor(a, b)
  if a.major ~= b.major then return a.major < b.major and -1 or 1 end
  if a.minor ~= b.minor then return a.minor < b.minor and -1 or 1 end
  return 0
end

---@param v { major: integer, minor: integer, patch?: integer }
---@return string
local function vstr(v)
  return ("%d.%d.%d"):format(v.major, v.minor, v.patch or 0)
end

---Whether a commit about the Neovim version concerns the running one:
---"drop support for Nvim 0.11" on 0.12.2 does not; "requires Neovim 0.13" on
---0.12.2 does.
---@param text string  Subject and body.
---@param nvim { major: integer, minor: integer, patch?: integer }
---@return { affects: boolean, reason: string }|nil
local function nvim_relevance(text, nvim)
  local m = vim.fn.matchlist(text, P_FLOOR_DROP)
  if m[1] then
    local dropped = { major = tonumber(m[6]), minor = tonumber(m[7]) }
    if dropped.major and dropped.minor then
      local newer = cmp_minor(nvim, dropped) > 0
      return {
        affects = not newer,
        reason = ("drops Neovim %d.%d; you run %s"):format(
          dropped.major,
          dropped.minor,
          vstr(nvim)
        ) .. (newer and " (does not affect you)" or ""),
      }
    end
  end
  m = vim.fn.matchlist(text, P_FLOOR_REQUIRE)
  if m[1] then
    local need = { major = tonumber(m[6]), minor = tonumber(m[7]) }
    if need.major and need.minor then
      local met = cmp_minor(nvim, need) >= 0
      return {
        affects = not met,
        reason = ("requires Neovim %d.%d; you run %s"):format(need.major, need.minor, vstr(nvim))
          .. (met and " (met)" or " (NOT met)"),
      }
    end
  end
  return nil
end

---@param langs string[]
---@param installed table<string, true>
---@return { affects: boolean, reason: string, installed: string[] }
local function parser_relevance(langs, installed)
  local have = {}
  for _, lang in ipairs(langs) do
    if installed[lang] then have[#have + 1] = lang end
  end
  if #have == 0 then
    return { affects = false, reason = "parser not installed", installed = have }
  end
  return {
    affects = true,
    reason = "installed: " .. table.concat(have, ", "),
    installed = have,
  }
end

---A Lua module the commit deleted, from a path (`lua/foo/bar.lua` ->
---`foo.bar`), or nil.
---@param path any
---@return string|nil
function M.module_of(path)
  if type(path) ~= "string" then return nil end
  local mod = path:match("^lua/(.+)%.lua$")
  if not mod then return nil end
  mod = mod:gsub("/init$", ""):gsub("/", ".")
  return mod
end

---@class GitSuite.Plugins.BreakingOpts
---@field ignore? string[]     `vim.regex` patterns (very magic is up to the pattern) on the subject: a match is never classified.
---@field force? string[]      Commit hashes (or prefixes of at least 7 digits) that are always `sure`.
---@field parsers? table<string, true>  Installed tree-sitter languages (for the relevance of parser commits).
---@field parser_plugin? boolean  The plugin ships parsers: a scope names languages.
---@field nvim? { major: integer, minor: integer, patch?: integer }  The running Neovim.
---@field collapse_repeats? integer
---@field positions? boolean   The commits are the complete update, newest first in topological order: number them.

---@class GitSuite.Plugins.Verdict
---@field tier? "sure"|"probable"|"hint"|"bulk"
---@field rules string[]       Ids of the rules that matched.
---@field score integer        Weight of the hint rules.
---@field revert? boolean
---@field ignored? boolean
---@field forced? boolean
---@field langs? string[]      For a parser commit: its languages.
---@field relevance? { affects: boolean, reason: string, installed?: string[] }

---@param sha any
---@param force string[]|nil
---@return boolean
local function forced(sha, force)
  if type(sha) ~= "string" or type(force) ~= "table" then return false end
  for _, prefix in ipairs(force) do
    if type(prefix) == "string" and #prefix >= 7 and sha:sub(1, #prefix) == prefix:lower() then
      return true
    end
  end
  return false
end

---@param subject string
---@param ignore string[]|nil
---@return boolean
local function ignored(subject, ignore)
  if type(ignore) ~= "table" then return false end
  for _, pattern in ipairs(ignore) do
    if type(pattern) == "string" then
      local ok, r = pcall(re, pattern)
      if ok and r:match_str(subject) then return true end
    end
  end
  return false
end

---Commit types (and scopes) that do not reach the user: CI, tests, docs,
---formatting, housekeeping. Without a marker of their own they get no tier --
---"remove a CI step" or "docs: ... by default" is no change to the plugin.
---@type table<string, true>
local INTERNAL = {
  ci = true,
  test = true,
  tests = true,
  docs = true,
  doc = true,
  style = true,
  build = true,
  chore = true,
}

---@param subject string
---@return boolean
local function internal(subject)
  local t = M.type_of(subject)
  if not t then return false end
  if INTERNAL[t] then return true end
  local scopes = M.scopes(subject)
  return scopes ~= nil and #scopes == 1 and INTERNAL[scopes[1]:lower()] == true
end

---Classify one commit.
---@param commit { sha?: string, subject?: string, body?: string, gone?: string[] }
---@param opts? GitSuite.Plugins.BreakingOpts
---@return GitSuite.Plugins.Verdict
function M.classify(commit, opts)
  opts = opts or {}
  local subject = vim.trim((M.normalize_text(commit.subject):gsub("\n", " ")))
  local body = M.normalize_text(commit.body)
  local lines = lines_of(body)
  local v = { rules = {}, score = 0 } ---@type GitSuite.Plugins.Verdict
  local function hit(id)
    v.rules[#v.rules + 1] = id
  end

  if matches(P_REVERT, subject) then
    v.revert = true
    hit("revert")
    return v
  end
  if ignored(subject, opts.ignore) then
    v.ignored = true
    hit("ignored")
    return v
  end

  local bang = matches(P_BANG, subject)
  local footer = any_line(lines, P_FOOTER)
  local prefix = matches(P_PREFIX, subject)
  local parser = matches(P_PARSER, subject) or matches(P_PARSERS_SCOPE, subject)
  if bang then hit("bang") end
  if footer then hit("footer") end
  if prefix then hit("prefix") end

  local text = subject .. "\n" .. body
  if forced(commit.sha, opts.force) then
    v.forced = true
    hit("forced")
    v.tier = "sure"
  elseif bang and parser and not footer then
    hit("parser")
    v.tier = "bulk"
  elseif bang or footer or prefix then
    v.tier = "sure"
  elseif not internal(subject) then
    local probable = false
    if matches(P_DROP, text) then
      hit("drop_support")
      probable = true
    end
    if matches(P_REQUIRES, text) or matches(P_REQUIRED, text) or matches(P_MINIMUM, text) then
      hit("requires_nvim")
      probable = true
    end
    if any_line(lines, P_FOOTER_ANY) then
      hit("footer_lower")
      probable = true
    end
    if matches(P_BY_DEFAULT, subject) then
      hit("by_default")
      probable = true
    end
    -- (a parser bump with a misplaced `!` is as routine as one without)
    if matches(P_BANG_MISPLACED, subject) and not parser then
      hit("bang_misplaced")
      probable = true
    end
    if matches(P_PREFIX_LOWER, subject) then
      hit("prefix_lower")
      probable = true
    end
    if probable then
      v.tier = "probable"
    else
      if matches(P_REMOVE, subject) then
        hit("remove_word")
        v.score = v.score + 2
      elseif matches(P_REMOVE, body) then
        hit("remove_word_body")
        v.score = v.score + 1
      end
      if matches(P_BREAKING_WORD, body) then
        hit("breaking_word")
        v.score = v.score + 2
      end
      local gone = {}
      for _, path in ipairs(type(commit.gone) == "table" and commit.gone or {}) do
        local mod = M.module_of(path)
        if mod then gone[#gone + 1] = mod end
      end
      if #gone > 0 then
        hit("module_removed")
        v.score = v.score + 3
      end
      if v.score >= 2 then v.tier = "hint" end
    end
  end

  -- Relevance: what of this concerns the user's own setup.
  if v.tier and (parser or opts.parser_plugin) then
    local scopes = M.scopes(subject)
    if scopes and opts.parsers and not (#scopes == 1 and scopes[1]:match("^parsers?$")) then
      local r = parser_relevance(scopes, opts.parsers)
      -- A scope of a parser plugin may also be a module (`fix(install)`): only a
      -- parser bump, or a scope that IS an installed parser, says something.
      if parser or r.affects then
        v.langs = scopes
        v.relevance = r
      end
    end
  end
  if v.tier and v.tier ~= "bulk" then
    local nvim = as_version(opts.nvim)
    if nvim then v.relevance = nvim_relevance(text, nvim) or v.relevance end
  end
  return v
end

---Whether a project uses the conventional-commit convention (and so marks its
---breaking changes): at least `CONVENTION_SHARE` of its subjects are
---`type(scope): ...`.
---@param subjects string[]  Newest first; the first 100 are looked at.
---@return { conventional: integer, total: integer, recognized: boolean|nil }  `recognized` is nil when there are too few subjects to tell.
function M.convention(subjects)
  local n, total = 0, 0
  for i = 1, math.min(#subjects, 100) do
    local s = subjects[i]
    if type(s) == "string" then
      total = total + 1
      if matches(P_CONVENTIONAL, s) then n = n + 1 end
    end
  end
  local recognized
  if total >= M.CONVENTION_MIN then recognized = n / total >= M.CONVENTION_SHARE end
  return { conventional = n, total = total, recognized = recognized }
end

---@class GitSuite.Plugins.Group
---@field kind "parsers"|"repeat"
---@field key string           The normalized subject (`parsers` for the parser group).
---@field label string         A representative subject.
---@field members integer[]    Indexes into the commits, in their order.
---@field breaking integer     Members with a `!` marker.
---@field installed? string[]  Parser group: the installed languages it touches.

---@class GitSuite.Plugins.Digest
---@field verdicts GitSuite.Plugins.Verdict[]  One per commit, same order.
---@field positions? integer[]  "i of n" per commit (1 = oldest), when known.
---@field total integer
---@field sure integer[]        Indexes, in commit order.
---@field probable integer[]
---@field hints integer[]       Indexes, best score first (then commit order).
---@field groups GitSuite.Plugins.Group[]
---@field grouped table<integer, integer>  Commit index -> index into `groups`.

---Classify the commits of one update and arrange them for reading.
---@param commits table[]  Newest first (as `git log` prints them).
---@param opts? GitSuite.Plugins.BreakingOpts
---@return GitSuite.Plugins.Digest
function M.digest(commits, opts)
  opts = opts or {}
  local threshold = opts.collapse_repeats or M.COLLAPSE_REPEATS
  local n = #commits
  local d = {
    verdicts = {},
    total = n,
    sure = {},
    probable = {},
    hints = {},
    groups = {},
    grouped = {},
  }
  if opts.positions then d.positions = {} end

  for i, commit in ipairs(commits) do
    local v = M.classify(commit, opts)
    d.verdicts[i] = v
    if d.positions then d.positions[i] = n - i + 1 end
  end

  -- The parser group: every parser bump, one row.
  local parsers = { kind = "parsers", key = "parsers", members = {}, breaking = 0 }
  local have = {}
  for i, v in ipairs(d.verdicts) do
    if v.tier == "bulk" then
      parsers.members[#parsers.members + 1] = i
      parsers.breaking = parsers.breaking + 1
      -- `feat(kdl)!: update parser and queries` -> `feat(<lang>)!: ...`
      parsers.label = parsers.label
        or (tostring(commits[i].subject or ""):gsub("^([%a][%w_%-]*)%b()", "%1(<lang>)", 1))
      for _, lang in ipairs(v.relevance and v.relevance.installed or {}) do
        have[lang] = true
      end
    end
  end
  if #parsers.members > 0 then
    parsers.installed = vim.tbl_keys(have)
    table.sort(parsers.installed)
    d.groups[1] = parsers
    for _, i in ipairs(parsers.members) do
      d.grouped[i] = 1
    end
  end

  -- Repeats: the same normalized subject `threshold` times or more. A `sure`
  -- commit (a footer, a `!` that is no parser bump) never folds away.
  local by_key, order = {}, {}
  for i, commit in ipairs(commits) do
    local v = d.verdicts[i]
    if not d.grouped[i] and v.tier ~= "sure" then
      local key = M.normalize_subject(commit.subject)
      if key ~= "" then
        if not by_key[key] then
          by_key[key] = {}
          order[#order + 1] = key
        end
        local list = by_key[key]
        list[#list + 1] = i
      end
    end
  end
  for _, key in ipairs(order) do
    local members = by_key[key]
    if #members >= threshold then
      local g = {
        kind = "repeat",
        key = key,
        label = commits[members[1]].subject,
        members = members,
        breaking = 0,
      }
      for _, i in ipairs(members) do
        if matches(P_BANG, commits[i].subject or "") then g.breaking = g.breaking + 1 end
      end
      d.groups[#d.groups + 1] = g
      for _, i in ipairs(members) do
        d.grouped[i] = #d.groups
      end
    end
  end

  for i, v in ipairs(d.verdicts) do
    if v.tier == "sure" then
      d.sure[#d.sure + 1] = i
    elseif v.tier == "probable" and not d.grouped[i] then
      d.probable[#d.probable + 1] = i
    elseif v.tier == "hint" and not d.grouped[i] then
      d.hints[#d.hints + 1] = i
    end
  end
  table.sort(d.hints, function(a, b)
    local sa, sb = d.verdicts[a].score, d.verdicts[b].score
    if sa ~= sb then return sa > sb end
    return a < b
  end)
  return d
end

return M
