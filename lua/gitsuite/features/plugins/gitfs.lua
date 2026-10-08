---@module 'gitsuite.features.plugins.gitfs'
--- Reading a clone's state straight from its `.git` directory -- no git
--- process. Fifty clones take a few dozen milliseconds this way instead of
--- tens of seconds of spawns, which is what makes "did anything change?" free.
---
--- The `.git` directory of a plugin belongs to whoever published the plugin, so
--- nothing here trusts it: every file is a regular file (no symlink, FIFO or
--- device), is read with a size cap, and is parsed strictly -- a ref name or a
--- hash that does not look like one is `nil`, not a surprise.
---
--- Covered: `HEAD`, loose and packed refs, tag names, the HEAD reflog, the
--- mtime of a non-empty `FETCH_HEAD`, `index.lock`. Anything that needs git's
--- object database (peeling an annotated loose tag, ancestry) is NOT here.

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

---A hash as git writes it: 40 (SHA-1) or 64 (SHA-256) hex digits.
---@param s any
---@return boolean
function M.valid_sha(s)
  return type(s) == "string" and (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil
end

---@param s any
---@return boolean
local function is_zero_sha(s)
  return type(s) == "string" and s:match("^0+$") ~= nil
end

---A ref name that is safe to turn into a path below `.git/`.
---@param ref any
---@return boolean
function M.valid_refname(ref)
  return type(ref) == "string"
    and #ref <= 255
    and ref:match("^refs/[%w%._%-+@/]+$") ~= nil
    and not ref:find("..", 1, true)
    and not ref:find("//", 1, true)
    and ref:sub(-1) ~= "/"
    and ref:sub(-5) ~= ".lock"
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

---Whether `dir` has its own `.git` directory (a worktree's `.git` file does not
---count: its state lives elsewhere).
---@param dir string
---@return boolean
function M.is_clone(dir)
  local st = uv.fs_lstat(gitdir(dir))
  return st ~= nil and st.type == "directory"
end

---@class GitSuite.Plugins.PackedRef
---@field sha string
---@field peeled? string  The commit an annotated tag points at, when packed-refs records it.

---`packed-refs` as a map `refs/... -> { sha, peeled? }`. Cached per file
---signature (mtime, size): resolving a plugin's target reads it several times.
---@type table<string, { stamp: string, refs: table<string, GitSuite.Plugins.PackedRef> }>
local packed_cache = {}

---@param dir string
---@return table<string, GitSuite.Plugins.PackedRef>
function M.packed_refs(dir)
  local path = gitdir(dir) .. "/packed-refs"
  local st = uv.fs_lstat(path)
  if not st or st.type ~= "file" then return {} end
  local stamp = ("%d:%d:%d"):format(st.mtime.sec, st.mtime.nsec or 0, st.size)
  local cached = packed_cache[path]
  if cached and cached.stamp == stamp then return cached.refs end

  local text = read_regular(path, M.MAX_PACKED)
  local refs = {}
  if text then
    local last
    for line in text:gmatch("[^\r\n]+") do
      local sha, name = line:match("^(%x+) (refs/%S+)$")
      if sha and M.valid_sha(sha) and M.valid_refname(name) then
        last = { sha = sha }
        refs[name] = last
      else
        local peeled = line:match("^%^(%x+)$")
        if peeled and last and M.valid_sha(peeled) then last.peeled = peeled end
      end
    end
  end
  packed_cache[path] = { stamp = stamp, refs = refs }
  return refs
end

---The ref a symbolic ref points at (`refs/remotes/origin/HEAD` ->
---`refs/remotes/origin/main`), or `nil` when `ref` is not symbolic.
---@param dir string
---@param ref string
---@return string|nil
function M.symref(dir, ref)
  if not M.valid_refname(ref) and ref ~= "HEAD" then return nil end
  local text = read_regular(gitdir(dir) .. "/" .. ref, M.MAX_SMALL)
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
    local text = read_regular(gitdir(dir) .. "/" .. ref, M.MAX_SMALL)
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
---@param dir string
---@return GitSuite.Plugins.Head|nil head
---@return string|nil err
function M.head(dir)
  local text, err = read_regular(gitdir(dir) .. "/HEAD", M.MAX_SMALL)
  if not text then return nil, err end
  text = text:gsub("%s+$", "")
  local ref = text:match("^ref:%s*(.+)$")
  if ref then
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

---Upper bound on tag names listed from one clone.
local MAX_TAGS = 20000

---@param dir string
---@param prefix string  Path below `refs/tags/`.
---@param out table<string, true>
---@param count integer  Tags collected so far.
---@param depth integer
---@return integer count
local function scan_tags(dir, prefix, out, count, depth)
  if depth > 4 then return count end
  local handle = uv.fs_scandir(gitdir(dir) .. "/refs/tags/" .. prefix)
  if not handle then return count end
  while count < MAX_TAGS do
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
---@return string[]
function M.tag_names(dir)
  local set = {}
  scan_tags(dir, "", set, 0, 0)
  for ref in pairs(M.packed_refs(dir)) do
    local name = ref:match("^refs/tags/(.+)$")
    if name then set[name] = true end
  end
  local names = vim.tbl_keys(set)
  table.sort(names)
  return names
end

---The commit a tag points at, as far as files alone can tell.
---@param dir string
---@param tag string
---@return string|nil sha
---@return boolean certain  `true` when `sha` is known to be a commit; `false` for a loose tag, which may be an annotated tag OBJECT (peeling needs git).
function M.tag_commit(dir, tag)
  local ref = "refs/tags/" .. tag
  if not M.valid_refname(ref) then return nil, false end
  local text = read_regular(gitdir(dir) .. "/" .. ref, M.MAX_SMALL)
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
  local text = read_regular(gitdir(dir) .. "/logs/HEAD", M.MAX_REFLOG, true)
  if not text then return nil end
  local entries = {}
  for line in text:gmatch("[^\r\n]+") do
    local old, new, time, message = line:match("^(%x+) (%x+) [^\t]*> (%d+) [+-]%d%d%d%d\t(.*)$")
    if old and M.valid_sha(old) and M.valid_sha(new) then
      entries[#entries + 1] = {
        old = old,
        new = new,
        time = tonumber(time),
        kind = message:match("^([%a][%w%-]*)") or "?",
        message = message:sub(1, M.MAX_MESSAGE),
      }
    end
  end
  return entries
end

---Whether a reflog entry is the all-zero "before the first commit" hash.
---@param sha string
---@return boolean
function M.is_zero(sha)
  return is_zero_sha(sha)
end

---When the clone last fetched, if it did: the mtime of `FETCH_HEAD`, counted
---only when the file is non-empty (a failed fetch truncates it to 0 bytes while
---still touching it).
---@param dir string
---@return integer|nil epoch
function M.fetch_time(dir)
  local st = uv.fs_lstat(gitdir(dir) .. "/FETCH_HEAD")
  if not st or st.type ~= "file" or st.size == 0 then return nil end
  return st.mtime.sec
end

---Whether another git process holds the index (lazy is mid-update, or a stale
---lock is left behind).
---@param dir string
---@return boolean
function M.index_locked(dir)
  return uv.fs_lstat(gitdir(dir) .. "/index.lock") ~= nil
end

return M
