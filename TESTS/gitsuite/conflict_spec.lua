-- TESTS/gitsuite/conflict_spec.lua -- gitsuite.features.conflict (the
-- impure shell: scan/highlight/choose/navigate) against real scratch
-- buffers with synthetic conflict markers. No git state needed -- this
-- operates purely on buffer text.
---@diagnostic disable: undefined-field -- luassert extends `assert` (assert.is_nil, assert.equals, ...) beyond stock Lua's; the test body itself is the guard, so one disable per file beats one disable-next-line per assertion (LLS-40/42 discipline).
describe("gitsuite.features.conflict", function()
  local conflict
  local bufnr

  local function set_lines(lines)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end

  local function get_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  before_each(function()
    package.loaded["gitsuite.features.conflict"] = nil
    conflict = require("gitsuite.features.conflict")
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  describe("fenced-block filtering (color_my_ascii.nvim, optional)", function()
    local real_fences

    before_each(function()
      real_fences = package.loaded["color_my_ascii.api.fences"]
    end)

    after_each(function()
      package.loaded["color_my_ascii.api.fences"] = real_fences
    end)

    it("without color_my_ascii.nvim: a fenced-looking conflict still counts", function()
      package.loaded["color_my_ascii.api.fences"] = nil
      set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
      assert.is_true(conflict.has_conflicts(bufnr))
    end)

    it("with a faked color_my_ascii.nvim: markers inside a fence are not a conflict", function()
      package.loaded["color_my_ascii.api.fences"] = {
        block_at = function(_, row)
          -- A fenced block covering rows 0..4 (the whole example below).
          if row >= 0 and row <= 4 then return { close_row = 4 } end
          return nil
        end,
      }
      set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
      assert.is_false(conflict.has_conflicts(bufnr))
    end)

    it(
      "with a faked color_my_ascii.nvim: a real conflict outside any fence still counts",
      function()
        package.loaded["color_my_ascii.api.fences"] = {
          block_at = function()
            return nil
          end,
        }
        set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
        assert.is_true(conflict.has_conflicts(bufnr))
      end
    )
  end)

  it("has_conflicts() is false for an ordinary buffer, true once markers are added", function()
    set_lines({ "just", "ordinary", "lines" })
    assert.is_false(conflict.has_conflicts(bufnr))

    set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
    assert.is_true(conflict.has_conflicts(bufnr))
  end)

  describe("an ambiguous region (a `=======` line that may be text)", function()
    local lines = {
      "before",
      "<<<<<<< HEAD", -- row 1
      "Title",
      "=======", -- candidate, row 3
      "our text",
      "=======", -- candidate, row 5
      "their text",
      ">>>>>>> other", -- row 7
      "after",
    }

    it("is still a conflict: has_conflicts() and next() see it", function()
      set_lines(lines)
      assert.is_true(conflict.has_conflicts(bufnr))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      conflict.next()
      assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("refresh() marks the markers and every candidate, and colours no section", function()
      set_lines(lines)
      conflict.refresh(bufnr)
      local ns = vim.api.nvim_create_namespace("gitsuite_conflict")
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
      local rows = {}
      for _, mark in ipairs(marks) do
        rows[#rows + 1] = mark[2]
        assert.equals("GitSuiteConflictMarker", mark[4].hl_group)
      end
      table.sort(rows)
      assert.same(
        { 1, 3, 5, 7 },
        rows,
        "start, both candidates, end -- nothing coloured ours/theirs"
      )
    end)

    describe("choose() (GS-28: asks which `=======` is real, via vim.ui.select)", function()
      it("offers both candidate rows and resolves with the one picked", function()
        set_lines(lines)
        local offered
        local original_select = vim.ui.select
        vim.ui.select = function(items, _opts, on_choice)
          offered = items
          on_choice(items[1]) -- row 3: "Title" / "======= / our text" split
        end
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        conflict.choose("ours")
        vim.ui.select = original_select

        assert.same({ 3, 5 }, offered, "both candidate rows are offered, in order")
        assert.same(
          { "before", "Title", "after" },
          get_lines(),
          "picking the first candidate treats row 3 as the separator"
        )
      end)

      it("a different pick resolves the region differently", function()
        set_lines(lines)
        local original_select = vim.ui.select
        vim.ui.select = function(items, _opts, on_choice)
          on_choice(items[2]) -- row 5: the other split
        end
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        conflict.choose("ours")
        vim.ui.select = original_select

        assert.same(
          { "before", "Title", "=======", "our text", "after" },
          get_lines(),
          "picking the second candidate treats row 5 as the separator instead"
        )
      end)

      it("a cancelled prompt (nil choice) leaves the buffer untouched", function()
        set_lines(lines)
        local original_select = vim.ui.select
        vim.ui.select = function(_items, _opts, on_choice)
          on_choice(nil)
        end
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        local ok = pcall(conflict.choose, "ours")
        vim.ui.select = original_select

        assert.is_true(ok)
        assert.same(lines, get_lines())
      end)

      it(
        "refuses (TOCTOU) if the buffer changed while the vim.ui.select prompt was open",
        function()
          -- vim.ui.select is asynchronous -- the prompt can stay open for as
          -- long as the user takes to decide, during which other code (an
          -- autocmd, a timer, another choose()) can edit the buffer. Here the
          -- picked separator row (5) no longer holds `=======` by the time
          -- on_choice runs; resolving anyway would silently drop content.
          set_lines(lines)
          local original_select = vim.ui.select
          vim.ui.select = function(items, _opts, on_choice)
            set_lines({ "before", "<<<<<<< HEAD", "Title", "=======", "our text", "EDITED" })
            on_choice(items[2]) -- row 5: no longer "=======" after the edit above
          end
          local seen = {}
          local original_notify = vim.notify
          vim.notify = function(msg)
            seen[#seen + 1] = tostring(msg)
          end
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          local ok = pcall(conflict.choose, "ours")
          vim.notify = original_notify
          vim.ui.select = original_select

          assert.is_true(ok, "refusing is a message, not an error")
          assert.same(
            { "before", "<<<<<<< HEAD", "Title", "=======", "our text", "EDITED" },
            get_lines(),
            "the concurrent edit is left untouched, not overwritten"
          )
          assert.equals(1, #seen)
          assert.is_truthy(seen[1]:find("buffer changed", 1, true))
        end
      )
    end)

    it(
      "choose() still refuses outright when only the BASE marker is ambiguous (one separator candidate)",
      function()
        -- Two `|||||||` markers before a single `=======`: which is the real
        -- base is ambiguous, but there is only one separator candidate --
        -- nothing a separator choice could resolve, so no prompt is offered.
        local base_ambiguous = {
          "<<<<<<< HEAD",
          "ours",
          "||||||| base1",
          "b1",
          "||||||| base2",
          "b2",
          "=======",
          "theirs",
          ">>>>>>> branch",
        }
        set_lines(base_ambiguous)
        local select_called = false
        local original_select = vim.ui.select
        vim.ui.select = function(_items, _opts, on_choice)
          select_called = true
          on_choice(nil)
        end
        local seen = {}
        local original_notify = vim.notify
        vim.notify = function(msg)
          seen[#seen + 1] = tostring(msg)
        end
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local ok = pcall(conflict.choose, "ours")
        vim.notify = original_notify
        vim.ui.select = original_select

        assert.is_true(ok, "refusing is a message, not an error")
        assert.is_false(select_called, "no prompt: one candidate separator can't be chosen among")
        assert.same(base_ambiguous, get_lines())
        assert.equals(1, #seen)
        assert.is_truthy(seen[1]:find("ambiguous", 1, true))
      end
    )
  end)

  it("refresh() places one extmark per marker/content section", function()
    set_lines({ "<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> branch" })
    conflict.refresh(bufnr)
    local ns = vim.api.nvim_create_namespace("gitsuite_conflict")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
    -- start marker, ours, sep marker, theirs, end marker = 5
    assert.equals(5, #marks)
  end)

  it("choose('ours') keeps only the ours side and removes every marker", function()
    set_lines({
      "before",
      "<<<<<<< HEAD",
      "our line",
      "=======",
      "their line",
      ">>>>>>> branch",
      "after",
    })
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- cursor inside the conflict
    conflict.choose("ours")
    assert.same({ "before", "our line", "after" }, get_lines())
  end)

  it("choose('theirs') keeps only the theirs side", function()
    set_lines({ "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("theirs")
    assert.same({ "their line" }, get_lines())
  end)

  it("choose('both') keeps ours then theirs, in order", function()
    set_lines({ "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    conflict.choose("both")
    assert.same({ "our line", "their line" }, get_lines())
  end)

  it("choose('none') removes the whole region, keeping the buffer's other lines", function()
    set_lines({
      "before",
      "<<<<<<< HEAD",
      "our line",
      "=======",
      "their line",
      ">>>>>>> branch",
      "after",
    })
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    conflict.choose("none")
    assert.same({ "before", "after" }, get_lines())
  end)

  it("choose('base') keeps the common-ancestor section on a diff3-style conflict", function()
    set_lines({
      "<<<<<<< HEAD",
      "our line",
      "||||||| base",
      "base line",
      "=======",
      "their line",
      ">>>>>>> branch",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.choose("base")
    assert.same({ "base line" }, get_lines())
  end)

  it(
    "choose('base') on a merge-style conflict (no base section) errors, changes nothing",
    function()
      local original = { "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" }
      set_lines(original)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(conflict.choose, "base")
      assert.is_true(ok, "must not raise, just report an error")
      assert.same(
        original,
        get_lines(),
        "buffer is untouched when the requested side does not exist"
      )
    end
  )

  it("choose() with the cursor outside any conflict reports an error, changes nothing", function()
    local original = { "just", "ordinary", "lines" }
    set_lines(original)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local ok = pcall(conflict.choose, "ours")
    assert.is_true(ok)
    assert.same(original, get_lines())
  end)

  it("choose() only resolves the conflict under the cursor, a second one is untouched", function()
    set_lines({
      "<<<<<<< HEAD", -- 1
      "a-ours", -- 2
      "=======", -- 3
      "a-theirs", -- 4
      ">>>>>>> branch", -- 5
      "between", -- 6
      "<<<<<<< HEAD", -- 7
      "b-ours", -- 8
      "=======", -- 9
      "b-theirs", -- 10
      ">>>>>>> branch", -- 11
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- inside the FIRST conflict
    conflict.choose("ours")
    local lines = get_lines()
    assert.same(
      { "a-ours", "between", "<<<<<<< HEAD", "b-ours", "=======", "b-theirs", ">>>>>>> branch" },
      lines
    )
  end)

  it("next()/prev() move the cursor to the next/previous conflict's start line", function()
    set_lines({
      "before", -- row 1
      "<<<<<<< HEAD", -- row 2 = conflict A start
      "a",
      "=======",
      "a2",
      ">>>>>>> b",
      "between", -- row 7
      "<<<<<<< HEAD", -- row 8 = conflict B start
      "b",
      "=======",
      "b2",
      ">>>>>>> b", -- row 12
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    conflict.next()
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

    conflict.next()
    assert.equals(8, vim.api.nvim_win_get_cursor(0)[1])

    -- No third conflict: cursor stays put, does not raise.
    local ok = pcall(conflict.next)
    assert.is_true(ok)
    assert.equals(8, vim.api.nvim_win_get_cursor(0)[1])

    conflict.prev()
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  describe("GitsuiteConflictsResolved", function()
    local group
    local captured

    before_each(function()
      captured = nil
      group = vim.api.nvim_create_augroup("gitsuite_conflict_spec_events", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "GitsuiteConflictsResolved",
        callback = function(event)
          captured = event.data
        end,
      })
    end)

    after_each(function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end)

    it("fires with {bufnr} once choose() resolves the buffer's only conflict", function()
      set_lines({ "<<<<<<< HEAD", "our line", "=======", "their line", ">>>>>>> branch" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      conflict.choose("ours")

      assert.is_not_nil(captured)
      assert.equals(bufnr, captured.bufnr)
    end)

    it("does not fire while a second conflict remains in the buffer", function()
      set_lines({
        "<<<<<<< HEAD",
        "a-ours",
        "=======",
        "a-theirs",
        ">>>>>>> branch",
        "between",
        "<<<<<<< HEAD",
        "b-ours",
        "=======",
        "b-theirs",
        ">>>>>>> branch",
      })
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- inside the FIRST conflict
      conflict.choose("ours")

      assert.is_nil(captured)
    end)

    it("does not fire when choose() on an ambiguous region is cancelled", function()
      set_lines({
        "<<<<<<< HEAD",
        "Title",
        "=======",
        "our text",
        "=======",
        "their text",
        ">>>>>>> other",
      })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local original_select = vim.ui.select
      vim.ui.select = function(_items, _opts, on_choice)
        on_choice(nil)
      end
      pcall(conflict.choose, "ours")
      vim.ui.select = original_select

      assert.is_nil(captured)
    end)
  end)

  describe("list() -- repo-wide, delegates to insights.nvim.conflicts", function()
    local real_insights_conflicts

    before_each(function()
      real_insights_conflicts = package.loaded["insights.conflicts"]
    end)

    after_each(function()
      package.loaded["insights.conflicts"] = real_insights_conflicts
    end)

    it("without insights.nvim: notifies and calls on_done(0) -- fails open", function()
      package.loaded["insights.conflicts"] = nil
      local orig_preload = package.preload["insights.conflicts"]
      package.preload["insights.conflicts"] = function()
        error("no insights.nvim here")
      end

      local seen = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        seen[#seen + 1] = tostring(msg)
      end
      local done_count
      conflict.list(function(count)
        done_count = count
      end)
      vim.notify = original_notify
      package.preload["insights.conflicts"] = orig_preload

      assert.equals(0, done_count)
      assert.is_truthy(seen[1] and seen[1]:find("insights.nvim is not installed", 1, true))
    end)

    it("with a faked insights.nvim: forwards run_async's count to on_done", function()
      package.loaded["insights.conflicts"] = {
        run_async = function(_, on_done)
          on_done(3)
        end,
      }
      local done_count
      conflict.list(function(count)
        done_count = count
      end)
      assert.equals(3, done_count)
    end)

    it("with a faked insights.nvim: on_done is optional", function()
      package.loaded["insights.conflicts"] = {
        run_async = function(_, on_done)
          on_done(0)
        end,
      }
      local ok = pcall(conflict.list)
      assert.is_true(ok)
    end)
  end)
end)
