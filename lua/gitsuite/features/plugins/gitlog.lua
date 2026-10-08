---@module 'gitsuite.features.plugins.gitlog'
--- The one place `features/plugins` runs git -- and the place that keeps it
--- read-only.
---
--- It reads other people's repositories (a plugin manager's clones), so three
--- invariants hold for every process started from here:
---   * **No writes.** `lib.nvim.git.run` runs whatever it is handed; this module
---     puts an allowlist of read-only verbs in front of it and refuses options
---     that write a file or run an external program. `fetch`, `pull`, `checkout`,
---     `reset`, `gc`, ... are not on the list.
---   * **No network.** Every call sets `no_lazy_fetch` (git then fails on a
---     missing object of a blobless clone instead of quietly fetching it into
---     the clone), `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` (no
---     credential prompt can hang or pop up).
---   * **Bounded.** Each process runs under `plugins.timeout_ms`.
---
--- Callers that use a typed lib.nvim function (`git.log_async`, `git.tags_async`,
--- ...) need no allowlist -- the verb is fixed there -- but still get the same
--- environment from `opts()`.

local git = require("lib.nvim.git")
local config = require("gitsuite.config")

local M = {}

---Verbs that only read. Anything else is refused by `check`.
---@type table<string, true>
M.READ_ONLY_VERBS = {
  ["log"] = true,
  ["for-each-ref"] = true,
  ["rev-parse"] = true,
  ["rev-list"] = true,
  ["cat-file"] = true,
  ["merge-base"] = true,
  ["diff-tree"] = true,
  ["ls-tree"] = true,
}

---Option prefixes refused whatever the verb: they write a file, or make git
---run a program named in the repository's own (untrusted) configuration.
---@type string[]
local FORBIDDEN_OPTIONS = {
  "--output",
  "--ext-diff",
  "--textconv",
  "--exec",
  "--upload-pack",
  "--receive-pack",
  "--open-files-in-pager",
  "--paginate",
  "-O",
  -- Patch and statistics output reads file CONTENTS: in a blobless clone that
  -- is a (blocked) fetch, elsewhere it runs the repository's `textconv`/
  -- external-diff programs from its own configuration. Names and messages
  -- (`--name-status`, `--format`) never need any of it.
  "-p",
  "-u",
  "-c",
  "--cc",
  "--patch",
  "--patch-with-stat",
  "--patch-with-raw",
  "--stat",
  "--numstat",
  "--shortstat",
  "--dirstat",
  "--filters",
  "-S",
  "-G",
  "--pickaxe-regex",
  "--pickaxe-all",
}

---Verbs that produce a diff and so take `--no-textconv` / `--no-ext-diff`.
---@type table<string, true>
local DIFF_VERBS = { ["log"] = true, ["diff-tree"] = true }

---Whether `args` (what follows `git`) may be run.
---@param args any
---@return boolean ok
---@return string|nil err
function M.check(args)
  if type(args) ~= "table" or #args == 0 then return false, "no git arguments" end
  local verb = args[1]
  if type(verb) ~= "string" or not M.READ_ONLY_VERBS[verb] then
    return false,
      ("git %s is not a read-only verb; gitsuite's plugin features never change a clone"):format(
        tostring(verb)
      )
  end
  for i = 2, #args do
    local arg = args[i]
    if type(arg) ~= "string" then return false, "git arguments must be strings" end
    if arg:find("[%z\r\n]") then return false, "a git argument contains a line break or NUL" end
    -- Everything after a bare `--` is a path, not an option.
    if arg == "--" then break end
    for _, forbidden in ipairs(FORBIDDEN_OPTIONS) do
      if arg == forbidden or arg:sub(1, #forbidden + 1) == forbidden .. "=" then
        return false, ("git option %s is not allowed here"):format(arg)
      end
    end
  end
  return true, nil
end

---The options every process gets: bounded, offline, never asking for input,
---and pinned to the clone it was asked about.
---
---`GIT_DIR`/`GIT_WORK_TREE` are set to the clone: `-C <dir>` does not override
---a `GIT_DIR` the editor itself inherited (started from a hook, a dotfiles
---setup, lazygit), and git would then quietly read the wrong repository. A
---clone this feature reads always has its own `.git` directory.
---@param dir string Absolute path of the clone.
---@param extra? table Merged over the result.
---@return Lib.Git.RunOpts
function M.opts(dir, extra)
  return vim.tbl_extend("force", {
    dir = dir,
    timeout_ms = config.get().plugins.timeout_ms,
    no_lazy_fetch = true,
    env = {
      GIT_TERMINAL_PROMPT = "0",
      GCM_INTERACTIVE = "never",
      LC_ALL = "C",
      GIT_DIR = dir .. "/.git",
      GIT_WORK_TREE = dir,
    },
  }, extra or {})
end

---The arguments that are actually run: `args` plus, for the verbs that make a
---diff, `--no-textconv --no-ext-diff` (before any `--`). The option check
---already refuses patch output; this is the second lock, so a way past the
---first still cannot start a program named in the clone's own configuration.
---@param args string[]
---@return string[]
function M.argv(args)
  if not DIFF_VERBS[args[1]] then return vim.deepcopy(args) end
  local out, inserted = {}, false
  for _, arg in ipairs(args) do
    if arg == "--" and not inserted then
      vim.list_extend(out, { "--no-textconv", "--no-ext-diff" })
      inserted = true
    end
    out[#out + 1] = arg
  end
  if not inserted then vim.list_extend(out, { "--no-textconv", "--no-ext-diff" }) end
  return out
end

---Run an allowlisted read-only git command in `dir`.
---@param args string[] E.g. `{ "diff-tree", "--name-status", "--no-renames", "-r", sha }`.
---@param dir string
---@param on_done fun(result: Lib.Git.RunResult|nil, err: string|nil) `vim.schedule`d.
---@return { stop: fun() } handle
function M.run(args, dir, on_done)
  local ok, err = M.check(args)
  if not ok then
    vim.schedule(function()
      on_done(nil, err)
    end)
    return { stop = function() end }
  end
  return git.run_async(M.argv(args), M.opts(dir, { read_only = true }), function(res)
    on_done(res, nil)
  end)
end

---A revision this module will put into a range: a hash, or a tag peeled to its
---commit (`refs/tags/<tag>^{commit}`). Nothing that starts with `-`, no
---abbreviation, no `..` -- the range is built by gluing two of these together.
---@param rev any
---@return boolean
function M.valid_rev(rev)
  if type(rev) ~= "string" then return false end
  if rev:match("^%x+$") and #rev >= 7 and #rev <= 64 then return true end
  local tag = rev:match("^refs/tags/(.+)%^{commit}$")
  return tag ~= nil
    and require("gitsuite.features.plugins.gitfs").valid_refname("refs/tags/" .. tag)
end

---@param on_done function
---@param err string
---@return { stop: fun() }
local function refuse(on_done, err)
  vim.schedule(function()
    on_done(nil, err)
  end)
  return { stop = function() end }
end

---The commits between two states of a clone, **one** process: `from...to` with
---`--left-right`, so `entry.side` says which side a commit is on -- `>` only in
---`to`, `<` only in `from` (a rollback, a force-push, a branch switch), which is
---the direction without a second call. No file lists: names are not needed for
---the report and cost output.
---@param dir string
---@param from string  A hash.
---@param to string    A hash or `refs/tags/<tag>^{commit}`.
---@param opts? { max_count?: integer, no_merges?: boolean }
---@param on_done fun(entries: Lib.Git.LogEntry[]|nil, err: string|nil) `vim.schedule`d.
---@return { stop: fun() } handle
function M.range(dir, from, to, opts, on_done)
  opts = opts or {}
  if not M.valid_rev(from) or not M.valid_rev(to) then
    return refuse(on_done, "not a usable revision for a range")
  end
  return git.log_async(
    from .. "..." .. to,
    M.opts(dir, {
      left_right = true,
      max_count = opts.max_count,
      no_merges = opts.no_merges,
    }),
    on_done
  )
end

---Whether `rev` names a commit this clone has (`cat-file -e`): tells a
---force-pushed-away `from` from any other failure.
---@param dir string
---@param rev string
---@param on_done fun(has: boolean) `vim.schedule`d.
---@return { stop: fun() } handle
function M.has_commit(dir, rev, on_done)
  if not M.valid_rev(rev) then
    return refuse(function()
      on_done(false)
    end, "")
  end
  return M.run({ "cat-file", "-e", rev .. "^{commit}" }, dir, function(res)
    on_done(res ~= nil and res.ok == true)
  end)
end

---The newest `n` commits of `dir`'s HEAD with their message and changed files
----- **one** process. `--name-status --no-renames` reads trees only, so it
---works offline in a blobless clone.
---@param dir string
---@param n integer
---@param on_done fun(entries: Lib.Git.LogEntry[]|nil, err: string|nil) `vim.schedule`d.
---@return { stop: fun() } handle
function M.log(dir, n, on_done)
  return git.log_async("HEAD", M.opts(dir, { max_count = n, name_status = true }), on_done)
end

return M
