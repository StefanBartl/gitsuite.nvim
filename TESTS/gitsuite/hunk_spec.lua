-- TESTS/gitsuite/hunk_spec.lua -- gitsuite.features.hunk. gitsigns.nvim is
-- not a sibling checkout in gitsuite.nvim's own test environment (it is an
-- optional adapter, not a runtime dependency), so every case here exercises
-- the "not installed" degrade path -- exactly what `adapter.resolve
-- ("gitsigns")` correctly reports in this environment, and what every real
-- consumer without gitsigns installed will see too. preview()'s fallback
-- onto diff.nvim's real :Diff target=git:HEAD is the one path that still
-- does real work without gitsigns.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.hunk", function()
  local hunk
  local bufnr
  local origin_win
  local known_bufs
  local initial_buf

  before_each(function()
    package.loaded["gitsuite.features.hunk"] = nil
    package.loaded["gitsuite.adapter"] = nil
    hunk = require("gitsuite.features.hunk")
    -- Show README.md from a hidden buffer instead of `:edit`: the buffer that
    -- was current stays put (an `:edit` over an empty buffer wipes it, and
    -- deleting the then-current buffer later makes nvim create a new one).
    origin_win = vim.api.nvim_get_current_win()
    initial_buf = vim.api.nvim_get_current_buf()
    known_bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      known_bufs[b] = true
    end
    bufnr = vim.fn.bufadd(vim.fn.getcwd() .. "/README.md")
    vim.fn.bufload(bufnr)
    vim.api.nvim_win_set_buf(origin_win, bufnr)
  end)

  -- Closes every window but the one the case started in, the kit floats
  -- included (closing a float fires WinClosed, which drops its
  -- lib_ui_kit_surface_<winid> autocmd group). Returns how many it closed.
  local function close_extra_windows()
    local closed = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= origin_win and pcall(vim.api.nvim_win_close, win, true) then closed = closed + 1 end
    end
    return closed
  end

  after_each(function()
    require("diff").clear()
    pcall(vim.api.nvim_del_user_command, "Git") -- registered by the `:Git hunk` cases
    -- diff.nvim opens its splits and ui.kit floats (notifications, pickers)
    -- from scheduled and async callbacks that land after the case body. Keep
    -- cleaning until a quiet period shows nothing more arrives (bounded).
    local quiet = 0
    local deadline = vim.uv.now() + 3000
    while quiet < 2 and vim.uv.now() < deadline do
      vim.wait(50)
      pcall(function()
        require("ui.kit.toast").clear()
      end)
      quiet = close_extra_windows() == 0 and quiet + 1 or 0
    end
    if vim.api.nvim_buf_is_valid(initial_buf) then
      pcall(vim.api.nvim_win_set_buf, origin_win, initial_buf)
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if not known_bufs[b] then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  local actions = { "stage", "reset", "stage_buffer", "reset_buffer", "toggle_deleted", "inline" }
  for _, action in ipairs(actions) do
    it(("%s() reports 'not installed', does not crash, without gitsigns"):format(action), function()
      local ok = pcall(hunk[action])
      assert.is_true(ok)
    end)
  end

  it("preview() falls back to diff.nvim's :Diff target=git:HEAD without gitsigns", function()
    local ok = pcall(hunk.preview)
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
        toggle_word_diff = function() end,
        toggle_linehl = function() end,
        preview_hunk_inline = function() end,
        preview_hunk = function() end,
      }
    end

    local expected_dir = git.repo_root()

    -- Only stage writes to the git index -- reset (see below) never does.
    local async_actions = { "stage", "stage_buffer" }
    for _, action in ipairs(async_actions) do
      it(
        ("%s() fires with {dir} once gitsigns' callback reports success"):format(action),
        function()
          package.loaded["gitsigns"] = fake_gitsigns(nil)
          hunk[action]()

          assert.is_not_nil(captured)
          assert.equals(expected_dir, captured.dir)
        end
      )

      it(("%s() does not fire when gitsigns reports an error"):format(action), function()
        package.loaded["gitsigns"] = fake_gitsigns("boom")
        hunk[action]()

        assert.is_nil(captured)
      end)
    end

    -- reset()/reset_buffer() never fire GitsuiteStatusChanged: gitsigns'
    -- reset only rewrites the buffer's in-memory lines (found in a
    -- bug/security/performance review of the commit that introduced this
    -- event) -- it never touches the git index or the file on disk, so
    -- `git status` has not moved when either of these returns.
    local reset_actions = { "reset", "reset_buffer" }
    for _, action in ipairs(reset_actions) do
      it(("%s() does not fire GitsuiteStatusChanged"):format(action), function()
        package.loaded["gitsigns"] = fake_gitsigns(nil)
        hunk[action]()

        assert.is_nil(captured)
      end)
    end

    it("toggle_deleted() does not fire GitsuiteStatusChanged", function()
      package.loaded["gitsigns"] = fake_gitsigns(nil)
      hunk.toggle_deleted()

      assert.is_nil(captured)
    end)

    it(
      "inline() toggles word_diff, linehl and previews inline, does not fire GitsuiteStatusChanged",
      function()
        local calls = {}
        package.loaded["gitsigns"] = {
          toggle_word_diff = function()
            calls[#calls + 1] = "toggle_word_diff"
          end,
          toggle_linehl = function()
            calls[#calls + 1] = "toggle_linehl"
          end,
          preview_hunk_inline = function()
            calls[#calls + 1] = "preview_hunk_inline"
          end,
          preview_hunk = function()
            calls[#calls + 1] = "preview_hunk"
          end,
        }

        hunk.inline()

        assert.same({ "toggle_word_diff", "toggle_linehl", "preview_hunk_inline" }, calls)
        assert.is_nil(captured)
      end
    )

    it("inline() falls back to preview_hunk when preview_hunk_inline is unavailable", function()
      local calls = {}
      package.loaded["gitsigns"] = {
        toggle_word_diff = function()
          calls[#calls + 1] = "toggle_word_diff"
        end,
        toggle_linehl = function()
          calls[#calls + 1] = "toggle_linehl"
        end,
        preview_hunk = function()
          calls[#calls + 1] = "preview_hunk"
        end,
      }

      hunk.inline()

      assert.same({ "toggle_word_diff", "toggle_linehl", "preview_hunk" }, calls)
    end)

    it(":Git hunk inline routes to inline()", function()
      require("gitsuite.bindings.usrcmds").register({ commands = { git = "Git" } })
      local calls = {}
      package.loaded["gitsigns"] = {
        toggle_word_diff = function()
          calls[#calls + 1] = "toggle_word_diff"
        end,
        toggle_linehl = function()
          calls[#calls + 1] = "toggle_linehl"
        end,
        preview_hunk_inline = function()
          calls[#calls + 1] = "preview_hunk_inline"
        end,
      }

      vim.cmd("Git hunk inline")

      assert.same({ "toggle_word_diff", "toggle_linehl", "preview_hunk_inline" }, calls)
    end)
  end)
end)
