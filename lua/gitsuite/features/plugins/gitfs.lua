---@module 'gitsuite.features.plugins.gitfs'
--- Reading a clone's state straight from its `.git` directory -- no git
--- process. Fifty clones take roughly a hundred milliseconds this way instead of
--- tens of seconds of spawns, which is what makes "did anything change?" cheap.
---
--- The `.git` directory of a plugin belongs to whoever published the plugin, so
--- nothing here trusts it:
---   * every file is a regular file read below `.git` through plain directories
---     -- not through a symlink or junction at ANY level (`.git/refs` pointing
---     at an outside folder is refused as much as `HEAD` doing so);
---   * every read is size-capped and parsed strictly: a ref name or a hash that
---     does not look like one is `nil`, not a surprise.
---
--- Covered: `HEAD`, loose and packed refs, tag names, the HEAD reflog, the
--- mtime of a non-empty `FETCH_HEAD`, `index.lock`. Anything that needs git's
--- object database (peeling an annotated loose tag, ancestry) is NOT here, and
--- neither is the `reftable` ref format (see `head`).

local repos = require("gitsuite.util.repos")
local uv = vim.uv or vim.loop

local M = {}

---Cap for HEAD, a loose ref, FETCH_HEAD, a symbolic ref.
M.MAX_SMALL = 64 * 1024
---Cap for packed-refs.
M.MAX_PACKED = 16 * 1024 * 1024
---Cap for the HEAD reflog; a bigger file is read from its tail (the recent end).
M.MAX_REFLOG = 4 * 1024 * 1024
---Longest reflog message kept.
M.MAX_MESSAGE = 200
---Latest time (year 2100) a reflog entry may claim; later ones are clamped.
M.MAX_TIME = 4102444800
---Upper bound on tag names listed from one clone.
M.MAX_TAGS = 20000
---A legitimate HEAD is a few dozen bytes; longer is not parsed at all.
M.MAX_HEAD = 4096

local IS_WIN = (uv.os_uname().sysname or ""):find("Windows", 1, true) ~= nil

---A hash as git writes it: 40 (SHA-1) or 64 (SHA-256) hex digits.
---@param s any
---@return boolean
function M.valid_sha(s)
  return type(s) == "string" and (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil
end

---A ref name that is safe to turn into a path below `.git/` and into a git
---argument. Follows git's own rules (`git check-ref-format`) instead of an
---allow-list of characters, so `fix/#12`, `feature/größe`, `release,2` and
---`v1(beta)` are fine; what is refused is what git refuses plus what could
---leave the folder or mean something to a file system.
---@param ref any
---@return boolean
function M.valid_refname(ref)
  if type(ref) ~= "string" or #ref > 255 or ref:sub(1, 5) ~= "refs/" then return false end
  -- control bytes and space, ~ ^ : ? * [ \ and the characters Windows forbids
  if ref:find('[%z\1-\32\127~^:?*%[\\"<>|]') then return false end
  if ref:find("..", 1, true) or ref:find("@{", 1, true) or ref:find("//", 1, true) then
    return false
  end
  if ref:sub(-1) == "/" or ref:sub(-1) == "." then return false end
  for component in ref:gmatch("[^/]+") do
    if
      component:sub(1, 1) == "."
      or component:sub(-1) == "."
      or component:sub(-5) == ".lock"
      or component == "@"
    then
      return false
    end
  end
  return true
end

---Read a regular file, bounded.
---@param path string
---@param max integer
---@param tail? boolean  With a file larger than `max`: read its last `max` bytes (dropping the cut first line) instead of refusing.
---@return string|nil text
---@return string|nil err
local function read_regular(path, max, tail)
  local st = uv.fs_lstat(path)
  if not st then return nil, "missing" end
  if st.type ~= "file" then return nil, "not a regular file" end
  local offset, length = 0, st.size
  if st.size > max then
    if not tail then return nil, "too large" end
    offset, length = st.size - max, max
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then return nil, "unreadable" end
  local data = length > 0 and uv.fs_read(fd, length, offset) or ""
  uv.fs_close(fd)
  if not data then return nil, "unreadable" end
  if offset > 0 then
    local newline = data:find("\n", 1, true)
    data = newline and data:sub(newline + 1) or ""
  end
  return data, nil
end

---@param dir string
---@return string
local function gitdir(dir)
  return dir .. "/.git"
end

---The path of `rel` below `<dir>/.git`, after checking that `.git` and every
---folder on the way are plain directories (not a symlink or junction).
---@param dir string
---@param rel string  e.g. `refs/heads/main`
---@return string|nil path
---@return string|nil err
local function under_git(dir, rel)
  local path = gitdir(dir)
  -- `.git` itself too: a symlink there would lead every read out of the clone.
  local root = uv.fs_lstat(path)
  if not root then return nil, "missing" end
  if root.type ~= "directory" then return nil, "not a plain folder" end
  local parts = vim.split(rel, "/", { plain = true })
  for i = 1, #parts - 1 do
    path = path .. "/" .. parts[i]
    local st = uv.fs_lstat(path)
    if not st then return nil, "missing" end
    if st.type ~= "directory" then return nil, "not a plain folder" end
  end
  return path .. "/" .. parts[#parts], nil
end

---Read a file below `.git` (see `under_git`).
---@param dir string
---@param rel string
---@param max integer
---@param tail? boolean
---@return string|nil text
---@return string|nil err
local function file_text(dir, rel, max, tail)
  local path, err = under_git(dir, rel)
  if not path then return nil, err end
  return read_regular(path, max, tail)
end

---What `<dir>/.git` is: `"clone"` (a directory, git's own state),
---`"file"` (a worktree or submodule: its state lives elsewhere), `"link"` (a
---symlink or junction, which is not followed), `"other"` or `"none"`.
---@param dir string
---@return "clone"|"file"|"link"|"other"|"none"
function M.clone_state(dir)
  local st = uv.fs_lstat(gitdir(dir))
  if not st then return "none" end
  if st.type == "directory" then return "clone" end
  if st.type == "file" then return "file" end
  if st.type == "link" then return "link" end
  return "other"
end

---Whether `dir` has its own `.git` directory (a worktree's `.git` file does not
---count: its state lives elsewhere).
---@param dir string
---@return boolean
function M.is_clone(dir)
  return M.clone_state(dir) == "clone"
end

---@class GitSuite.Plugins.PackedRef
---@field sha string
---@field peeled? string  The commit an annotated tag points at, when packed-refs records it.

---`packed-refs` as a map `refs/... -> { sha, peeled? }`. Cached per file
---signature (mtime, size): resolving a plugin's target reads it several times.
---@type table<string, { stamp: string, refs: table<string, GitSuite.Plugins.PackedRef>, incomplete: string|nil }>
local packed_cache = {}
local packed_cache_n = 0
---The one big (over 1 MiB of text) map held, see `packed_refs`.
---@type { path: string, stamp: string, refs: table, incomplete: string|nil }|nil
local big_packed

---@param dir string
---@return table<string, GitSuite.Plugins.PackedRef> refs
---@return string|nil incomplete  Why the map may lack refs (the file is over `MAX_PACKED`); `nil` when it is complete.
function M.packed_refs(dir)
  local path, perr = under_git(dir, "packed-refs")
  if not path then return {}, perr end
  local st = uv.fs_lstat(path)
  if not st then return {}, nil end -- no packed-refs: every ref is loose
  if st.type ~= "file" then
    -- a link or folder where git has a file: its refs cannot be listed from here
    return {}, "packed-refs is not a regular file"
  end
  local stamp = ("%d:%d:%d"):format(st.mtime.sec, st.mtime.nsec or 0, st.size)
  local cached = packed_cache[path]
  if cached and cached.stamp == stamp then return cached.refs, cached.incomplete end
  local big = big_packed
  if big and big.path == path and big.stamp == stamp then return big.refs, big.incomplete end

  local text, err = read_regular(path, M.MAX_PACKED)
  local refs = {}
  local incomplete
  if err == "too large" then
    incomplete = ("packed-refs is larger than %d MiB"):format(M.MAX_PACKED / 1024 / 1024)
  elseif not text then
    -- a read error (antivirus, a sharing violation) is not an empty file, and not
    -- worth remembering: the next read may succeed
    return {}, ("packed-refs could not be read (%s)"):format(err or "unreadable")
  else
    local last
    for line in text:gmatch("[^\r\n]+") do
      local sha, name = line:match("^(%x+) (refs/%S+)$")
      if sha and M.valid_sha(sha) and M.valid_refname(name) then
        last = { sha = sha }
        refs[name] = last
      elseif sha then
        -- a ref line we do not accept: its `^peeled` line must not attach to
        -- the previous (valid) tag
        last = nil
      else
        local peeled = line:match("^%^(%x+)$")
        if peeled and last and M.valid_sha(peeled) then last.peeled = peeled end
      end
    end
  end
  -- bounded: one entry per clone ever looked at would grow with every plugin
  -- that is installed and removed in a long session
  -- (a big map goes into its own single slot: the cache is bounded by entries,
  -- so its memory must be bounded per entry as well. A plugin's target needs the
  -- map several times in a row; only the last big one is ever held.)
  if text and #text > 1024 * 1024 then
    big_packed = { path = path, stamp = stamp, refs = refs, incomplete = incomplete }
    return refs, incomplete
  end
  if not packed_cache[path] then
    packed_cache_n = packed_cache_n + 1
    if packed_cache_n > 256 then
      packed_cache, packed_cache_n = {}, 1
    end
  end
  packed_cache[path] = { stamp = stamp, refs = refs, incomplete = incomplete }
  return refs, incomplete
end

---Why the refs of `dir` cannot all be read from files (an oversized
---`packed-refs`), or `nil`.
---@param dir string
---@return string|nil
function M.refs_incomplete(dir)
  local _, incomplete = M.packed_refs(dir)
  return incomplete
end

---The ref a symbolic ref points at (`refs/remotes/origin/HEAD` ->
---`refs/remotes/origin/main`), or `nil` when `ref` is not symbolic.
---@param dir string
---@param ref string
---@return string|nil
function M.symref(dir, ref)
  if not M.valid_refname(ref) and ref ~= "HEAD" then return nil end
  local text = file_text(dir, ref, M.MAX_SMALL)
  local target = text and text:match("^ref:%s*(%S+)")
  if target and M.valid_refname(target) then return target end
  return nil
end

---The commit a ref names: loose file first, then packed-refs; follows symbolic
---refs (a few hops). For an annotated tag this is the tag OBJECT -- see
---`tag_commit`.
---@param dir string
---@param ref string  `refs/heads/main`, `refs/remotes/origin/main`, ...
---@return string|nil sha
function M.ref(dir, ref)
  for _ = 1, 5 do
    if not M.valid_refname(ref) then return nil end
    local text = file_text(dir, ref, M.MAX_SMALL)
    if text then
      local sym = text:match("^ref:%s*(%S+)")
      if sym then
        ref = sym
      else
        local sha = text:match("^(%x+)")
        if M.valid_sha(sha) then return sha end
        return nil
      end
    else
      local packed = M.packed_refs(dir)[ref]
      return packed and packed.sha or nil
    end
  end
  return nil
end

---@class GitSuite.Plugins.Head
---@field sha? string     The commit HEAD resolves to (`nil` for an unborn branch).
---@field ref? string     `refs/heads/main` -- `nil` when detached.
---@field branch? string  `main`.
---@field detached boolean

---Where HEAD is. Lazy detaches HEAD on every update, so `sha` -- not the
---branch -- is what is installed.
---
---A clone in the `reftable` ref format (git 2.45+, `init.defaultRefFormat`) keeps
---a placeholder HEAD (`ref: refs/heads/.invalid`) and its refs in a binary
---table: nothing in this module can read those, and it says so instead of
---reporting a clone without commits.
---@param dir string
---@return GitSuite.Plugins.Head|nil head
---@return string|nil err
function M.head(dir)
  local text, err = file_text(dir, "HEAD", M.MAX_SMALL)
  if not text then return nil, err end
  if #text > M.MAX_HEAD then return nil, "unusual HEAD" end
  text = repos.rtrim(text)
  local ref = text:match("^ref:%s*(.+)$")
  if ref then
    if ref == "refs/heads/.invalid" then
      return nil, "reftable ref storage (not readable without a git process)"
    end
    if not M.valid_refname(ref) then return nil, "unusual HEAD" end
    return {
      ref = ref,
      branch = ref:match("^refs/heads/(.+)$"),
      sha = M.ref(dir, ref),
      detached = false,
    }
  end
  if M.valid_sha(text) then return { sha = text, detached = true } end
  return nil, "unrecognised HEAD"
end

---@param dir string
---@param prefix string  Path below `refs/tags/`.
---@param out table<string, true>
---@param count integer  Tags collected so far.
---@param depth integer
---@return integer count
local function scan_tags(dir, prefix, out, count, depth)
  if depth > 4 then return count end
  -- `refs` and `refs/tags` must be plain folders; deeper levels are only
  -- entered when the scan reports them as directories (a link shows as "link")
  local base = gitdir(dir) .. "/refs"
  local st = uv.fs_lstat(base)
  if not st or st.type ~= "directory" then return count end
  st = uv.fs_lstat(base .. "/tags")
  if not st or st.type ~= "directory" then return count end
  local handle = uv.fs_scandir(base .. "/tags/" .. prefix)
  if not handle then return count end
  while count < M.MAX_TAGS do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then break end
    local full = prefix .. name
    if kind == "directory" then
      count = scan_tags(dir, full .. "/", out, count, depth + 1)
    elseif kind == "file" and M.valid_refname("refs/tags/" .. full) and not out[full] then
      out[full] = true
      count = count + 1
    end
  end
  return count
end

---All tag names of a clone (loose and packed).
---@param dir string
---@return string[] names
---@return string|nil incomplete  Why the list may be missing tags (too many, or an oversized `packed-refs`); `nil` when complete.
function M.tag_names(dir)
  local set = {}
  local count = scan_tags(dir, "", set, 0, 0)
  local incomplete
  if count >= M.MAX_TAGS then incomplete = ("more than %d loose tags"):format(M.MAX_TAGS) end
  local packed, packed_incomplete = M.packed_refs(dir)
  incomplete = incomplete or packed_incomplete
  for ref in pairs(packed) do
    local name = ref:match("^refs/tags/(.+)$")
    if name then set[name] = true end
  end
  local names = vim.tbl_keys(set)
  table.sort(names)
  return names, incomplete
end

---The commit a tag points at, as far as files alone can tell.
---@param dir string
---@param tag string
---@return string|nil sha
---@return boolean certain  `true` when `sha` is known to be a commit; `false` for a loose tag, which may be an annotated tag OBJECT (peeling needs git).
function M.tag_commit(dir, tag)
  local ref = "refs/tags/" .. tag
  if not M.valid_refname(ref) then return nil, false end
  local text = file_text(dir, ref, M.MAX_SMALL)
  if text then
    local sha = text:match("^(%x+)")
    if M.valid_sha(sha) then return sha, false end
    return nil, false
  end
  local packed = M.packed_refs(dir)[ref]
  if not packed then return nil, false end
  -- A packed annotated tag carries its peeled commit; a packed lightweight tag
  -- IS the commit. (Only a file without the `fully-peeled` trait could blur
  -- this; git has written it since 1.8.)
  return packed.peeled or packed.sha, true
end

---@class GitSuite.Plugins.ReflogEntry
---@field old string
---@field new string
---@field time integer  Unix seconds.
---@field kind string   `checkout`, `pull`, `clone`, `commit`, ... (the word before the first `:`/space).
---@field message string

---The HEAD reflog of a clone, in file order (oldest first). File order is the
---truth: timestamps can go backwards across a clock change.
---@param dir string
---@return GitSuite.Plugins.ReflogEntry[]|nil entries  `nil` when there is no reflog file (the reflog expired, was never written or is not a regular file).
function M.reflog(dir)
  local text = file_text(dir, "logs/HEAD", M.MAX_REFLOG, true)
  if not text then return nil end
  local entries = {}
  for line in text:gmatch("[^\r\n]+") do
    local old, new, time, message = line:match("^(%x+) (%x+) [^\t]*> (%d+) [+-]%d%d%d%d\t(.*)$")
    local seconds = tonumber(time)
    -- A reflog is a file somebody else may have written (or a clock once went
    -- wrong): a time that is not a plausible Unix time must not become "the
    -- latest update" nor a number JSON cannot hold.
    if seconds and (seconds ~= seconds or seconds > M.MAX_TIME) then seconds = M.MAX_TIME end
    if old and seconds and M.valid_sha(old) and M.valid_sha(new) then
      entries[#entries + 1] = {
        old = old,
        new = new,
        time = seconds,
        kind = message:match("^([%a][%w%-]*)") or "?",
        message = message:sub(1, M.MAX_MESSAGE),
      }
    end
  end
  return entries
end

---Whether a reflog entry hash is the all-zero "before the first commit" hash.
---@param sha any
---@return boolean
function M.is_zero(sha)
  return type(sha) == "string" and sha:match("^0+$") ~= nil
end

---When the clone last fetched, if it did: the mtime of `FETCH_HEAD`, counted
---only when the file is non-empty (a failed fetch truncates it to 0 bytes while
---still touching it).
---@param dir string
---@return integer|nil epoch
function M.fetch_time(dir)
  -- (through `under_git`: a `.git` that is a symlink or junction is not followed)
  local path = under_git(dir, "FETCH_HEAD")
  local st = path and uv.fs_lstat(path)
  if not st or st.type ~= "file" or st.size == 0 then return nil end
  return st.mtime.sec
end

---Whether another git process holds the index (lazy is mid-update, or a stale
---lock is left behind).
---@param dir string
---@return boolean
function M.index_locked(dir)
  local path = under_git(dir, "index.lock")
  return path ~= nil and uv.fs_lstat(path) ~= nil
end

---Whether the first path of a text is a UNC/device path (`\\host\share`,
---`//host/share`), after the leading blanks and quotes git allows.
---@param text string
---@return boolean
local function starts_unc(text)
  local s = text:gsub('^[%s"]+', "")
  return s:match("^[/\\][/\\]") ~= nil
end

---`text` with C-style quoting undone (git writes odd paths as "\057\057host/..."
---in alternates) and a trailing-backslash line continuation joined.
---@param text string
---@return string
local function unquote(text)
  text = text:gsub("\\\r?\n", "")
  return (
    text
      :gsub("\\(%d%d%d)", function(octal)
        return string.char(tonumber(octal, 8) % 256)
      end)
      :gsub('\\([\\"nt])', { ["\\"] = "\\", ['"'] = '"', n = "\n", t = "\t" })
  )
end

---Longest include chain followed. Git itself allows ten; a longer one is refused.
local MAX_INCLUDE_DEPTH = 8

---Most distinct files read while following includes: a config cannot make this
---check cost more than that, however many `path =` lines it holds.
local MAX_INCLUDE_FILES = 16

---Config keys whose value a `git log` never touches: the address of a remote is
---only used when talking to it.
local INERT_KEYS = { url = true, pushurl = true }

---Whether a config file (and what it includes, a few levels deep) names a
---network path in any value. A file that cannot be followed with certainty (too
---deep, too many, a link, unreadable) counts as naming one.
---@param text string
---@param base string  Folder relative include paths are taken from.
---@param depth integer
---@param seen { n: integer, files: table<string, true> }  The files followed so far.
---@return boolean
local function config_has_unc(text, base, depth, seen)
  for line in unquote(text):gmatch("[^\r\n]+") do
    -- (an entry may follow a `[section]` header on the same line; the quoted
    -- subsection of `[includeIf "gitdir:**/[.]git/"]` may hold a `]`)
    local entry = line:gsub('^%s*%[[^"%]]*"[^"]*"%s*%]', ""):gsub("^%s*%[[^%]]*%]", "")
    local key, value = entry:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
    key = key and key:lower()
    if value and not INERT_KEYS[key] and starts_unc(value) then return true end
    if key == "path" and value and value ~= "" then
      -- a chain git would still follow, but this check does not: refused
      if depth == 0 then return true end
      -- (a quoted value ends at its closing quote, an unquoted one at a comment)
      local included = value:match('^"([^"]*)"') or (value:gsub("%s*[;#].*$", ""))
      if
        not included:match("^~")
        and not included:match("^%a:")
        and not included:match("^[/\\]")
      then
        -- (relative to the file that includes it, as git resolves it)
        local file = base .. "/" .. included
        if not seen.files[file] then
          seen.files[file] = true
          seen.n = seen.n + 1
          if seen.n > MAX_INCLUDE_FILES then return true end
          local inner, err = read_regular(file, 256 * 1024)
          if inner then
            if config_has_unc(inner, vim.fs.dirname(file), depth - 1, seen) then return true end
          elseif err ~= "missing" then
            -- (git skips a missing include too; anything else cannot be judged)
            return true
          end
        end
      end
    end
  end
  return false
end

---On Windows: a reason when the clone's own files point git at a NETWORK path
----- an object alternate, a `commondir`, a value in `.git/config` (an
---`include.path`, `mailmap.file`, ...) or in a file it includes. Every git
---process of this feature would touch that path first, and an SMB connection to
---somebody else's server leaks the user's NTLM hash and stalls until the
---timeout. A file that cannot be read in full (too large, unreadable) is
---refused too. `nil` elsewhere (a leading `//` is a plain local path on POSIX)
---and when nothing points off the machine.
---@param dir string
---@return string|nil reason
function M.network_path(dir)
  if not IS_WIN then return nil end
  ---@param rel string
  ---@param max integer
  ---@return string|nil text
  ---@return string|nil refusal
  local function read(rel, max)
    local text, err = file_text(dir, rel, max)
    if text then return text, nil end
    if err == "missing" then return nil, nil end
    -- too large, unreadable, a link or junction (git follows those): not judged
    return nil, ("%s cannot be read safely (%s)"):format(rel, err or "unreadable")
  end

  local alternates, refusal = read("objects/info/alternates", M.MAX_SMALL)
  if refusal then return refusal end
  if alternates then
    for line in unquote(alternates):gmatch("[^\r\n]+") do
      if starts_unc(line) then return "its object alternates point at a network path" end
    end
  end
  local commondir
  commondir, refusal = read("commondir", M.MAX_SMALL)
  if refusal then return refusal end
  if commondir and starts_unc(unquote(commondir)) then
    return "its commondir points at a network path"
  end
  -- (`config.worktree` is read by git when `extensions.worktreeConfig` is on)
  for _, name in ipairs({ "config", "config.worktree" }) do
    local config
    config, refusal = read(name, 256 * 1024)
    if refusal then return refusal end
    local seen = { n = 0, files = {} }
    if config and config_has_unc(config, gitdir(dir), MAX_INCLUDE_DEPTH, seen) then
      return "its config names a file on a network path"
    end
  end
  return nil
end

return M
