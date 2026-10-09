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
---`//host/share`, and the NT forms `\??\UNC\host\share` git also reads), after
---the leading blanks and quotes git allows.
---@param text string
---@return boolean
local function starts_unc(text)
  local s = text:gsub('^[%s"]+', "")
  return s:match("^[/\\][/\\]") ~= nil or s:match("^[/\\]%?%?[/\\]") ~= nil
end

local C_ESC = {
  a = "\a",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
  v = "\v",
  ["\\"] = "\\",
  ['"'] = '"',
}

---A line that starts with `"`, the way git's `unquote_c_style` reads it: one
---pass (an octal `\134` is a backslash and stays one), up to the closing quote;
---whatever follows the closing quote is ignored. `nil` when git would not take
---it as a quoted string (it then uses the line as it is).
---@param line string
---@return string|nil
local function unquote_c_style(line)
  local out, i = {}, 2
  while i <= #line do
    local c = line:sub(i, i)
    if c == '"' then return table.concat(out) end
    if c ~= "\\" then
      out[#out + 1], i = c, i + 1
    else
      local octal = line:match("^[0-3][0-7][0-7]", i + 1)
      if octal then
        out[#out + 1], i = string.char(tonumber(octal, 8)), i + 4
      else
        local esc = C_ESC[line:sub(i + 1, i + 1)]
        if not esc then return nil end
        out[#out + 1], i = esc, i + 2
      end
    end
  end
  return nil
end

---Longest include chain followed. Git itself allows ten; a longer one is refused.
local MAX_INCLUDE_DEPTH = 8

---Most distinct files read while following includes: a config cannot make this
---check cost more than that, however many `path =` lines it holds.
local MAX_INCLUDE_FILES = 16

---Most bytes of config text looked at in one check (all files together): the
---check runs on the main thread before every git call.
local MAX_CONFIG_BYTES = 512 * 1024

---Config keys whose value a `git log` never touches: the address of a remote is
---only used when talking to it.
local INERT_KEYS = { url = true, pushurl = true }

---Every `key = value` of a git config, read the way git's own parser does
---(config.c `git_parse_source`): a BOM at the start is skipped, any number of
---`[headers]` on a line (a quoted subsection may hold `]` and `\"`), a `;`/`#`
---comment ends at the line end (a trailing backslash does NOT continue it),
---values are unquoted (`"..."`, the escapes `\" \ \n \t \b`, backslash-newline
---joins) and cut at a comment. `nil` for text git itself would reject.
---@param text string
---@return { [1]: string, [2]: string|nil }[]|nil entries  `{ key, value }` pairs, key as written.
local function config_entries(text)
  local out, i, n = {}, 1, #text
  if text:sub(1, 3) == "\239\187\191" then i = 4 end
  local function skip_line()
    local nl = text:find("\n", i, true)
    i = nl and nl + 1 or n + 1
  end
  local ESC = { n = "\n", t = "\t", b = "\b", ['"'] = '"', ["\\"] = "\\" }
  while i <= n do
    local c = text:sub(i, i)
    if c == ";" or c == "#" then
      skip_line()
    elseif c:find("%s") then
      i = i + 1
    elseif c == "[" then
      i = i + 1
      local quoted = false
      while true do
        c = text:sub(i, i)
        if c == "" or c == "\n" then return nil end
        i = i + 1
        if quoted and c == "\\" then
          i = i + 1
        elseif c == '"' then
          quoted = not quoted
        elseif c == "]" and not quoted then
          break
        end
      end
    else
      local key = text:match("^%a[%w%-]*", i)
      if not key then return nil end
      i = i + #key
      i = i + #text:match("^[ \t\r]*", i)
      local c2 = text:sub(i, i)
      if c2 == "=" then
        i = i + 1
        local buf, quoted, pending = {}, false, 0
        while i <= n do
          c = text:sub(i, i)
          i = i + 1
          if c == "\n" then
            if quoted then return nil end
            break
          elseif c == "\\" then
            local e = text:sub(i, i)
            i = i + 1
            if e == "" then break end -- a backslash at the very end
            if e == "\r" and text:sub(i, i) == "\n" then
              e, i = "\n", i + 1
            end
            if e ~= "\n" then
              if not ESC[e] then return nil end
              buf[#buf + 1] = (" "):rep(pending) .. ESC[e]
              pending = 0
            end
          elseif c == '"' then
            quoted = not quoted
          elseif not quoted and c:find("%s") then
            if #buf > 0 then pending = pending + 1 end
          elseif not quoted and (c == ";" or c == "#") then
            skip_line()
            break
          else
            buf[#buf + 1] = (" "):rep(pending) .. c
            pending = 0
          end
        end
        if quoted then return nil end
        out[#out + 1] = { key, table.concat(buf) }
      elseif c2 == "" or c2 == "\n" or c2 == ";" or c2 == "#" then
        out[#out + 1] = { key }
      else
        return nil
      end
    end
  end
  return out
end

---Where an `include.path` value leads, as git resolves it: `~/` is the home
---folder, a relative path is taken from the including file's folder, an
---absolute path is itself. `nil` for what cannot be resolved here (`~user`,
---`%(prefix)/...`).
---@param base string
---@param path string
---@return string|nil
local function include_file(base, path)
  if path:match("^~[/\\]") then
    local home = uv.os_homedir()
    return home and (home:gsub("\\", "/") .. path:sub(2)) or nil
  end
  if path:match("^[~%%]") then return nil end
  if path:match("^%a:") or path:match("^[/\\]") then return path end
  return base .. "/" .. path
end

local NET_REASON = "its config names a file on a network path"

---Whether a config file (and what it includes, a few levels deep) names a
---network path in any value. A file that cannot be followed with certainty (too
---deep, too many, too much text, a link, unreadable, unparsable) is a reason too.
---@param text string
---@param base string  Folder relative include paths are taken from (the including file's own).
---@param depth integer
---@param seen { n: integer, bytes: integer, files: table<string, true> }  What was followed so far.
---@return string|nil reason
local function config_reason(text, base, depth, seen)
  seen.bytes = seen.bytes + #text
  if seen.bytes > MAX_CONFIG_BYTES then return "its config files are too large to check" end
  local entries = config_entries(text)
  if not entries then return "its config could not be parsed" end
  for _, entry in ipairs(entries) do
    local key, value = entry[1]:lower(), entry[2]
    if value and not INERT_KEYS[key] and starts_unc(value) then return NET_REASON end
    if key == "path" and value and value ~= "" then
      if depth == 0 then return "its config includes are nested too deep to check" end
      local file = include_file(base, value)
      if not file then return "an include of its config cannot be resolved" end
      if not seen.files[file] then
        seen.files[file] = true
        seen.n = seen.n + 1
        if seen.n > MAX_INCLUDE_FILES then return "its config includes too many files" end
        local inner, err = read_regular(file, 256 * 1024)
        if inner then
          local reason = config_reason(inner, vim.fs.dirname(file), depth - 1, seen)
          if reason then return reason end
        elseif err ~= "missing" then
          -- (git skips a missing include too; anything else cannot be judged)
          return ("an included config cannot be read safely (%s)"):format(err or "unreadable")
        end
      end
    end
  end
  return nil
end

---Git follows a chain of `objects/info/alternates` files this deep.
local MAX_ALT_DEPTH = 5

---@param root string  A git directory (or any folder) whose plain-folder path `rel` is taken below.
---@param rel string
---@return string|nil path
---@return string|nil err
local function under_root(root, rel)
  local st0 = uv.fs_lstat(root)
  if not st0 then return nil, "missing" end
  if st0.type ~= "directory" then return nil, "not a plain folder" end
  local path = root
  local parts = vim.split(rel, "/", { plain = true })
  for i = 1, #parts - 1 do
    path = path .. "/" .. parts[i]
    local st = uv.fs_lstat(path)
    if not st then return nil, "missing" end
    if st.type ~= "directory" then return nil, "not a plain folder" end
  end
  return path .. "/" .. parts[#parts], nil
end

---@param root string
---@param rel string
---@param max integer
---@return string|nil text
---@return string|nil refusal
local function read_under(root, rel, max)
  local path, err = under_root(root, rel)
  local text
  if path then
    text, err = read_regular(path, max)
  end
  if text then return text, nil end
  if err == "missing" then return nil, nil end
  return nil, ("%s cannot be read safely (%s)"):format(rel, err or "unreadable")
end

---The alternates of one `objects` folder, and (git follows them) of every local
---folder they name.
---@param objdir string
---@param depth integer
---@return string|nil refusal
local function alternates_refusal(objdir, depth)
  local text, refusal = read_under(objdir, "info/alternates", M.MAX_SMALL)
  if refusal then return refusal end
  if not text then return nil end
  for line in text:gmatch("[^\r\n]+") do
    -- (git unquotes an entry only when it starts with a quote, in one pass, and
    -- ignores what follows the closing quote; a plain entry is raw, and on
    -- Windows full of backslashes that are not escapes. Both forms are looked at.)
    local trimmed = vim.trim(line)
    local entry = trimmed
    if trimmed:sub(1, 1) == '"' then entry = unquote_c_style(trimmed) or trimmed end
    if starts_unc(trimmed) or starts_unc(entry) then
      return "its object alternates point at a network path"
    end
    if entry ~= "" and entry:sub(1, 1) ~= "#" then
      if depth == 0 then return "its object alternates are chained too deep to judge" end
      local nested = (entry:match("^%a:") or entry:match("^[/\\]")) and entry
        or (objdir .. "/" .. entry)
      refusal = alternates_refusal(nested, depth - 1)
      if refusal then return refusal end
    end
  end
  return nil
end

---@param gd string  A git directory.
---@param is_common boolean  `gd` was named by a `commondir` file (whose own `commondir` git ignores).
---@return string|nil refusal
local function gitdir_refusal(gd, is_common)
  local st = uv.fs_lstat(gd)
  if not st then return nil end
  -- (first of all: a link here would let every read below go through it)
  if st.type ~= "directory" then return "its git directory is not a plain folder" end
  -- Git reads `config.worktree` of the folder it was started in, and `config` of
  -- the common folder; looking at both of each is the cautious reading.
  local seen = { n = 0, bytes = 0, files = {} }
  for _, name in ipairs({ "config", "config.worktree" }) do
    local config, refusal = read_under(gd, name, 256 * 1024)
    if refusal then return refusal end
    local reason = config and config_reason(config, gd, MAX_INCLUDE_DEPTH, seen)
    if reason then return reason end
  end
  local refusal = alternates_refusal(gd .. "/objects", MAX_ALT_DEPTH)
  if refusal then return refusal end
  if not is_common then
    local commondir
    commondir, refusal = read_under(gd, "commondir", M.MAX_SMALL)
    if refusal then return refusal end
    if commondir then
      -- (read raw, as git does)
      local c = vim.trim(commondir)
      if starts_unc(c) then return "its commondir points at a network path" end
      local resolved = (c:match("^%a:") or c:match("^[/\\]")) and c or (gd .. "/" .. c)
      return gitdir_refusal(resolved, true)
    end
  end
  return nil
end

---Verdicts of `network_path` by clone: the git calls of one action come in a
---burst, and the check is several file reads on the main thread.
---@type table<string, { at: number, reason: string|nil }>
local verdicts = {}
local verdicts_n = 0
local VERDICT_TTL_MS = 2000

---On Windows: a reason when the clone's own files point git at a NETWORK path
----- an object alternate (and the alternates of the local folders it chains
---through), a `commondir` (and the config behind it), a value in `.git/config`
---or `config.worktree` (an `include.path`, `mailmap.file`, ...) or in a file
---they include. Every git process of this feature would touch that path first,
---and an SMB connection to somebody else's server leaks the user's NTLM hash and
---stalls until the timeout. What cannot be judged -- a file too large or
---unreadable, a link or junction, a config git would reject, a chain too deep --
---is refused too. `nil` elsewhere (a leading `//` is a plain local path on POSIX)
---and when nothing points off the machine. The verdict is kept for two seconds.
---@param dir string
---@return string|nil reason
function M.network_path(dir)
  if not IS_WIN then return nil end
  local now = uv.hrtime() / 1e6
  local hit = verdicts[dir]
  if hit and now - hit.at < VERDICT_TTL_MS then return hit.reason end
  local reason = gitdir_refusal(gitdir(dir), false)
  if not hit then
    verdicts_n = verdicts_n + 1
    if verdicts_n > 256 then
      verdicts, verdicts_n = {}, 1
    end
  end
  verdicts[dir] = { at = now, reason = reason }
  return reason
end

---Forget the kept verdicts (for specs, which rewrite a clone's files).
function M.forget_network_verdicts()
  verdicts, verdicts_n = {}, 0
end

---The config parser, for specs: it is the same on every platform.
M._config_entries = config_entries

return M
