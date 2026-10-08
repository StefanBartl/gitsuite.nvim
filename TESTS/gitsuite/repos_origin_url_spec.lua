-- TESTS/gitsuite/repos_origin_url_spec.lua -- `util.repos.origin_url`: the origin URL
-- read from `.git/config` without git -- the parts of the config grammar that matter.
---@diagnostic disable: undefined-field -- luassert extends `assert` beyond stock Lua's.
local dir_of_spec = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("gitsuite util.repos.origin_url", function()
  local F = dofile(dir_of_spec .. "plugins_fixture.lua")()
  local repos = require("gitsuite.util.repos")

  after_each(function()
    F.cleanup()
  end)

  ---A directory whose `.git/config` is exactly `config` (no git involved).
  local function with_config(config)
    local dir = F.init("-origin-url")
    local f = assert(io.open(dir .. "/.git/config", "wb"))
    f:write(config)
    f:close()
    return dir
  end

  it("reads a plain url", function()
    local dir =
      with_config('[core]\n\tbare = false\n[remote "origin"]\n\turl = https://h/o/r.git\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
  end)

  it("ignores another remote and a url outside the origin section", function()
    local dir = with_config('[remote "up"]\n\turl = https://h/up.git\n[core]\n\turl = nope\n')
    assert.is_nil(repos.origin_url(dir))
  end)

  it("takes the section and key names case-insensitively, the remote name exactly", function()
    local dir = with_config('[REMOTE "origin"]\n\tURL = https://h/o/r.git\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
    dir = with_config('[remote "Origin"]\n\turl = https://h/x.git\n')
    assert.is_nil(repos.origin_url(dir))
  end)

  it("strips a trailing comment and the quotes around a value", function()
    local dir = with_config('[remote "origin"]\n\turl = https://h/o/r.git ; the main one\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
    dir = with_config('[remote "origin"]\n\turl = "https://h/o/r#frag.git" # quoted\n')
    assert.equals("https://h/o/r#frag.git", repos.origin_url(dir))
  end)

  it("does not read a commented-out url", function()
    local dir =
      with_config('[remote "origin"]\n\t; url = https://h/old.git\n\t# url = https://h/older.git\n')
    assert.is_nil(repos.origin_url(dir))
  end)

  it("reads an entry on the header line and a section header with a comment", function()
    local dir = with_config('[remote "origin"] url = https://h/o/r.git\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
    dir = with_config('[remote "origin"] ; main\n\turl = https://h/o/r.git\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
  end)

  it("reads a config with CRLF line endings", function()
    local dir = with_config('[remote "origin"]\r\n\turl = https://h/o/r.git\r\n')
    assert.equals("https://h/o/r.git", repos.origin_url(dir))
  end)

  it("is nil without a config, and for a config that is too large", function()
    local dir = F.init("-origin-url-none")
    os.remove(dir .. "/.git/config")
    assert.is_nil(repos.origin_url(dir))
    dir = with_config('[remote "origin"]\n\turl = https://h/o/r.git\n' .. ("#"):rep(300000))
    assert.is_nil(repos.origin_url(dir))
  end)
end)
