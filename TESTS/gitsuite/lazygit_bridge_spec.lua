-- TESTS/gitsuite/lazygit_bridge_spec.lua -- the nvr bridge lazygit's O/<C-o>
-- custom commands call into (badd/replace). Real file operations against
-- this repo's own tracked files, no fixture needed.
describe("gitsuite.features.ui.lazygit bridge", function()
  local badd
  local replace

  before_each(function()
    package.loaded["gitsuite.features.ui.lazygit.badd"] = nil
    package.loaded["gitsuite.features.ui.lazygit.replace"] = nil
    badd = require("gitsuite.features.ui.lazygit.badd")
    replace = require("gitsuite.features.ui.lazygit.replace")
  end)

  describe("badd", function()
    it("adds a repo-relative path as a background buffer, not focused", function()
      local before_win = vim.api.nvim_get_current_win()
      local ok = badd.run("README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(before_win, vim.api.nvim_get_current_win(), "badd never changes focus")

      local bufnr = vim.fn.bufnr(vim.fn.getcwd() .. "/README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(bufnr > 0, "the buffer now exists in the buffer list")
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(0, vim.fn.bufloaded(bufnr), "badd does not load the buffer's content")
    end)

    it("returns false, does not raise, for an unreadable path", function()
      local ok, result = pcall(badd.run, "this/file/does/not/exist.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_false(result)
    end)

    it("returns false, does not raise, for an empty/nil path", function()
      local ok, result = pcall(badd.run, "")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      ---@diagnostic disable-next-line: undefined-field
      assert.is_false(result)
    end)
  end)

  describe("replace", function()
    it("falls back to badd when there is no normal editor window to replace", function()
      -- Close every window down to exactly one, showing a non-file scratch
      -- buffer, so find_last_normal_window() finds nothing to replace.
      vim.cmd("only")
      vim.cmd("enew")
      vim.bo.buftype = "nofile"

      local ok = replace.run("README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok, "falls back to badd, which succeeds")

      local bufnr = vim.fn.bufnr(vim.fn.getcwd() .. "/README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(bufnr > 0, "README.md was added as a background buffer instead")
    end)

    it("replaces the visible file in a real editor window", function()
      vim.cmd("only")
      local scratch = vim.fn.getcwd() .. "/__gitsuite_lazygit_bridge_scratch.md"
      vim.fn.writefile({ "scratch" }, scratch)
      vim.cmd("edit " .. vim.fn.fnameescape(scratch))
      local win = vim.api.nvim_get_current_win()

      local ok = replace.run("README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok)
      -- vim.fs.normalize on both sides: nvim_buf_get_name can come back with
      -- OS-native separators (backslashes on Windows) while getcwd() here
      -- returns forward slashes -- same file, different string.
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(
        vim.fs.normalize(vim.fn.getcwd() .. "/README.md"),
        vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
      )

      vim.fn.delete(scratch)
    end)

    it("never clobbers an unsaved buffer -- falls back to badd instead", function()
      vim.cmd("only")
      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved change" })
      local win = vim.api.nvim_get_current_win()
      local original_buf = vim.api.nvim_win_get_buf(win)

      local ok = replace.run("README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(ok, "falls back to badd, which succeeds")
      ---@diagnostic disable-next-line: undefined-field
      assert.equals(original_buf, vim.api.nvim_win_get_buf(win), "the modified buffer is untouched")

      local bufnr = vim.fn.bufnr(vim.fn.getcwd() .. "/README.md")
      ---@diagnostic disable-next-line: undefined-field
      assert.is_true(bufnr > 0, "README.md was added as a background buffer instead")

      vim.bo[original_buf].modified = false -- so :bdelete/test teardown never prompts
    end)
  end)
end)
