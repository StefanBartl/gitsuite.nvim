---@module 'gitsuite.features.conflict.parser'
--- Pure merge-conflict-marker parser: text in, structured regions out. No
--- `vim.api` calls, headless-testable (PRINCIPLES.md "Pure Core / Impure
--- Shell") -- `render.lua` is the impure shell (highlight, navigation,
--- choose actions) around this.
---
--- This is the one module in gitsuite.nvim with real correctness risk
--- (§9 of the concept doc): a misparsed marker means silently losing a side
--- of a merge. Tested against merge-style, diff3-style and zdiff3-style
--- fixtures, multiple conflicts per buffer, and malformed/unclosed markers.

local M = {}

local START_PAT = "^<<<<<<<%s?(.*)$"
local BASE_PAT = "^|||||||%s?(.*)$"
local SEP_PAT = "^=======%s*$"
local END_PAT = "^>>>>>>>%s?(.*)$"

---One conflict region. Every `*_first`/`*_last` pair is an inclusive,
---0-indexed buffer row range (matching `nvim_buf_get_lines`/extmark
---conventions directly -- no further conversion needed by callers).
---`last < first` means that section is genuinely empty (e.g. a side that
---deleted the whole block), not a parser bug -- callers must handle it,
---not assume `first <= last`.
---@class GitSuite.Conflict.Region
---@field style "merge"|"diff3"        "diff3" covers both `diff3` and `zdiff3` merge.conflictStyle output -- both use identical markers, differing only in how much unchanged base context git includes.
---@field start_line integer            Row of the `<<<<<<<` marker.
---@field ours_label string             Text after `<<<<<<<` (branch/ref name).
---@field ours_first integer
---@field ours_last integer
---@field base_first integer|nil        nil unless style == "diff3".
---@field base_last integer|nil
---@field sep_line integer              Row of the `=======` marker.
---@field theirs_first integer
---@field theirs_last integer
---@field theirs_label string           Text after `>>>>>>>` (branch/ref name).
---@field end_line integer              Row of the `>>>>>>>` marker.

---Parse every conflict region in `lines`.
---
---Malformed input (a `<<<<<<<` with no matching `=======`/`>>>>>>>` before
---the next `<<<<<<<` or end of buffer) is skipped, not guessed at -- a
---half-parsed region would risk exactly the correctness failure this
---module exists to avoid. Regions are returned in buffer order.
---@param lines string[] 1-indexed array of buffer lines (as `nvim_buf_get_lines` returns).
---@return GitSuite.Conflict.Region[]
function M.parse(lines)
  local regions = {}
  local n = #lines
  local i = 1

  while i <= n do
    local ours_label = lines[i]:match(START_PAT)
    if not ours_label then
      i = i + 1
    else
      local start_idx = i
      local base_marker_idx, sep_idx, end_idx
      local j = i + 1

      while j <= n do
        if lines[j]:match(START_PAT) then
          -- Another `<<<<<<<` before this one closed: malformed, bail.
          break
        elseif not sep_idx and not base_marker_idx and lines[j]:match(BASE_PAT) then
          base_marker_idx = j
        elseif not sep_idx and lines[j]:match(SEP_PAT) then
          sep_idx = j
        elseif sep_idx and lines[j]:match(END_PAT) then
          end_idx = j
          break
        end
        j = j + 1
      end

      if not sep_idx or not end_idx then
        i = i + 1
      else
        local ours_close = (base_marker_idx or sep_idx) - 1

        ---@type GitSuite.Conflict.Region
        local region = {
          style = base_marker_idx and "diff3" or "merge",
          start_line = start_idx - 1,
          ours_label = ours_label,
          ours_first = start_idx, -- row = array_pos - 1; first content array pos is start_idx + 1 -> row start_idx
          ours_last = ours_close - 1,
          sep_line = sep_idx - 1,
          theirs_first = sep_idx,
          theirs_last = end_idx - 2,
          theirs_label = lines[end_idx]:match(END_PAT),
          end_line = end_idx - 1,
        }
        if base_marker_idx then
          region.base_first = base_marker_idx
          region.base_last = sep_idx - 2
        end

        regions[#regions + 1] = region
        i = end_idx + 1
      end
    end
  end

  return regions
end

return M
