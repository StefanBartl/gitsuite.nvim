---@module 'gitsuite.features.conflict.parser'
--- Pure merge-conflict-marker parser: text in, structured regions out. No
--- `vim.api` calls, headless-testable (PRINCIPLES.md "Pure Core / Impure
--- Shell") -- `render.lua` is the impure shell (highlight, navigation,
--- choose actions) around this.
---
--- This is the one module in gitsuite.nvim with real correctness risk
--- (§9 of the concept doc): a misparsed marker means silently losing a side
--- of a merge. It is tested against conflicts written by a real `git merge`
--- (`TESTS/gitsuite/conflict_git_spec.lua`: all three `merge.conflictStyle`
--- values, LF/CRLF, criss-cross history) as well as string fixtures.
---
--- Three facts about what git writes drive the design:
---
--- 1. **Marker length is part of the marker.** A conflict opens with a run of
---    `<` (7 by default, the `conflict-marker-size` git attribute changes it)
---    and every other marker of the same conflict has exactly that many
---    characters. Git writes a conflict *nested* in the base section -- the
---    conflicting virtual ancestor of a criss-cross merge -- with markers two
---    characters longer. So a marker is matched by its exact length, and a
---    longer or shorter run inside a conflict is just text.
--- 2. **A `=======` line can be text.** In Markdown it underlines a setext
---    heading, so a side of a merge-style conflict may contain one and the
---    separator is then not decidable from the text alone (git cannot tell
---    either). Such a region is reported with `ambiguous = true` and no
---    sections; it is never guessed at, because a guessed boundary moves lines
---    across sides. (diff3/zdiff3 have a `|||||||` marker, which disambiguates
---    unless the *base* also contains one.)
--- 3. **Malformed input is skipped, not repaired.**

local M = {}

-- git's default and minimum marker size (`conflict-marker-size` may only raise it).
local MIN_MARKER_SIZE = 7

local BYTE_LT, BYTE_EQ, BYTE_GT, BYTE_PIPE = 60, 61, 62, 124 -- `<`, `=`, `>`, `|`

---One conflict region. Every `*_first`/`*_last` pair is an inclusive,
---0-indexed buffer row range (matching `nvim_buf_get_lines`/extmark
---conventions directly -- no further conversion needed by callers).
---`last < first` means that section is genuinely empty (e.g. a side that
---deleted the whole block), not a parser bug -- callers must handle it,
---not assume `first <= last`.
---
---When `ambiguous` is true only `start_line`, `end_line`, the labels and
---`separators` are set: the section fields are `nil` on purpose.
---@class GitSuite.Conflict.Region
---@field style "merge"|"diff3"        "diff3" covers both `diff3` and `zdiff3` merge.conflictStyle output -- both use identical markers, differing only in how much unchanged base context git includes.
---@field ambiguous boolean|nil         True when the separator cannot be told from the text (see the module doc); the section fields below are then nil.
---@field separators integer[]|nil      Only when `ambiguous`: the rows of every `=======` line that could be the separator.
---@field start_line integer            Row of the `<<<<<<<` marker.
---@field ours_label string             Text after `<<<<<<<` (branch/ref name).
---@field ours_first integer|nil
---@field ours_last integer|nil
---@field base_first integer|nil        nil unless style == "diff3".
---@field base_last integer|nil
---@field sep_line integer|nil          Row of the `=======` marker.
---@field theirs_first integer|nil
---@field theirs_last integer|nil
---@field theirs_label string           Text after `>>>>>>>` (branch/ref name).
---@field end_line integer              Row of the `>>>>>>>` marker.

---A marker line: a run of at least `MIN_MARKER_SIZE` of `ch`, then either the
---end of the line or whitespace and a label. `<<<<<<<HEAD` (no space) is not
---one -- git never writes it.
---@param line string
---@param ch string One of `<`, `|`, `>`.
---@return integer|nil size Length of the run, nil if `line` is not a marker.
---@return string label Text after the run, trimmed (a CRLF file loaded as unix leaves a `\r`).
local function marker(line, ch)
  local run, rest = line:match("^(" .. ch .. "+)(.*)$")
  if not run or #run < MIN_MARKER_SIZE then return nil, "" end
  if rest ~= "" and not rest:match("^%s") then return nil, "" end
  return #run, (rest:match("^%s*(.-)%s*$"))
end

---A separator line: a run of at least `MIN_MARKER_SIZE` `=` and nothing else.
---@param line string
---@return integer|nil size
local function separator(line)
  local run, rest = line:match("^(=+)(.*)$")
  if not run or #run < MIN_MARKER_SIZE or not rest:match("^%s*$") then return nil end
  return #run
end

---Parse the conflict that opens at `start_idx`, or return nil if it is
---malformed.
---@param lines string[]
---@param n integer
---@param start_idx integer 1-based array position of the opening marker.
---@param size integer Marker length of this conflict.
---@param ours_label string
---@return GitSuite.Conflict.Region|nil region
---@return integer end_idx 1-based array position of the closing marker (meaningless when region is nil).
local function parse_region(lines, n, start_idx, size, ours_label)
  local bases, seps = {}, {}
  local end_idx

  for j = start_idx + 1, n do
    local line = lines[j]
    local byte = line:byte(1)
    if byte == BYTE_LT then
      -- A second opening marker of this size before the first one closed.
      if marker(line, "<") == size then return nil, 0 end
    elseif byte == BYTE_PIPE then
      if marker(line, "|") == size then bases[#bases + 1] = j end
    elseif byte == BYTE_EQ then
      if separator(line) == size then seps[#seps + 1] = j end
    elseif byte == BYTE_GT then
      if #seps > 0 and marker(line, ">") == size then
        end_idx = j
        break
      end
    end
  end

  if not end_idx then return nil, 0 end

  -- A `|||||||` only counts as the base marker if a separator follows it;
  -- otherwise it is text (a table rule in their side, say).
  local last_sep = seps[#seps]
  local base_idx, base_candidates = nil, 0
  for _, b in ipairs(bases) do
    if b < last_sep then
      base_candidates = base_candidates + 1
      base_idx = base_idx or b
    end
  end

  -- With a base marker, only separators after it can end the base section;
  -- ones before it are text of our side.
  local candidates = seps
  if base_idx then
    candidates = {}
    for _, s in ipairs(seps) do
      if s > base_idx then candidates[#candidates + 1] = s end
    end
  end

  local theirs_label = select(2, marker(lines[end_idx], ">"))

  if #candidates ~= 1 or (base_idx and base_candidates ~= 1) then
    local rows = {}
    for _, s in ipairs(candidates) do
      rows[#rows + 1] = s - 1
    end
    ---@type GitSuite.Conflict.Region
    local ambiguous = {
      style = base_idx and "diff3" or "merge",
      ambiguous = true,
      separators = rows,
      start_line = start_idx - 1,
      ours_label = ours_label,
      theirs_label = theirs_label,
      end_line = end_idx - 1,
    }
    return ambiguous, end_idx
  end

  local sep_idx = candidates[1]
  local ours_close = (base_idx or sep_idx) - 1

  ---@type GitSuite.Conflict.Region
  local region = {
    style = base_idx and "diff3" or "merge",
    start_line = start_idx - 1,
    ours_label = ours_label,
    ours_first = start_idx, -- row = array_pos - 1; first content array pos is start_idx + 1 -> row start_idx
    ours_last = ours_close - 1,
    sep_line = sep_idx - 1,
    theirs_first = sep_idx,
    theirs_last = end_idx - 2,
    theirs_label = theirs_label,
    end_line = end_idx - 1,
  }
  if base_idx then
    region.base_first = base_idx
    region.base_last = sep_idx - 2
  end
  return region, end_idx
end

---Parse every conflict region in `lines`.
---
---Malformed input (a `<<<<<<<` with no matching `=======`/`>>>>>>>` before
---the next `<<<<<<<` of the same size or the end of the buffer) is skipped,
---not guessed at -- a half-parsed region would risk exactly the correctness
---failure this module exists to avoid. Regions are returned in buffer order.
---@param lines string[] 1-indexed array of buffer lines (as `nvim_buf_get_lines` returns).
---@return GitSuite.Conflict.Region[]
function M.parse(lines)
  local regions = {}
  local n = #lines
  local i = 1

  while i <= n do
    local size, ours_label
    if lines[i]:byte(1) == BYTE_LT then
      size, ours_label = marker(lines[i], "<")
    end

    if not size then
      i = i + 1
    else
      local region, end_idx = parse_region(lines, n, i, size, ours_label)
      if region then
        regions[#regions + 1] = region
        i = end_idx + 1
      else
        i = i + 1
      end
    end
  end

  return regions
end

return M
