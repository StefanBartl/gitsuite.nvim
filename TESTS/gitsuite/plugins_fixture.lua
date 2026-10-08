-- TESTS/gitsuite/plugins_fixture.lua -- throwaway git repositories for the
-- `plugins_*_spec.lua` files. Not a spec (no `_spec` suffix): a spec loads it with
--
--   local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
--   local F = dofile(dir .. "plugins_fixture.lua")()
--
-- and calls `F.cleanup()` in `after_each`/at the end. Everything lives under
-- `vim.fn.tempname()`, never inside the checkout under test.
return function()
  local F = {}
  local created = {} ---@type string[]

  local BASE = {
    "git",
    "-c",
    "user.name=gitsuite-spec",
    "-c",
    "user.email=spec@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.autocrlf=false",
    "-c",
    "protocol.file.allow=always",
  }

  ---@param suffix? string
  ---@return string
  function F.tmpdir(suffix)
    local dir = vim.fn.tempname() .. (suffix or "")
    vim.fn.mkdir(dir, "p")
    created[#created + 1] = dir
    return dir
  end

  ---@param dir string
  ---@param args string[]
  ---@param opts? { env?: table<string, string>, allow_fail?: boolean }
  ---@return string stdout
  ---@return integer code
  function F.git(dir, args, opts)
    opts = opts or {}
    local argv = vim.list_extend(vim.deepcopy(BASE), { "-C", dir })
    vim.list_extend(argv, args)
    local res = vim.system(argv, { text = true, env = opts.env }):wait()
    if not opts.allow_fail then
      assert(
        res.code == 0,
        ("fixture: git %s failed (%d): %s"):format(table.concat(args, " "), res.code, res.stderr)
      )
    end
    return vim.trim(res.stdout or ""), res.code
  end

  ---@param path string
  ---@param text string
  function F.write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---A new repository on branch `main`.
  ---@param suffix? string
  ---@return string
  function F.init(suffix)
    local dir = F.tmpdir(suffix)
    F.git(dir, { "init", "-q", "-b", "main" })
    return dir
  end

  ---Stage everything and commit `message` verbatim. `when` pins the dates
  ---(git's raw date form needs a plausible, 9+ digit epoch).
  ---@param dir string
  ---@param message string
  ---@param when? integer
  ---@return string sha
  function F.commit(dir, message, when)
    local stamp = ("%d +0000"):format(when or 1700000000)
    local msg_file = vim.fn.tempname()
    F.write(msg_file, message)
    F.git(dir, { "add", "-A" })
    F.git(
      dir,
      { "commit", "-q", "--allow-empty", "--cleanup=verbatim", "-F", msg_file },
      { env = { GIT_AUTHOR_DATE = stamp, GIT_COMMITTER_DATE = stamp } }
    )
    vim.fn.delete(msg_file)
    return (F.git(dir, { "rev-parse", "HEAD" }))
  end

  ---Run a `git fast-import` stream in `dir` -- one process for any number of
  ---commits and refs (a spawn costs 100+ ms on Windows, so building a history
  ---commit by commit makes a spec file crawl). Returns the hash of every mark.
  ---@param dir string
  ---@param stream string
  ---@return table<integer, string> marks  `marks[n]` is the hash of `:n`.
  function F.fast_import(dir, stream)
    local marks_file = vim.fn.tempname()
    local argv = vim.list_extend(vim.deepcopy(BASE), {
      "-C",
      dir,
      "fast-import",
      "--quiet",
      "--export-marks=" .. marks_file,
    })
    local res = vim.system(argv, { stdin = stream, text = true }):wait()
    assert(res.code == 0, "fixture: fast-import failed: " .. (res.stderr or ""))
    local marks = {}
    for line in io.lines(marks_file) do
      local n, sha = line:match("^:(%d+) (%x+)$")
      if n then marks[tonumber(n)] = sha end
    end
    vim.fn.delete(marks_file)
    return marks
  end

  ---A fast-import `data` block.
  ---@param s string
  ---@return string
  function F.data(s)
    return ("data %d\n%s\n"):format(#s, s)
  end

  ---`n` linear commits on `branch` (file `f.txt` holds the commit number),
  ---dated `first + 100 * i`. Mark `:i` is commit `i`.
  ---@param dir string
  ---@param n integer
  ---@param opts? { branch?: string, first?: integer, extra?: string }  `extra` is more stream text appended (tags, resets).
  ---@return string[] shas
  function F.history(dir, n, opts)
    opts = opts or {}
    local branch = opts.branch or "main"
    local first = opts.first or 1700000000
    local parts = {}
    for i = 1, n do
      parts[#parts + 1] = ("commit refs/heads/%s\nmark :%d\ncommitter T <t@example.invalid> %d +0000\n"):format(
        branch,
        i,
        first + 100 * i
      ) .. F.data("c" .. i) .. (i > 1 and ("from :%d\n"):format(i - 1) or "") .. "M 100644 inline f.txt\n" .. F.data(
        i .. "\n"
      ) .. "\n"
    end
    local marks = F.fast_import(dir, table.concat(parts) .. (opts.extra or ""))
    local shas = {}
    for i = 1, n do
      shas[i] = marks[i]
    end
    return shas
  end

  function F.cleanup()
    for _, dir in ipairs(created) do
      vim.fn.delete(dir, "rf")
    end
    created = {}
  end

  return F
end
