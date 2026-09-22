-- TESTS/gitsuite/hunk_spec.lua -- gitsuite.features.hunk. gitsigns.nvim is
-- not a sibling checkout in gitsuite.nvim's own test environment (it is an
-- optional adapter, not a runtime dependency), so every case here exercises
-- the "not installed" degrade path -- exactly what `adapter.resolve
-- ("gitsigns")` correctly reports in this environment, and what every real
-- consumer without gitsigns installed will see too. preview()'s fallback
-- onto diff.nvim's real :Diff target=git:HEAD is the one path that still
-- does real work without gitsigns.
describe("gitsuite.features.hunk", function()
  local hunk
  local bufnr

  before_each(function()
    package.loaded["gitsuite.features.hunk"] = nil
    package.loaded["gitsuite.adapter"] = nil
    hunk = require("gitsuite.features.hunk")
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fn.getcwd() .. "/README.md"))
    bufnr = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    require("diff").clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  local actions = { "stage", "reset", "stage_buffer", "reset_buffer", "toggle_deleted" }
  for _, action in ipairs(actions) do
    it(("%s() reports 'not installed', does not crash, without gitsigns"):format(action), function()
      local ok = pcall(hunk[action])
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
    end)
  end

  it("preview() falls back to diff.nvim's :Diff target=git:HEAD without gitsigns", function()
    local ok = pcall(hunk.preview)
    ---@diagnostic disable-next-line: undefined-field
    assert.is_true(ok)
  end)

  describe("GitsuiteStatusChanged, with a faked gitsigns.nvim", function()
    local git = require("lib.nvim.git")
    local group
    local captured
    local real_gitsigns

    before_each(function()
      real_gitsigns = package.loaded["gitsigns"]
      group = vim.api.nvim_create_augroup("gitsuite_hunk_spec_events", { clear = true })
      captured = nil
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "GitsuiteStatusChanged",
        callback = function(event)
          captured = event.data
        end,
      })
    end)

    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
      package.loaded["gitsigns"] = real_gitsigns
    end)

    -- gitsigns.stage_hunk/reset_hunk/stage_buffer are async with an optional
    -- `fun(err?: string)` completion callback (see adapter/gitsigns.lua's
    -- docstring); this fake calls it synchronously, close enough to check
    -- that gitsuite wires the callback through and only fires on success.
    local function fake_gitsigns(err)
      return {
        stage_hunk = function(_range, _opts, callback)
          if callback then callback(err) end
        end,
        reset_hunk = function(_range, _opts, callback)
          if callback then callback(err) end
        end,
        stage_buffer = function(callback)
          if callback then callback(err) end
        end,
        reset_buffer = function() end,
        toggle_deleted = function() end,
      }
    end

    local expected_dir = git.repo_root()

    local async_actions = { "stage", "reset", "stage_buffer" }
    for _, action in ipairs(async_actions) do
      it(
        ("%s() fires with {dir} once gitsigns' callback reports success"):format(action),
        function()
          package.loaded["gitsigns"] = fake_gitsigns(nil)
          hunk[action]()

          ---@diagnostic disable-next-line: undefined-field
          assert.is_not_nil(captured)
          ---@diagnostic disable-next-line: undefined-field
          assert.equals(expected_dir, captured.dir)
        end
      )

      it(("%s() does not fire when gitsigns reports an error"):format(action), function()
        package.loaded["gitsigns"] = fake_gitsigns("boom")
        hunk[action]()

        ---@diagnostic disable-next-line: undefined-field
        assert.is_nil(captured)
      end)
    end

    it("reset_buffer() fires with {dir} (gitsigns' own reset_buffer is synchronous)", function()
      package.loaded["gitsigns"] = fake_gitsigns(nil)
      hunk.reset_buffer()

      ---@diagnostic disable-next-line: undefined-field
      assert.is_not_nil(captured)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(expected_dir, captured.dir)
    end)

    it("toggle_deleted() does not fire GitsuiteStatusChanged", function()
      package.loaded["gitsigns"] = fake_gitsigns(nil)
      hunk.toggle_deleted()

      ---@diagnostic disable-next-line: undefined-field
      assert.is_nil(captured)
    end)
  end)
end)
