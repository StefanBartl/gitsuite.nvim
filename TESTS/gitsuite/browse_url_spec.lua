-- TESTS/gitsuite/browse_url_spec.lua -- pure remote-URL parsing/building,
-- no git/vim.api dependency.
describe("gitsuite.features.browse.url", function()
  local url = require("gitsuite.features.browse.url")

  describe("parse_remote", function()
    it("parses an https URL", function()
      local r = url.parse_remote("https://github.com/StefanBartl/gitsuite.nvim.git")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ host = "github.com", owner = "StefanBartl", repo = "gitsuite.nvim" }, r)
    end)

    it("parses an https URL without a trailing .git", function()
      local r = url.parse_remote("https://gitlab.com/owner/repo")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ host = "gitlab.com", owner = "owner", repo = "repo" }, r)
    end)

    it("parses an SSH shorthand URL (git@host:owner/repo.git)", function()
      local r = url.parse_remote("git@codeberg.org:owner/repo.git")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ host = "codeberg.org", owner = "owner", repo = "repo" }, r)
    end)

    it("parses an ssh:// URL", function()
      local r = url.parse_remote("ssh://git@github.com/owner/repo.git")
      ---@diagnostic disable-next-line: undefined-field
      assert.same({ host = "github.com", owner = "owner", repo = "repo" }, r)
    end)

    it("returns nil for garbage input", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_nil(url.parse_remote("not a remote url"))
    end)
  end)

  describe("host_kind", function()
    it("recognizes the three built-in hosts without any config", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("github", url.host_kind("github.com", {}))
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("gitlab", url.host_kind("gitlab.com", {}))
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("codeberg", url.host_kind("codeberg.org", {}))
    end)

    it("looks up a self-hosted instance from the given hosts table", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals("gitlab", url.host_kind("git.example.org", { ["git.example.org"] = "gitlab" }))
    end)

    it("returns nil for an unrecognized, unconfigured host", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.is_nil(url.host_kind("unknown.example.org", {}))
    end)
  end)

  describe("build", function()
    local remote = { host = "github.com", owner = "StefanBartl", repo = "gitsuite.nvim" }

    it("builds the repo root when rel_path is nil", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://github.com/StefanBartl/gitsuite.nvim",
        url.build("github", remote, "main", nil)
      )
    end)

    it("builds a github file URL with no line anchor", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://github.com/StefanBartl/gitsuite.nvim/blob/main/README.md",
        url.build("github", remote, "main", "README.md")
      )
    end)

    it("builds a github file URL with a single-line anchor", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://github.com/StefanBartl/gitsuite.nvim/blob/main/README.md#L5",
        url.build("github", remote, "main", "README.md", 5)
      )
    end)

    it("builds a github file URL with a range anchor", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://github.com/StefanBartl/gitsuite.nvim/blob/main/README.md#L5-L9",
        url.build("github", remote, "main", "README.md", 5, 9)
      )
    end)

    it("collapses an equal first/last range to a single-line anchor", function()
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://github.com/StefanBartl/gitsuite.nvim/blob/main/README.md#L5",
        url.build("github", remote, "main", "README.md", 5, 5)
      )
    end)

    it("builds a gitlab file URL (different grammar: /-/blob/)", function()
      local gitlab_remote = { host = "gitlab.com", owner = "owner", repo = "repo" }
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://gitlab.com/owner/repo/-/blob/main/src/x.lua#L1-L3",
        url.build("gitlab", gitlab_remote, "main", "src/x.lua", 1, 3)
      )
    end)

    it("builds a codeberg file URL (different grammar: /src/branch/)", function()
      local codeberg_remote = { host = "codeberg.org", owner = "owner", repo = "repo" }
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        "https://codeberg.org/owner/repo/src/branch/main/src/x.lua",
        url.build("codeberg", codeberg_remote, "main", "src/x.lua")
      )
    end)
  end)
end)
