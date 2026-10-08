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

  function F.cleanup()
    for _, dir in ipairs(created) do
      vim.fn.delete(dir, "rf")
    end
    created = {}
  end

  return F
end
