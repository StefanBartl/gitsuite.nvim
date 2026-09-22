---@module 'gitsuite.features.conflict'
--- Buffer-local merge-conflict resolution: scan, highlight, choose
--- (ours/theirs/both/base/none), navigate, refresh -- built on
--- `parser.lua`'s pure marker parsing (PRINCIPLES.md "Pure Core / Impure
--- Shell": this file is the impure shell around it -- buffer/window reads,
--- extmarks, the actual mutation).
---
--- `list`/repo-wide `refresh` delegate to `insights.nvim.conflicts`
--- (`git diff --name-only --diff-filter=U` into the quickfix list) --
--- already written, reused as-is rather than duplicated.

local parser = require("gitsuite.features.conflict.parser")
local highlights = require("gitsuite.features.conflict.highlights")
local notify = require("gitsuite.util.notify")

local M = {}

local NS = vim.api.nvim_create_namespace("gitsuite_conflict")

---@internal
--- Drop marker-shaped regions that sit entirely inside a fenced code block
--- (color_my_ascii.nvim, optional): a fence showing conflict markers as a
--- documentation example is not an actual unresolved merge conflict.
---@param bufnr integer
---@param regions GitSuite.Conflict.Region[]
---@return GitSuite.Conflict.Region[]
local function filter_fenced(bufnr, regions)
  local ok, fences = pcall(require, "color_my_ascii.api.fences")
  if not ok then return regions end

  local out = {}
  for _, r in ipairs(regions) do
    local block = fences.block_at(bufnr, r.start_line, { include_fence = true })
    if not (block and r.end_line <= block.close_row) then out[#out + 1] = r end
  end
  return out
end

---Scan a buffer for conflict regions. Pure read, no side effects.
---@param bufnr integer
---@return GitSuite.Conflict.Region[]
function M.scan(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return filter_fenced(bufnr, parser.parse(lines))
end

---Whether a buffer currently contains at least one conflict region.
---@param bufnr integer
---@return boolean
function M.has_conflicts(bufnr)
  return #M.scan(bufnr) > 0
end

---@internal
---@param bufnr integer
---@param first integer
---@param last integer  inclusive; `last < first` (an empty section) is a no-op.
---@param hl_group string
local function highlight_range(bufnr, first, last, hl_group)
  if last < first then return end
  vim.api.nvim_buf_set_extmark(bufnr, NS, first, 0, {
    end_row = last + 1,
    hl_group = hl_group,
    hl_eol = true,
  })
end

---@internal
---@param bufnr integer
---@param regions GitSuite.Conflict.Region[]
local function apply_highlight(bufnr, regions)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, r in ipairs(regions) do
    highlight_range(bufnr, r.start_line, r.start_line, "GitSuiteConflictMarker")
    if r.ambiguous then
      -- No section boundaries are known: mark every line that could be the
      -- separator and leave the text unhighlighted rather than colour it as
      -- "ours"/"theirs" on a guess.
      for _, row in ipairs(r.separators) do
        highlight_range(bufnr, row, row, "GitSuiteConflictMarker")
      end
    else
      highlight_range(bufnr, r.ours_first, r.ours_last, "GitSuiteConflictOurs")
      if r.base_first then
        highlight_range(bufnr, r.base_first, r.base_last, "GitSuiteConflictBase")
      end
      highlight_range(bufnr, r.sep_line, r.sep_line, "GitSuiteConflictMarker")
      highlight_range(bufnr, r.theirs_first, r.theirs_last, "GitSuiteConflictTheirs")
    end
    highlight_range(bufnr, r.end_line, r.end_line, "GitSuiteConflictMarker")
  end
end

---Re-scan the current buffer for conflict markers and refresh highlighting.
---@param bufnr? integer defaults to the current buffer
---@return GitSuite.Conflict.Region[]
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  highlights.setup()
  local regions = M.scan(bufnr)
  apply_highlight(bufnr, regions)
  return regions
end

---@internal
---@param bufnr integer
---@param cursor_row integer 0-indexed
---@return GitSuite.Conflict.Region|nil
local function region_at_cursor(bufnr, cursor_row)
  for _, r in ipairs(M.scan(bufnr)) do
    if cursor_row >= r.start_line and cursor_row <= r.end_line then return r end
  end
  return nil
end

---@internal
--- Collect the replacement lines for `keep`, given a region.
---@param bufnr integer
---@param region GitSuite.Conflict.Region
---@param keep "ours"|"theirs"|"both"|"base"|"none"
---@return string[]
local function collect_replacement(bufnr, region, keep)
  local out = {}
  local function add(first, last)
    if last < first then return end
    vim.list_extend(out, vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false))
  end

  if keep == "ours" or keep == "both" then add(region.ours_first, region.ours_last) end
  if keep == "base" then add(region.base_first, region.base_last) end
  if keep == "theirs" or keep == "both" then add(region.theirs_first, region.theirs_last) end
  -- keep == "none": out stays empty.

  return out
end

---@internal
--- A concrete region for the separator at `sep_row` (a 0-indexed row taken
--- from an ambiguous region's own `separators`), reusing whatever `region`
--- already knows -- `base_first`, when the base marker itself was
--- unambiguous (see `parser.lua`'s `GitSuite.Conflict.Region` doc).
---@param region GitSuite.Conflict.Region
---@param sep_row integer
---@return GitSuite.Conflict.Region
local function reconstruct_from_separator(region, sep_row)
  return {
    style = region.style,
    ambiguous = false,
    start_line = region.start_line,
    ours_label = region.ours_label,
    ours_first = region.start_line + 1,
    ours_last = (region.base_first or (sep_row + 1)) - 2,
    base_first = region.base_first,
    base_last = region.base_first and (sep_row - 1) or nil,
    sep_line = sep_row,
    theirs_first = sep_row + 1,
    theirs_last = region.end_line - 1,
    theirs_label = region.theirs_label,
    end_line = region.end_line,
  }
end

---@internal
--- Resolve a concrete (non-ambiguous) `region` by keeping `keep`. Shared by
--- `M.choose()`'s direct path and its ambiguous-region-disambiguated path.
---@param bufnr integer
---@param region GitSuite.Conflict.Region
---@param keep "ours"|"theirs"|"both"|"base"|"none"
---@return nil
local function resolve_concrete(bufnr, region, keep)
  if keep == "base" and not region.base_first then
    notify.error("conflict: no base section here (not a diff3/zdiff3-style conflict)")
    return
  end

  -- ERR-30 (TOCTOU): re-verify every marker row this region was scanned at
  -- still holds the marker it held then, immediately before mutating --
  -- refuse rather than blindly overwrite if the buffer changed in between.
  -- `vim.ui.select` is asynchronous (the prompt can stay open indefinitely
  -- while timers/autocmds/LSP callbacks keep running), so the
  -- ambiguous-region path needs this to cover `sep_line`/`base_first` too,
  -- not just `start_line`/`end_line`: a wrong row here is exactly the
  -- silent-code-loss failure this whole feature exists to avoid.
  local function line_at(row)
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  end
  local start_marker = line_at(region.start_line)
  local end_marker = line_at(region.end_line)
  local sep_marker = line_at(region.sep_line)
  local base_marker = region.base_first and line_at(region.base_first - 1)
  if
    not (start_marker and start_marker:match("^<<<<<<<"))
    or not (end_marker and end_marker:match("^>>>>>>>"))
    or not (sep_marker and sep_marker:match("^======="))
    or (region.base_first and not (base_marker and base_marker:match("^|||||||")))
  then
    notify.error(
      "conflict: buffer changed since this region was found -- re-run :Git conflict refresh"
    )
    return
  end

  local replacement = collect_replacement(bufnr, region, keep)
  vim.api.nvim_buf_set_lines(bufnr, region.start_line, region.end_line + 1, false, replacement)
  local remaining = M.refresh(bufnr)
  if #remaining == 0 then require("gitsuite.events").conflicts_resolved(bufnr) end
end

---Resolve the conflict region under the cursor by keeping `keep`.
---
---An ambiguous region (an `=======` line that could be text, e.g. a
---Markdown setext heading underline -- see the module doc) with more than
---one candidate separator asks which one is real via `vim.ui.select`
---(GS-28) instead of refusing outright: safe because the user decides, sees
---a line-before/line-after preview of each candidate, and the parser itself
---still never guesses. Exactly one candidate means the *base* marker is
---what is actually ambiguous, not the separator -- nothing a separator
---choice could resolve, so that case still refuses.
---@param keep "ours"|"theirs"|"both"|"base"|"none"
---@return nil
function M.choose(keep)
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

  local region = region_at_cursor(bufnr, cursor_row)
  if not region then
    notify.error("conflict: no conflict region under the cursor")
    return
  end

  if region.ambiguous then
    if not region.separators or #region.separators <= 1 then
      -- A wrong guess here moves lines from one side to the other, i.e. loses
      -- code in a merge; refusing costs the user one manual edit.
      notify.error(
        ("conflict: ambiguous separator -- %d lines read `=======`, so where our side ends cannot be told from the text. Resolve this one by hand (git's `conflict-marker-size` attribute avoids this for the next merge)"):format(
          region.separators and #region.separators or 0
        )
      )
      return
    end

    vim.ui.select(region.separators, {
      prompt = "conflict: ambiguous separator -- pick the real `=======` line",
      format_item = function(row)
        local before = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
        local after = vim.api.nvim_buf_get_lines(bufnr, row + 1, row + 2, false)[1] or ""
        return ("line %d  -- before: %q  after: %q"):format(row + 1, before, after)
      end,
    }, function(choice)
      if not choice then return end -- cancelled (<Esc>): leave the buffer untouched
      resolve_concrete(bufnr, reconstruct_from_separator(region, choice), keep)
    end)
    return
  end

  resolve_concrete(bufnr, region, keep)
end

---Jump to the next conflict marker after the cursor.
---@return nil
function M.next()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  for _, r in ipairs(M.scan(bufnr)) do
    if r.start_line > cursor_row then
      vim.api.nvim_win_set_cursor(0, { r.start_line + 1, 0 })
      return
    end
  end
  notify.info("conflict: no next conflict in this buffer")
end

---Jump to the previous conflict marker before the cursor.
---@return nil
function M.prev()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local regions = M.scan(bufnr)
  for i = #regions, 1, -1 do
    if regions[i].start_line < cursor_row then
      vim.api.nvim_win_set_cursor(0, { regions[i].start_line + 1, 0 })
      return
    end
  end
  notify.info("conflict: no previous conflict in this buffer")
end

---List every file with unresolved conflicts in the quickfix list
---(repo-wide, delegates to insights.nvim.conflicts).
---@param on_done? fun(count: integer) Called once the scan is applied -- 0
---when insights.nvim is not installed (a caller using this as a preflight
---gate fails open rather than blocking on a missing optional dependency).
---@return nil
function M.list(on_done)
  local ok_req, insights_conflicts = pcall(require, "insights.conflicts")
  if not ok_req then
    notify.error(
      'conflict: insights.nvim is not installed -- install "StefanBartl/insights.nvim" to use :Git conflict list'
    )
    if on_done then on_done(0) end
    return
  end
  insights_conflicts.run_async({}, function(count)
    if count == 0 then notify.info("conflict: no unresolved conflicts") end
    if on_done then on_done(count) end
  end)
end

return M
