---@module 'gitsuite.features.plugins.gitlog'
--- The one place `features/plugins` runs git -- and the place that keeps it
--- read-only.
---
--- It reads other people's repositories (a plugin manager's clones), so these
--- invariants hold for every process started from here:
---   * **No writes, no programs.** `lib.nvim.git.run` runs whatever it is handed;
---     this module puts an allowlist in front of it -- a handful of read-only
---     verbs and, for each, only the options this feature really passes. Whatever
---     else (patch or statistics output, `-S`/`-G`, `--output`, an abbreviated
---     spelling of any of them) is refused, because it would read file contents,
---     write a file or run a program named in the clone's own configuration.
---     Independently of that the environment pins the config vectors that start a
---     program from `git log` (`core.fsmonitor`, the `gpg.*` programs), and the
---     diff-making verbs get `--no-textconv --no-ext-diff`.
---   * **No network.** Every call sets `no_lazy_fetch` (git then fails on a
---     missing object of a blobless clone instead of quietly fetching it into
---     the clone), `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` (no
---     credential prompt can hang or pop up), and on Windows a clone whose own
---     files point git at a network path (alternates, `commondir`,
---     `include.path`) is refused before git starts -- an SMB connection to
---     somebody else's server leaks the user's hash and stalls until the timeout.
---   * **Bounded.** Each process runs under `plugins.timeout_ms`, and its output
---     under `MAX_OUTPUT`: one commit with a hundred-megabyte message must not be
---     read into memory just to be cut down afterwards.
---
--- Callers that use a typed lib.nvim function (`git.log_async`, ...) need no verb
--- allowlist -- the verb is fixed there -- but still get the same environment and
--- limits from `opts()`.

local git = require("lib.nvim.git")
local config = require("gitsuite.config")
local gitfs = require("gitsuite.features.plugins.gitfs")

local M = {}

---The most output one git process may produce (bytes). A repository's author
---chooses how much `git log` prints; a legitimate range of a few thousand commits
---is a few megabytes.
M.MAX_OUTPUT = 32 * 1024 * 1024

---Verbs that only read. Anything else is refused by `check`.
---@type table<string, true>
M.READ_ONLY_VERBS = {
  ["log"] = true,
  ["rev-parse"] = true,
  ["cat-file"] = true,
}

---Options accepted as they are, for any allowed verb.
---@type table<string, true>
local PLAIN_OPTIONS = {
  ["-z"] = true,
  ["--no-color"] = true,
  ["--name-status"] = true,
  ["--no-renames"] = true,
  ["--root"] = true,
  ["--left-right"] = true,
  ["--no-merges"] = true,
  ["--first-parent"] = true,
  ["--reverse"] = true,
  ["--topo-order"] = true,
  ["--no-show-signature"] = true,
  ["--verify"] = true,
  ["--quiet"] = true,
  ["-q"] = true,
  ["-e"] = true,
  ["-t"] = true,
}

---Whether one option (an argument starting with `-`) is one this module passes.
---`--format=` values that would ask for a signature check are not: that starts
---the clone's configured gpg program.
---@param arg string
---@return boolean
local function option_allowed(arg)
  if PLAIN_OPTIONS[arg] then return true end
  if arg:match("^%-n%d+$") or arg:match("^%-%-max%-count=%d+$") or arg:match("^%-%-skip=%d+$") then
    return true
  end
  if arg:match("^%-%-encoding=[%w_%-]+$") then return true end
  local format = arg:match("^%-%-format=(.*)$")
  if format then return not (format:find("%G", 1, true) or format:find("%(signature", 1, true)) end
  return false
end

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
    if arg:sub(1, 1) == "-" and not option_allowed(arg) then
      return false, ("git option %s is not allowed here"):format(arg)
    end
  end
  return true, nil
end

---Verbs that produce a diff and so take `--no-textconv` / `--no-ext-diff`.
---@type table<string, true>
local DIFF_VERBS = { ["log"] = true }

---Config that makes git START A PROGRAM from a read-only command, pinned off
---through the environment (`GIT_CONFIG_COUNT`, git 2.31+, which beats the
---repository's and the user's config): the file-system monitor, signature
---checks and the gpg programs they would run.
---@type string[][]
local PINNED_CONFIG = {
  { "core.fsmonitor", "false" },
  { "log.showSignature", "false" },
  { "gpg.program", "false" },
  { "gpg.openpgp.program", "false" },
  { "gpg.x509.program", "false" },
  { "gpg.ssh.program", "false" },
}

---@return table<string, string>
local function pinned_env()
  local env = { GIT_CONFIG_COUNT = tostring(#PINNED_CONFIG) }
  for i, pair in ipairs(PINNED_CONFIG) do
    env["GIT_CONFIG_KEY_" .. (i - 1)] = pair[1]
    env["GIT_CONFIG_VALUE_" .. (i - 1)] = pair[2]
  end
  return env
end

---The options every process gets: bounded, offline, never asking for input,
---unable to start the clone's own programs, and pinned to the clone it was asked
---about.
---
---`GIT_DIR`/`GIT_WORK_TREE` are set to the clone: `-C <dir>` does not override
---a `GIT_DIR` the editor itself inherited (started from a hook, a dotfiles
---setup, lazygit), and git would then quietly read the wrong repository. A
---clone this feature reads always has its own `.git` directory. (This also
---switches off git's `safe.directory` ownership check, which is what the
---pinned config above makes up for.)
---@param dir string Absolute path of the clone.
---@param extra? table Merged over the result.
---@return Lib.Git.RunOpts
function M.opts(dir, extra)
  local env = vim.tbl_extend("force", pinned_env(), {
    GIT_TERMINAL_PROMPT = "0",
    GCM_INTERACTIVE = "never",
    LC_ALL = "C",
    GIT_DIR = dir .. "/.git",
    GIT_WORK_TREE = dir,
  })
  return vim.tbl_extend("force", {
    dir = dir,
    timeout_ms = config.get().plugins.timeout_ms,
    max_output_bytes = M.MAX_OUTPUT,
    no_lazy_fetch = true,
    env = env,
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

---A revision this module will put into a range: a hash, or a tag peeled to its
---commit (`refs/tags/<tag>^{commit}`). Nothing that starts with `-`, no
---abbreviation, no `..` -- the range is built by gluing two of these together.
---@param rev any
---@return boolean
function M.valid_rev(rev)
  if type(rev) ~= "string" then return false end
  if rev:match("^%x+$") and #rev >= 7 and #rev <= 64 then return true end
  local tag = rev:match("^refs/tags/(.+)%^{commit}$")
  return tag ~= nil and gitfs.valid_refname("refs/tags/" .. tag)
end

---Report a refused call the way a run would: through `on_done`, scheduled.
---@param on_done function
---@param ... any  What `on_done` gets.
---@return { stop: fun() } handle
local function refuse(on_done, ...)
  local args = { ... }
  vim.schedule(function()
    on_done(unpack(args, 1, 2))
  end)
  return { stop = function() end }
end

---A reason not to start git in `dir` at all, or nil.
---@param dir string
---@return string|nil
local function preflight(dir)
  local reason = gitfs.network_path(dir)
  if reason then return "refused: " .. reason end
  return nil
end

---Run an allowlisted read-only git command in `dir`.
---@param args string[] E.g. `{ "rev-parse", "--verify", "--quiet", sha .. "^{commit}" }`.
---@param dir string
---@param on_done fun(result: Lib.Git.RunResult|nil, err: string|nil) `vim.schedule`d.
---@return { stop: fun() } handle
function M.run(args, dir, on_done)
  local ok, err = M.check(args)
  if not ok then return refuse(on_done, nil, err) end
  local blocked = preflight(dir)
  if blocked then return refuse(on_done, nil, blocked) end
  return git.run_async(M.argv(args), M.opts(dir, { read_only = true }), function(res)
    on_done(res, nil)
  end)
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
    return refuse(on_done, nil, "not a usable revision for a range")
  end
  local blocked = preflight(dir)
  if blocked then return refuse(on_done, nil, blocked) end
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

---Whether `rev` names a commit this clone has -- `rev-parse --verify --quiet`,
---whose exit code tells "no such commit" (1) from "git could not run" (128, a
---missing git, a timeout, a broken config). Only the first is `false`; a
---failure is `nil` plus the reason, so the caller does not blame a force-push
---for a missing binary.
---@param dir string
---@param rev string
---@param on_done fun(has: boolean|nil, err: string|nil) `vim.schedule`d.
---@return { stop: fun() } handle
function M.has_commit(dir, rev, on_done)
  if not M.valid_rev(rev) then return refuse(on_done, false) end
  return M.run({ "rev-parse", "--verify", "--quiet", rev .. "^{commit}" }, dir, function(res, err)
    if not res then return on_done(nil, err) end
    if res.ok then return on_done(true) end
    if res.code == 1 and not res.timed_out and (res.signal or 0) == 0 then return on_done(false) end
    local reason = vim.trim(res.stderr or "")
    if res.timed_out then reason = "git timed out" end
    if reason == "" then reason = ("git failed (exit code %d)"):format(res.code) end
    on_done(nil, reason)
  end)
end

---The newest `n` commits of `dir`'s HEAD with their message and (by default)
---changed files -- **one** process. `--name-status --no-renames` reads trees
---only, so it works offline in a blobless clone.
---@param dir string
---@param n integer
---@param on_done fun(entries: Lib.Git.LogEntry[]|nil, err: string|nil) `vim.schedule`d.
---@param with_files? boolean  Ask for the changed files of every commit (default true). The buffer and clipboard listings never show them, and a commit that changes 100,000 files makes git print -- and Lua parse -- all of them.
---@return { stop: fun() } handle
function M.log(dir, n, on_done, with_files)
  local blocked = preflight(dir)
  if blocked then return refuse(on_done, nil, blocked) end
  return git.log_async(
    "HEAD",
    M.opts(dir, { max_count = n, name_status = with_files ~= false }),
    on_done
  )
end

return M
