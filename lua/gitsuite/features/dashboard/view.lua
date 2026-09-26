---@module 'gitsuite.features.dashboard.view'
---@brief Renders `:Git dashboard` results and displays them in the user's chosen output.
---@description
--- `vim.notify` truncates and can't be scrolled, which makes it a poor fit for
--- a repository dashboard that can easily run to dozens of lines. This
--- module renders the aligned dashboard table once and then hands it to one of
--- several output backends, all built on `lib.nvim`:
---   - "popup"     (default) a scrollable floating window via `ui.kit`
---   - "buffer"    replaces the current window's buffer with the dashboard buffer
---   - "split"     opens (or reuses) a horizontal split
---   - "vsplit"    opens (or reuses) a vertical split
---   - "clipboard" copies the raw table to the system clipboard
---   - "path"      writes the raw table to a file
---
--- On every interactive backend (popup/buffer/split/vsplit), the repository row
--- under the cursor can be opened: `<CR>` or a double-click (`<2-LeftMouse>`)
--- asks for confirmation via `ui.kit`'s button-confirm dialog, then
--- opens that repository's `README.md` (`:edit`). Rows with no readable
--- `README.md` are a silent no-op past a notification — there is nothing to
--- confirm opening.
---
--- The same row also drives git itself: `p`/`P`/`f` push, pull (`--ff-only`)
--- or fetch the repository under the cursor via `utils.repo_actions`. Each
--- action reports success/failure via notification and then re-reads just
--- that repository's status (`utils.repo_dashboard.dashboard_one`) and redraws the
--- table in place, so ahead/behind counts and dirty state stay current
--- without re-scanning the whole directory. A one-line legend of these keys
--- is shown in the window's `winbar`.
---
--- Those same three keys are also the batch: `m` marks the row under the
--- cursor (or, over a Visual selection, every row it spans) and while
--- anything is marked `p`/`P`/`f` act on the marked set instead of on one
--- row. That is one key doing one thing at two scales, rather than a second
--- uppercase alphabet of batch verbs nobody would find -- and it is why a
--- mark is stored by repository path: `s` re-sorts and `R` re-scans, and a
--- mark that followed the row index would quietly end up on a different
--- repository.
---
--- `gp`/`gP`/`gf`/`gu` are the whole-directory forms, ignoring marks: push,
--- pull, fetch, or update (fetch + ff-only pull, the same pair
--- `:Git dashboard update` runs) every repository in the dashboard. Batches run
--- sequentially and report through `utils.progress` -- these are network
--- calls, and forty simultaneous pushes are a rate limit or an auth-prompt
--- storm -- and every batch is confirmed first, because unlike a single row
--- there is nothing on screen that says what is about to be touched.

---One highlight span produced by `M.render`. Rows and columns are 0-indexed
---byte offsets; `end_col = -1` means "to the end of the line".
---@class DashboardHighlight
---@field row integer
---@field col integer
---@field end_col integer
---@field hl string

---Output backend for `:Git dashboard`, mirrored from reposcope.nvim's own
---`DashboardOutputMode` alias (GS-<dashboard-move>).
---@alias GitSuiteDashboardOutputMode "popup"|"buffer"|"split"|"vsplit"|"clipboard"|"path"

---@class GitSuiteDashboardView
local M = {}

local kit = require("ui.kit")
local map = require("lib.nvim.bindings.keymap")
local open_named_scratch = require("lib.nvim.window.open_named_scratch")
local copy_to_clipboard = require("lib.nvim.cross.copy_to_clipboard")
local write_to_file = require("lib.nvim.fs.write.to_file")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local repo_actions = require("gitsuite.features.dashboard.actions")
local dashboard_one = require("gitsuite.features.dashboard.status").dashboard_one
local progress = require("gitsuite.util.progress")
local notify = require("gitsuite.util.notify").notify

---In-flight row actions, keyed by record index -> verb ("push", "pull", ...).
---Rendered in place of the row's state so a slow push isn't several seconds of
---no visible change at all.
---@type table<integer, string>
local _pending = {}

---Marked repositories, keyed by absolute path -> true.
---
---By path and not by row index: `s` re-sorts the records in place and `R`
---rebuilds them from a fresh scan, so an index-keyed mark would survive both
---and mean a different repository afterwards.
---@type table<string, boolean>
local _marks = {}

---The verb of the batch currently running ("push", "pull", ...), or nil.
---Guards the operations that would move rows out from under an in-flight
---batch, whose `_pending` spinners are keyed by index.
---@type string|nil
local _bulk_running

---The most recent dashboard, kept so the popup can be restored after it is torn
---down to open a README. Without this the records only lived in the popup's
---own closure, so closing it meant re-scanning the whole directory to get back.
---@type { records: RepoDashboardRecord[], opts: table, line: integer }|nil
local _last_view

---Discovery-order snapshot, so the `s` sort cycle can return to the order the
---directory scan produced without re-running it.
---@type RepoDashboardRecord[]
local _discovery_order = {}

---Index into `SORT_MODES`; 1 is discovery order.
local _sort_index = 1

local SCRATCH_NAME = "gitsuite://dashboard"
local DEFAULT_PATH_OUT = vim.fn.stdpath("cache") .. "/gitsuite/dashboard.txt"
local SPINNER = "⟳"

---Mark column, rendered as the first two cells of every row. Present (as two
---spaces) on unmarked rows too, so marking a repository never reflows the
---table sideways.
local MARK_INDICATOR = "✓"
local MARK_GUTTER = "  "
local NS = vim.api.nvim_create_namespace("gitsuite_dashboard")

---Highlight groups for the dashboard table. Linked with `default = true` so a
---colorscheme (or the user) can override any of them without being clobbered
---on the next redraw. The links target semantic diagnostic groups rather than
---the small `ui.config.colortheme` palette, which has no notion of
---"ok/warning/error" and would otherwise force fixed hex values here.
local HL = {
  header = "GitSuiteDashboardHeader",
  repo = "GitSuiteDashboardRepo",
  branch = "GitSuiteDashboardBranch",
  clean = "GitSuiteDashboardClean",
  dirty = "GitSuiteDashboardDirty",
  ahead = "GitSuiteDashboardAhead",
  behind = "GitSuiteDashboardBehind",
  diverged = "GitSuiteDashboardDiverged",
  muted = "GitSuiteDashboardMuted",
  pending = "GitSuiteDashboardPending",
  mark = "GitSuiteDashboardMark",
}

local HL_LINKS = {
  [HL.repo] = "Directory",
  [HL.branch] = "Identifier",
  [HL.clean] = "DiagnosticOk",
  [HL.dirty] = "DiagnosticWarn",
  [HL.ahead] = "DiagnosticInfo",
  [HL.behind] = "DiagnosticInfo",
  [HL.diverged] = "DiagnosticError",
  [HL.muted] = "Comment",
  [HL.pending] = "Special",
  [HL.mark] = "DiagnosticOk",
}

---@private
---@internal
---(Re)defines the table's highlight groups. Called at load and again on every
---`ColorScheme`, since a colorscheme clears user-defined groups.
---@return nil
local function _define_highlights()
  for group, target in pairs(HL_LINKS) do
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end

  -- The header is the one group that wants an attribute *on top of* a link,
  -- and Neovim's highlight API cannot express that: a group either links or
  -- carries its own attributes. So `Title` is resolved here and re-resolved on
  -- ColorScheme -- which is what the link would have done for free if it could
  -- have carried the bold with it.
  --
  -- Bold and nothing more. An underline across the full width was tried and
  -- read as a hard rule cutting the table in half -- far louder than the one
  -- thing it was meant to say, which is "this row is the heading". Boxing the
  -- header instead would have needed side rules that cannot join anything: the
  -- popup's frame is the window's own border, drawn outside the buffer, so a
  -- drawn line inside it stops short of the frame and reads as broken.
  -- Built rather than mutated: `nvim_get_hl` answers with the *read* side of a
  -- highlight (each attribute `true?`, because it only reports the ones that
  -- are set), `nvim_set_hl` takes the *write* side, which can also unset them.
  -- Two classes for one table, and LuaLS refuses to cast between them.
  local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
  local header = vim.tbl_extend("force", {}, title, {
    link = nil,
    bold = true,
    default = true,
  })
  vim.api.nvim_set_hl(0, HL.header, header)
end

_define_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("GitsuiteDashboardHighlights", { clear = true }),
  desc = "Re-define the dashboard's highlight groups",
  callback = _define_highlights,
})

---@private
---@internal
---Formats a commit timestamp as a compact age ("3h", "2d", "5mo"). Compact
---rather than "3 hours ago" because this sits in a table column, where the
---unit letter carries the same information in a third of the width.
---@param ts integer|nil Unix timestamp, or nil when the repository has no commits
---@return string
local function _relative_age(ts)
  if not ts then return "-" end
  local diff = os.time() - ts
  if diff < 0 then diff = 0 end

  -- math.floor, not `//`: Neovim runs LuaJIT (5.1), which has no integer-division operator.
  if diff < 60 then return "now" end
  if diff < 3600 then return ("%dm"):format(math.floor(diff / 60)) end
  if diff < 86400 then return ("%dh"):format(math.floor(diff / 3600)) end
  if diff < 604800 then return ("%dd"):format(math.floor(diff / 86400)) end
  if diff < 2592000 then return ("%dw"):format(math.floor(diff / 604800)) end
  if diff < 31536000 then return ("%dmo"):format(math.floor(diff / 2592000)) end
  return ("%dy"):format(math.floor(diff / 31536000))
end

---Widest a single column may get before its content is elided. Without a cap,
---one repository on a long topic branch (e.g. "claude/lsp-nvim-plugin-concept-0bfd66")
---stretches the column for every other row, leaving a corridor of blanks across
---the whole table.
local MAX_NAME_W = 28
local MAX_BRANCH_W = 22

---@private
---@internal
---Truncates `s` to `width` display cells, marking elision with an ellipsis.
---
---Cuts the tail, which is right where the head identifies the value -- a
---repository name is recognised by how it starts.
---@param s string
---@param width integer
---@return string
local function _elide(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  return vim.fn.strcharpart(s, 0, width - 1) .. "…"
end

---@private
---@internal
---Truncates `s` to `width` display cells, cutting out of the MIDDLE.
---
---For branch names, where the tail is what tells two of them apart. Every
---branch off one workflow shares a prefix -- `claude/nvim-plugin-debugging-47a46e`
---and `claude/nvim-rules-checklists-merge-6656cc` agree for twelve characters
---and differ in a hash at the very end. Cutting the tail throws away exactly
---the half that answers "which one is this".
---
---Two thirds head, one third tail: the head still has to carry enough to read
---as a name, while the tail only has to carry the part that distinguishes.
---@param s string
---@param width integer
---@return string
local function _elide_middle(s, width)
  if vim.fn.strdisplaywidth(s) <= width then return s end
  -- Below four cells there is no room for head + ellipsis + tail, and a
  -- one-character head next to a one-character tail reads as noise; fall back
  -- to the plain form rather than producing "c…6".
  if width < 4 then return _elide(s, width) end

  local keep = width - 1 -- the ellipsis takes one cell
  local head = math.ceil(keep * 2 / 3)
  local tail = keep - head
  local chars = vim.fn.strchars(s)
  return vim.fn.strcharpart(s, 0, head) .. "…" .. vim.fn.strcharpart(s, chars - tail, tail)
end

---Widest the STATE column is allowed to shrink to. Fixed rather than derived
---from the widest cell so the column does not jump a character sideways the
---moment a row swaps `clean` for the wider `⟳ push...` spinner.
local MIN_STATE_W = 12

---Two spaces between every pair of columns.
local GAP = "  "

---@private
---@internal
---Pads `s` on the right to `width` display cells.
---@param s string
---@param width integer
---@return string
local function _ljust(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  return pad > 0 and (s .. (" "):rep(pad)) or s
end

---@private
---@internal
---Pads `s` on both sides so it sits centred in `width` display cells, with the
---odd cell going to the right (a centred cell that cannot be exact reads
---better leaning left, the way the eye scans the column).
---@param s string
---@param width integer
---@return string
local function _center(s, width)
  local pad = width - vim.fn.strdisplaywidth(s)
  if pad <= 0 then return s end
  local left = math.floor(pad / 2)
  return (" "):rep(left) .. s .. (" "):rep(pad - left)
end

---@private
---@internal
---Renders a record's upstream divergence. Empty when the branch tracks an
---upstream and is exactly in sync — that is the common case, and printing
---"+0/-0" on every row was column-wide noise that buried the rows that differ.
---@param r RepoDashboardRecord
---@return string
local function _sync_cell(r)
  if not r.has_upstream then return "no upstream" end
  local parts = {}
  if r.ahead > 0 then parts[#parts + 1] = ("↑%d"):format(r.ahead) end
  if r.behind > 0 then parts[#parts + 1] = ("↓%d"):format(r.behind) end
  return table.concat(parts, " ")
end

---Renders a list of repository dashboard records into an aligned, human-readable block.
---
---Only REPOSITORY is left-aligned; every other column is centred under its
---header. Names are what the eye scans down looking for one entry, and a
---ragged left edge makes that scan impossible — the short values in the other
---columns (a branch, `↑2`, `clean`, `3d`) have no such job and read as a
---column rather than as a ragged stripe when they sit under their heading.
---
---The SYNC column is omitted entirely when no repository has anything to report
---there, so a directory of perfectly in-sync clones doesn't carry a column of
---blanks. Highlight spans are returned alongside the text (rather than matched
---by a syntax file) because the column offsets are only known here, where the
---widths are computed — keyword matching would also colour a repository
---literally named "clean".
---@param records RepoDashboardRecord[] Dashboard records in discovery order
---@return string[] lines Column-aligned dashboard, one entry per line
---@return DashboardHighlight[] highlights Highlight spans, 0-indexed rows and byte columns
function M.render(records)
  local dw = vim.fn.strdisplaywidth
  local name_cells, branch_cells, sync_cells, state_cells, age_cells = {}, {}, {}, {}, {}
  local name_w, branch_w, sync_w = #"REPOSITORY", #"BRANCH", 0
  local state_w, age_w = math.max(#"STATE", MIN_STATE_W), #"LAST COMMIT"

  for i, r in ipairs(records) do
    name_cells[i] = _elide(r.name, MAX_NAME_W)
    branch_cells[i] = _elide_middle(r.branch, MAX_BRANCH_W)
    sync_cells[i] = _sync_cell(r)

    local state = r.state
    if r.state == "dirty" then state = ("dirty (%d)"):format(r.dirty) end
    local pending = _pending[i]
    if pending then state = ("%s %s..."):format(SPINNER, pending) end
    state_cells[i] = state
    age_cells[i] = _relative_age(r.last_commit)

    name_w = math.max(name_w, dw(name_cells[i]))
    branch_w = math.max(branch_w, dw(branch_cells[i]))
    sync_w = math.max(sync_w, dw(sync_cells[i]))
    state_w = math.max(state_w, dw(state_cells[i]))
    age_w = math.max(age_w, dw(age_cells[i]))
  end

  local show_sync = sync_w > 0
  if show_sync then sync_w = math.max(sync_w, #"SYNC") end

  -- Cell positions, so the highlight lookups below don't have to repeat the
  -- "is SYNC showing?" arithmetic at every call site.
  local NAME, BRANCH = 1, 2
  local STATE = show_sync and 4 or 3
  local AGE = STATE + 1

  ---Builds one line's cell list. The same function feeds the header, so the
  ---headings are padded and centred exactly like the values beneath them.
  ---@param name string
  ---@param branch string
  ---@param sync string
  ---@param state string
  ---@param age string
  ---@return { text: string, width: integer, center?: boolean }[]
  local function cells(name, branch, sync, state, age)
    local list = {
      { text = name, width = name_w },
      { text = branch, width = branch_w, center = true },
    }
    if show_sync then list[#list + 1] = { text = sync, width = sync_w, center = true } end
    list[#list + 1] = { text = state, width = state_w, center = true }
    list[#list + 1] = { text = age, width = age_w, center = true }
    return list
  end

  ---Assembles a line from its mark gutter and cells, reporting the byte range
  ---of each cell's *text* rather than of its padded box — centring puts blanks
  ---on both sides, and a highlight that covered them would colour half a column
  ---of whitespace. The gutter is measured in bytes for the same reason it is
  ---passed in at all: the tick is multi-byte where the blank is not, so every
  ---offset has to start from it rather than from column zero.
  ---@param gutter string Mark column, always two display cells wide
  ---@param list { text: string, width: integer, center?: boolean }[]
  ---@return string line, integer[][] spans One { start, stop } byte pair per cell
  local function build(gutter, list)
    local parts, spans = { gutter }, {}
    local col = #gutter
    for i, cell in ipairs(list) do
      if i > 1 then
        parts[#parts + 1] = GAP
        col = col + #GAP
      end
      local padded = cell.center and _center(cell.text, cell.width) or _ljust(cell.text, cell.width)
      local lead = #(padded:match("^ *"))
      spans[i] = { col + lead, col + lead + #cell.text }
      parts[#parts + 1] = padded
      col = col + #padded
    end
    return table.concat(parts), spans
  end

  ---@type DashboardHighlight[]
  local hls = {}

  local header = build(MARK_GUTTER, cells("REPOSITORY", "BRANCH", "SYNC", "STATE", "LAST COMMIT"))
  local lines = { (header:gsub("%s+$", "")) }
  hls[#hls + 1] = { row = 0, col = 0, end_col = -1, hl = HL.header }

  for i, r in ipairs(records) do
    local marked = _marks[r.path] == true
    local gutter = marked and (MARK_INDICATOR .. " ") or MARK_GUTTER
    local line, spans = build(
      gutter,
      cells(name_cells[i], branch_cells[i], sync_cells[i], state_cells[i], age_cells[i])
    )

    lines[#lines + 1] = (line:gsub("%s+$", ""))
    local row = #lines - 1

    if marked then hls[#hls + 1] = { row = row, col = 0, end_col = #gutter, hl = HL.mark } end
    hls[#hls + 1] = { row = row, col = spans[NAME][1], end_col = spans[NAME][2], hl = HL.repo }
    hls[#hls + 1] =
      { row = row, col = spans[BRANCH][1], end_col = spans[BRANCH][2], hl = HL.branch }

    local state_hl = _pending[i] and HL.pending or HL[r.state] or HL.muted
    hls[#hls + 1] = { row = row, col = spans[STATE][1], end_col = spans[STATE][2], hl = state_hl }
    hls[#hls + 1] = { row = row, col = spans[AGE][1], end_col = spans[AGE][2], hl = HL.muted }
  end

  return lines, hls
end

---Builds the one-line summary used as the popup title.
---@param records RepoDashboardRecord[]
---@return string
function M.summary(records)
  local dirty, out_of_sync, marked = 0, 0, 0
  for _, r in ipairs(records) do
    if r.dirty > 0 then dirty = dirty + 1 end
    if r.ahead > 0 or r.behind > 0 then out_of_sync = out_of_sync + 1 end
    if _marks[r.path] then marked = marked + 1 end
  end

  local parts = { ("%d repo%s"):format(#records, #records == 1 and "" or "s") }
  if dirty > 0 then parts[#parts + 1] = ("%d dirty"):format(dirty) end
  if out_of_sync > 0 then parts[#parts + 1] = ("%d out of sync"):format(out_of_sync) end
  -- Last, because it is the only part that changes while the window is open --
  -- appending keeps the leading counts from shifting sideways as marks come
  -- and go (see `_redraw`, which re-stamps this onto the float's border).
  if marked > 0 then parts[#parts + 1] = ("%d marked"):format(marked) end

  -- The active page's name, when there is more than one -- `_last_view` is
  -- always set by the time this runs (`M.show` sets it before calling any
  -- output backend, all of which call this).
  local pages = _last_view and _last_view.opts and _last_view.opts.pages
  local page_index = _last_view and _last_view.opts and _last_view.opts.page_index
  local page = pages and page_index and pages[page_index]
  local title = (page and page.name) and ("GitSuite Dashboard: " .. page.name)
    or "GitSuite Dashboard"

  return title .. " — " .. table.concat(parts, " · ")
end

---@private
---@internal
---Resolves the dashboard row under the cursor to its record. Line 1 is always
---the header (see `M.render`), so the record index is `cursor_line - 1`.
---@param records RepoDashboardRecord[]
---@return RepoDashboardRecord|nil
local function _record_at_cursor(records)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return records[line - 1]
end

---@private
---@internal
---Confirms with the user, then opens `record`'s README.md (`:edit`). A
---missing README.md is reported and treated as a no-op — there is nothing
---to confirm opening.
---@param record RepoDashboardRecord
---@param before_open? fun(): nil Called right before the file is opened (e.g. to close a popup)
---@return nil
local function _open_readme(record, before_open)
  local readme_path = record.path .. "/README.md"
  if not require("lib.nvim.fs.is_readable_file")(readme_path) then
    notify("No README.md found for " .. record.name, 3)
    return
  end

  -- Remember where we were before the popup is torn down, so `q` can put the
  -- dashboard back on the same row.
  if _last_view then _last_view.line = vim.api.nvim_win_get_cursor(0)[1] end

  kit.confirm({
    question = ('Open README.md of "%s"?'):format(record.name),
    on_answer = function(yes)
      if not yes then return end
      if before_open then before_open() end
      vim.cmd.edit(vim.fn.fnameescape(readme_path))

      -- Bound explicitly rather than via a BufWinLeave autocmd: navigating away
      -- with `:edit other` would also fire that, and silently resurrecting the
      -- dashboard on an unrelated buffer switch is worse than not restoring it.
      if not _last_view then return end
      local buf = vim.api.nvim_get_current_buf()
      map("n", "q", function()
        vim.cmd("bwipeout")
        M.reopen()
      end, { buffer = buf, nowait = true }, "Close README and return to the gitsuite dashboard")
      notify("q returns to the dashboard", 3)
    end,
  })
end

---@private
---@internal
---Replaces `bufnr`'s content with `lines` and applies `highlights`, toggling
---`modifiable` only for the duration of the write so read-only dashboard buffers
---stay locked afterwards.
---@param bufnr integer
---@param lines string[]
---@param highlights? DashboardHighlight[]
---@return nil
local function _set_buffer_lines(bufnr, lines, highlights)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable

  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, h in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, h.row, h.col, {
      end_col = h.end_col >= 0 and h.end_col or nil,
      end_row = h.end_col < 0 and (h.row + 1) or nil,
      hl_group = h.hl,
    })
  end
end

---@private
---@internal
---Redraws the whole table into `bufnr`, preserving the cursor position.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@return nil
local function _redraw(bufnr, records)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = (win ~= -1) and vim.api.nvim_win_get_cursor(win) or nil
  local lines, hls = M.render(records)
  _set_buffer_lines(bufnr, lines, hls)
  if cursor then pcall(vim.api.nvim_win_set_cursor, win, cursor) end

  -- A float's title is stamped once at open, but the summary it carries counts
  -- marks and dirty repositories -- both of which change while the window
  -- stays open. Re-stamping here is what keeps "3 marked" honest.
  if win ~= -1 then
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg and cfg.relative and cfg.relative ~= "" and cfg.title then
      cfg.title = M.summary(records)
      pcall(vim.api.nvim_win_set_config, win, cfg)
    end
  end
end

---@private
---@internal
---Row indices of the marked records, in row order.
---@param records RepoDashboardRecord[]
---@return integer[]
local function _marked_indices(records)
  local out = {}
  for i, r in ipairs(records) do
    if _marks[r.path] then out[#out + 1] = i end
  end
  return out
end

---@private
---@internal
---Sets or clears the mark on every record whose row falls inside [first, last].
---Line 1 is the header, so row N holds record N-1 (see `_record_at_cursor`).
---@param records RepoDashboardRecord[]
---@param first integer First buffer line, 1-based
---@param last integer Last buffer line, 1-based
---@param marked boolean Mark when true, unmark when false
---@return integer changed Number of records whose mark actually flipped
local function _mark_rows(records, first, last, marked)
  local value = marked or nil
  local changed = 0
  for line = first, last do
    local record = records[line - 1]
    if record and _marks[record.path] ~= value then
      _marks[record.path] = value
      changed = changed + 1
    end
  end
  return changed
end

---@private
---@internal
---Re-reads `records[idx]`'s git status and redraws `bufnr`, preserving the
---cursor position. Called after a push/pull/fetch settles so ahead/behind and
---dirty state reflect the outcome without re-scanning every repository.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param idx integer
---@return nil
local function _refresh_row(bufnr, records, idx)
  local record = records[idx]
  if not record then return end

  dashboard_one(record.path, function(new_record)
    vim.schedule(function()
      if new_record then records[idx] = new_record end
      _redraw(bufnr, records)
    end)
  end)
end

---@private
---@internal
---Runs a single-repository git action against the row under the cursor,
---notifies the outcome, then refreshes that row.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param verb string Human-readable action name, used in notifications
---@param action_fn fun(repo: string, on_done: fun(ok: boolean, err: string|nil): nil): nil One of `repo_actions.push/pull/fetch`
---@return nil
local function _run_row_action(bufnr, records, verb, action_fn)
  if _bulk_running then
    notify(("A bulk %s is running - wait for it to finish"):format(_bulk_running), 3)
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local idx = line - 1
  local record = records[idx]
  if not record then return end
  if _pending[idx] then
    notify(("%s: %s already running"):format(record.name, _pending[idx]), 3)
    return
  end

  -- Level 3: `utils.debug.notify` drops anything below WARN unless dev mode is
  -- on, so an INFO-level "push ..." would be invisible in normal use -- which
  -- is exactly the silence this feedback is meant to fill.
  notify(("%s %s ..."):format(verb, record.name), 3)
  local handle = progress.create(("%s %s"):format(verb, record.name))

  _pending[idx] = verb
  _redraw(bufnr, records)

  action_fn(record.path, function(ok, err)
    vim.schedule(function()
      _pending[idx] = nil
      if ok then
        notify(("%s: %s done"):format(record.name, verb), 3)
        if handle then handle:finish(("%s %s done"):format(verb, record.name)) end
      else
        notify(("%s: %s failed - %s"):format(record.name, verb, err or "unknown error"), 4)
        if handle then handle:finish(("%s %s failed"):format(verb, record.name)) end
      end
      _refresh_row(bufnr, records, idx)
    end)
  end)
end

---@private
---@internal
---Runs `action_fn` against every record named by `indices`, one after another,
---then reports a single summary.
---
---Sequential, not parallel: `git push` over forty clones at once is a rate
---limit, forty credential prompts, or both, and the queue is the same shape
---`repo_updater` already uses for a directory-wide update. Cancelling through
---the progress handle stops the queue from starting further repositories
---rather than killing the one in flight -- interrupting a `pull` mid-write is
---the one outcome worth avoiding.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param verb string Human-readable action name, used in notifications
---@param action_fn fun(repo: string, on_done: fun(ok: boolean, err: string|nil): nil): nil
---@param indices integer[] Record indices to act on, in row order
---@return nil
local function _run_bulk(bufnr, records, verb, action_fn, indices)
  local total = #indices
  if total == 0 then return end

  if _bulk_running then
    notify(("A bulk %s is already running"):format(_bulk_running), 3)
    return
  end
  for _, idx in ipairs(indices) do
    if _pending[idx] then
      notify(("%s: %s already running"):format(records[idx].name, _pending[idx]), 3)
      return
    end
  end

  -- Every target is marked pending up front, so the whole batch is visible as
  -- a column of spinners instead of one row lighting up at a time with no clue
  -- what else is queued behind it.
  _bulk_running = verb
  for _, idx in ipairs(indices) do
    _pending[idx] = verb
  end
  _redraw(bufnr, records)

  local handle = progress.create(("%s %d repositories"):format(verb, total), total)
  local cancelled = false
  if handle then handle:on_cancel(function()
    cancelled = true
  end) end

  ---@type string[]
  local errors = {}
  local succeeded, position = 0, 1

  local function finish()
    _bulk_running = nil
    -- Clears the queue's own spinners as well as the cancelled tail's.
    for _, idx in ipairs(indices) do
      _pending[idx] = nil
    end
    _redraw(bufnr, records)

    if handle then handle:finish(("%s: %d of %d repositories"):format(verb, succeeded, total)) end
    if #errors > 0 then
      notify(
        ("%s: %d of %d failed:\n\n%s"):format(verb, #errors, total, table.concat(errors, "\n")),
        vim.log.levels.WARN
      )
    else
      notify(
        ("%s: %d repositor%s done"):format(verb, succeeded, succeeded == 1 and "y" or "ies"),
        3
      )
    end
  end

  local function step()
    if cancelled or position > total then
      finish()
      return
    end

    local idx = indices[position]
    local record = records[idx]
    if handle then handle:update({ text = record.name, current = position - 1, total = total }) end

    action_fn(record.path, function(ok, err)
      vim.schedule(function()
        _pending[idx] = nil
        if ok then
          succeeded = succeeded + 1
        else
          errors[#errors + 1] = record.name .. ": " .. vim.trim(err or "unknown error")
        end

        -- The row is re-read *before* the queue moves on, not alongside it:
        -- fired off in parallel, the last repository's re-read would still be
        -- in flight when `finish()` draws the table and announces the batch as
        -- done, leaving that one row showing the state it had before its own
        -- push.
        dashboard_one(record.path, function(new_record)
          vim.schedule(function()
            if new_record then records[idx] = new_record end
            _redraw(bufnr, records)
            position = position + 1
            step()
          end)
        end)
      end)
    end)
  end

  step()
end

---@private
---@internal
---Asks before starting a batch, then runs it.
---
---Confirmed where the single-row actions are not: a row action names its
---target by the line the cursor is on, whereas a batch touches repositories
---that may be scrolled off screen entirely -- so the count is the only thing
---that can state what is about to happen, and it has to be stated.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param verb string
---@param action_fn fun(repo: string, on_done: fun(ok: boolean, err: string|nil): nil): nil
---@param indices integer[]
---@param what string Noun phrase describing the target set, e.g. "marked repositories"
---@return nil
local function _confirm_bulk(bufnr, records, verb, action_fn, indices, what)
  if #indices == 0 then
    notify("No repositories to " .. verb, 3)
    return
  end

  kit.confirm({
    question = ("%s%s %d %s?"):format(verb:sub(1, 1):upper(), verb:sub(2), #indices, what),
    on_answer = function(yes)
      if yes then _run_bulk(bufnr, records, verb, action_fn, indices) end
    end,
  })
end

---@private
---@internal
---The row keys' two scales: with marks set, act on the marked repositories;
---with none set, act on the row under the cursor exactly as before.
---@param ctx DashboardRowContext
---@param verb string
---@param action_fn fun(repo: string, on_done: fun(ok: boolean, err: string|nil): nil): nil
---@return nil
local function _run_marked_or_row(ctx, verb, action_fn)
  local marked = _marked_indices(ctx.records)
  if #marked == 0 then
    _run_row_action(ctx.bufnr, ctx.records, verb, action_fn)
    return
  end
  _confirm_bulk(
    ctx.bufnr,
    ctx.records,
    verb,
    action_fn,
    marked,
    ("marked repositor%s"):format(#marked == 1 and "y" or "ies")
  )
end

---@private
---@internal
---The `g`-prefixed forms: every repository in the dashboard, marks ignored.
---@param ctx DashboardRowContext
---@param verb string
---@param action_fn fun(repo: string, on_done: fun(ok: boolean, err: string|nil): nil): nil
---@return nil
local function _run_all(ctx, verb, action_fn)
  local indices = {}
  for i = 1, #ctx.records do
    indices[i] = i
  end
  _confirm_bulk(
    ctx.bufnr,
    ctx.records,
    verb,
    action_fn,
    indices,
    ("repositor%s in this dashboard"):format(#indices == 1 and "y" or "ies")
  )
end

---Context handed to every row keymap handler.
---@class DashboardRowContext
---@field bufnr integer
---@field records RepoDashboardRecord[]
---@field before_open? fun(): nil

---One interactive binding on a dashboard row.
---@class DashboardRowKeymap
---@field keys string[] Every lhs that triggers this action
---@field label? string Short "key desc" text for the winbar legend; omitted = listed only under `?`
---@field desc string Full description, used as the keymap's `desc`
---@field run fun(ctx: DashboardRowContext): nil
---@field visual? fun(ctx: DashboardRowContext): nil Optional Visual-mode variant, bound on the same keys

---Sort modes cycled by `s`, in cycle order. "discovery" restores the original
---directory order, so the cycle is always reversible without a rescan.
---@type string[]
local SORT_MODES = { "discovery", "name", "state", "age" }

---Ranks states worst-first, so `s` -> "state" surfaces what needs attention
---instead of sorting alphabetically (where "clean" would come first).
local STATE_RANK = { diverged = 1, dirty = 2, behind = 3, ahead = 4, clean = 5 }

---@private
---@internal
---Reorders `records` in place according to `mode`.
---@param records RepoDashboardRecord[]
---@param mode string
---@param original RepoDashboardRecord[] Discovery-order snapshot
---@return nil
local function _sort_records(records, mode, original)
  if mode == "discovery" then
    for i = 1, #original do
      records[i] = original[i]
    end
    return
  end

  table.sort(records, function(a, b)
    if mode == "name" then
      return a.name:lower() < b.name:lower()
    elseif mode == "state" then
      local ra, rb = STATE_RANK[a.state] or 9, STATE_RANK[b.state] or 9
      if ra ~= rb then return ra < rb end
      return a.name:lower() < b.name:lower()
    end
    -- "age": most recently touched first; repos with no commits sort last.
    local ta, tb = a.last_commit or -1, b.last_commit or -1
    if ta ~= tb then return ta > tb end
    return a.name:lower() < b.name:lower()
  end)
end

---@private
---@internal
---Shows a repository's full git status and recent commits in a nested popup.
---@param record RepoDashboardRecord
---@return nil
local function _show_detail(record)
  require("gitsuite.features.dashboard.status").dashboard_detail(record.path, function(body)
    vim.schedule(function()
      local lines = { "", (" %s  (%s)"):format(record.name, record.branch), "" }
      vim.list_extend(lines, body)
      lines[#lines + 1] = ""
      lines[#lines + 1] = " q / <Esc>  close"

      local width = 40
      for _, l in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(l))
      end
      kit.viewer({
        lines = lines,
        title = "git status — " .. record.name,
        filetype = "gitsuite-dashboard-detail",
        width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
        height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
      })
    end)
  end)
end

---@private
---@internal
---The page currently open, or nil before any dashboard has been shown /
---when the current view has no configured pages.
---@return { name: string|nil, paths: string[]|nil }|nil
local function _current_page()
  local view_state = _last_view
  local pages = view_state and view_state.opts and view_state.opts.pages
  if not pages then return nil end
  return pages[view_state.opts.page_index or 1]
end

---@private
---@internal
---Re-reads the page currently open (`delta = 0`), or switches to the
---next/previous configured page (`delta = ±1`, wrapping) and reads that one
---instead. Pages come from `dashboard.groups`: the default (unnamed) page
---plus every configured group, in declaration order -- see
---`features.dashboard.init.lua`'s `on_switch_page`, which is what actually
---knows how to read a given page and is threaded through `_last_view.opts`.
---@param ctx DashboardRowContext
---@param delta integer 0 to re-scan the current page, 1/-1 to move to the next/previous
---@return nil
local function _switch_page(ctx, delta)
  local view_state = _last_view
  local pages = view_state and view_state.opts and view_state.opts.pages
  local on_switch_page = view_state and view_state.opts and view_state.opts.on_switch_page
  if not (pages and on_switch_page) then
    notify("This dashboard has no configured pages to switch between", 3)
    return
  end
  if delta ~= 0 and #pages <= 1 then
    notify("Only one dashboard page is open -- add entries to dashboard.groups for more", 3)
    return
  end
  if _bulk_running then
    notify(("Cannot switch pages while a bulk %s is running"):format(_bulk_running), 3)
    return
  end

  local current_index = view_state.opts.page_index or 1
  local new_index = ((current_index - 1 + delta) % #pages) + 1
  local page = pages[new_index]

  notify(("Loading %s ..."):format(page.name or "dashboard"), 3)
  on_switch_page(page, function(records, errors)
    vim.schedule(function()
      _pending = {}
      _marks = {}
      _sort_index = 1
      _bulk_running = nil
      _discovery_order = vim.deepcopy(records)
      for i = #ctx.records, 1, -1 do
        ctx.records[i] = nil
      end
      for i, r in ipairs(records) do
        ctx.records[i] = r
      end

      local new_opts = vim.tbl_extend("force", view_state.opts, { page_index = new_index })
      _last_view = { records = records, opts = new_opts, line = 2 }
      _redraw(ctx.bufnr, ctx.records)
      notify(
        ("Loaded %s: %d repositor%s"):format(
          page.name or "dashboard",
          #records,
          #records == 1 and "y" or "ies"
        ),
        3
      )
      if errors and #errors > 0 then
        notify(
          ("%d repositor%s could not be read"):format(#errors, #errors == 1 and "y" or "ies"),
          vim.log.levels.WARN
        )
      end
    end)
  end)
end

---@private
---@internal
---Re-reads the current dashboard page (`R`). Marks are cleared along with
---it, same as before: `_switch_page`'s zero-delta path always rebuilds the
---record list from a fresh scan.
---@param ctx DashboardRowContext
---@return nil
local function _rescan_all(ctx)
  _switch_page(ctx, 0)
end

---Forward declaration: the `?` handler is defined below `ROW_KEYMAPS` because it
---renders that very table, but is referenced from inside it.
---@type fun(): nil
local _show_keymap_help

---Row bindings, and the single source of truth for the winbar legend below —
---adding a key here makes it live *and* documents it, instead of the legend
---being a hand-maintained string that silently drifts out of date.
---@type DashboardRowKeymap[]
local ROW_KEYMAPS = {
  {
    keys = { "<CR>", "<2-LeftMouse>" },
    label = "<CR> README",
    desc = "Open README.md of repository under cursor",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if record then _open_readme(record, ctx.before_open) end
    end,
  },
  {
    keys = { "m" },
    label = "m Mark",
    desc = "Toggle the mark on the repository under cursor (Visual: mark the selection)",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if not record then return end
      _marks[record.path] = (not _marks[record.path]) or nil
      _redraw(ctx.bufnr, ctx.records)
    end,
    -- Marking a run of repositories one `m` at a time is exactly the job a
    -- Visual selection over a table already does well; `V}m` beats twelve
    -- keystrokes. Visual mode is left first, because the redraw below changes
    -- the buffer under a selection that would otherwise linger over it.
    visual = function(ctx)
      local first, last = vim.fn.line("v"), vim.fn.line(".")
      if first > last then
        first, last = last, first
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)

      local changed = _mark_rows(ctx.records, first, last, true)
      _redraw(ctx.bufnr, ctx.records)
      notify(("Marked %d repositor%s"):format(changed, changed == 1 and "y" or "ies"), 3)
    end,
  },
  {
    keys = { "M" },
    desc = "Mark every repository, or clear all marks when everything is marked",
    run = function(ctx)
      local total = #ctx.records
      local marked = #_marked_indices(ctx.records)

      -- One key for both directions: "mark all" is only ever wanted when
      -- something is still unmarked, and once everything is marked the only
      -- remaining use for the key is to undo that.
      if total > 0 and marked == total then
        _mark_rows(ctx.records, 2, total + 1, false)
        notify("Cleared all marks", 3)
      else
        _mark_rows(ctx.records, 2, total + 1, true)
        notify(("Marked %d repositor%s"):format(total, total == 1 and "y" or "ies"), 3)
      end
      _redraw(ctx.bufnr, ctx.records)
    end,
  },
  {
    keys = { "p" },
    label = "p Push",
    desc = "Push the marked repositories, or the one under cursor when nothing is marked",
    run = function(ctx)
      _run_marked_or_row(ctx, "push", repo_actions.push)
    end,
  },
  {
    keys = { "P" },
    label = "P Pull",
    desc = "Pull the marked repositories, or the one under cursor when nothing is marked",
    run = function(ctx)
      _run_marked_or_row(ctx, "pull", repo_actions.pull)
    end,
  },
  {
    keys = { "f" },
    label = "f Fetch",
    desc = "Fetch the marked repositories, or the one under cursor when nothing is marked",
    run = function(ctx)
      _run_marked_or_row(ctx, "fetch", repo_actions.fetch)
    end,
  },
  {
    keys = { "gp" },
    desc = "Push every repository in the dashboard (marks ignored)",
    run = function(ctx)
      _run_all(ctx, "push", repo_actions.push)
    end,
  },
  {
    keys = { "gP" },
    desc = "Pull every repository in the dashboard (marks ignored)",
    run = function(ctx)
      _run_all(ctx, "pull", repo_actions.pull)
    end,
  },
  {
    keys = { "gf" },
    desc = "Fetch every repository in the dashboard (marks ignored)",
    run = function(ctx)
      _run_all(ctx, "fetch", repo_actions.fetch)
    end,
  },
  {
    keys = { "gu" },
    desc = "Update every repository in the dashboard: fetch + ff-only pull (marks ignored)",
    run = function(ctx)
      _run_all(ctx, "update", repo_actions.update)
    end,
  },
  {
    keys = { "S" },
    label = "S Status",
    desc = "Show full git status of repository under cursor",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if record then _show_detail(record) end
    end,
  },
  {
    keys = { "L" },
    label = "L Lazygit",
    desc = "Open lazygit for the repository under cursor",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if not record then return end
      if not require("gitsuite.config").get().features.ui then
        notify("The 'ui' feature is disabled (features.ui = false)", 3)
        return
      end
      require("gitsuite.features.ui").lazygit(record.path)
    end,
  },
  {
    keys = { "s" },
    label = "s Sort",
    desc = "Cycle sort order (discovery / name / state / age)",
    run = function(ctx)
      -- `_pending` is keyed by row index, so reordering mid-batch would leave
      -- the spinners pointing at repositories that are not the ones running.
      if _bulk_running then
        notify(("Cannot re-sort while a bulk %s is running"):format(_bulk_running), 3)
        return
      end

      _sort_index = (_sort_index % #SORT_MODES) + 1
      local mode = SORT_MODES[_sort_index]
      _sort_records(ctx.records, mode, _discovery_order)
      _pending = {}
      _redraw(ctx.bufnr, ctx.records)
      notify("Sorted by " .. mode, 3)
    end,
  },
  {
    keys = { "r" },
    desc = "Re-read the repository under cursor",
    run = function(ctx)
      local idx = vim.api.nvim_win_get_cursor(0)[1] - 1
      if ctx.records[idx] then _refresh_row(ctx.bufnr, ctx.records, idx) end
    end,
  },
  {
    keys = { "R" },
    desc = "Re-scan the current dashboard page",
    run = function(ctx)
      _rescan_all(ctx)
    end,
  },
  {
    keys = { "<C-l>", "<Right>" },
    label = "^L/→ Next",
    desc = "Switch to the next configured dashboard page (dashboard.groups)",
    run = function(ctx)
      _switch_page(ctx, 1)
    end,
  },
  {
    keys = { "<C-h>", "<Left>" },
    label = "^H/← Prev",
    desc = "Switch to the previous configured dashboard page (dashboard.groups)",
    run = function(ctx)
      _switch_page(ctx, -1)
    end,
  },
  {
    keys = { "a" },
    label = "a Add",
    desc = "Add a repository or directory path to the current dashboard page",
    run = function(ctx)
      local page = _current_page()
      local key = (page and page.name) or ""
      vim.ui.input(
        { prompt = ("Add path to %s: "):format(page and page.name or "the default page") },
        function(input)
          if not input or input == "" then return end
          require("gitsuite.state.dashboard_pages").add(key, input)
          _switch_page(ctx, 0)
        end
      )
    end,
  },
  {
    keys = { "x" },
    label = "x Remove",
    desc = "Remove the repository under cursor from this dashboard page (never touches disk)",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if not record then return end
      local page = _current_page()
      local key = (page and page.name) or ""
      kit.confirm({
        question = ('Remove "%s" from this dashboard page? (the repository itself is untouched)'):format(
          record.name
        ),
        on_answer = function(yes)
          if not yes then return end
          require("gitsuite.state.dashboard_pages").remove(key, record.path)
          _switch_page(ctx, 0)
        end,
      })
    end,
  },
  {
    keys = { "y" },
    desc = "Yank the path of the repository under cursor",
    run = function(ctx)
      local record = _record_at_cursor(ctx.records)
      if not record then return end
      vim.fn.setreg("+", record.path)
      vim.fn.setreg('"', record.path)
      notify("Yanked " .. record.path, 3)
    end,
  },
  {
    keys = { "?" },
    label = "? Keys",
    desc = "Show every key available in the dashboard",
    run = function()
      _show_keymap_help()
    end,
  },
}

---@private
---@internal
---Lists every row binding, including the ones kept out of the winbar legend to
---stop it overflowing. Generated from `ROW_KEYMAPS`, so it cannot drift.
---@return nil
_show_keymap_help = function()
  local rows, widest = {}, 0
  for _, entry in ipairs(ROW_KEYMAPS) do
    local lhs = table.concat(entry.keys, ", ")
    rows[#rows + 1] = { lhs = lhs, desc = entry.desc }
    widest = math.max(widest, #lhs)
  end

  local lines = { "", " Dashboard keys", "" }
  for _, row in ipairs(rows) do
    lines[#lines + 1] = ("  %-" .. widest .. "s   %s"):format(row.lhs, row.desc)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " q / <Esc>  close"

  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  kit.viewer({
    lines = lines,
    title = "GitSuite Dashboard Keys",
    filetype = "gitsuite-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

---Separator between two legend entries, and its width in display cells.
local LEGEND_SEP_W = 5

---@private
---@internal
---Builds the winbar legend from `ROW_KEYMAPS`, so it can never list a key that
---isn't actually bound. Keys are highlighted separately from their labels via
---`%#Group#` items, which the winbar understands natively.
---
---Fitted to `width` rather than emitted whole: a legend longer than the window
---is truncated by Neovim itself, which cuts it *from the left* and marks the
---cut with a bare `<` — so the overflow silently ate `<CR> README` and `m Mark`,
---the two entries most worth showing, and left a stray `<` in their place.
---Entries are therefore dropped from the right until the line fits, except the
---last one (`? Keys`), which is pinned because it is how everything dropped
---here is still reachable.
---
---What is left is then centred, so the gap before the first entry and the gap
---after the last one match.
---@param width integer Window width in display cells
---@return string
local function _legend(width)
  local labels = {}
  for _, entry in ipairs(ROW_KEYMAPS) do
    if entry.label then labels[#labels + 1] = entry.label end
  end
  if #labels == 0 then return "" end

  local pinned = table.remove(labels)
  local used = vim.fn.strdisplaywidth(pinned)
  local budget = math.max(width, 0) - 4 -- a two-cell margin on either side

  local kept = {}
  for _, label in ipairs(labels) do
    local cost = vim.fn.strdisplaywidth(label) + LEGEND_SEP_W
    if used + cost > budget then break end
    kept[#kept + 1] = label
    used = used + cost
  end
  kept[#kept + 1] = pinned

  local rendered = {}
  for i, label in ipairs(kept) do
    local key, text = label:match("^(%S+)%s+(.*)$")
    rendered[i] = ("%%#%s#%s %%#%s#%s"):format(HL.pending, key, HL.muted, text)
  end

  local lead = math.max(2, math.floor((width - used) / 2))
  return (" "):rep(lead) .. table.concat(rendered, ("%%#%s#  │  "):format(HL.muted))
end

---The winbar legend for the window Neovim is currently drawing.
---
---Public only because the `winbar` option has to name something callable from
---Vimscript: it is set to a `%!` expression rather than to a fixed string, so
---the legend re-fits itself when the window is resized instead of being frozen
---at the width the dashboard happened to open with.
---@return string
function M.legend()
  local win = vim.g.statusline_winid
  if not (win and vim.api.nvim_win_is_valid(win)) then win = vim.api.nvim_get_current_win() end
  return _legend(vim.api.nvim_win_get_width(win))
end

---The `winbar` value installed on every interactive dashboard window.
local WINBAR = "%!v:lua.require'gitsuite.features.dashboard.view'.legend()"

---@private
---@internal
---Wires every binding in `ROW_KEYMAPS` onto a dashboard buffer, all acting on the
---repository row under the cursor. Safe to call repeatedly on a reused buffer —
---later calls just overwrite the mappings with closures over the current `records`.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param before_open? fun(): nil Passed through to `_open_readme`
---@return nil
local function _attach_row_keymaps(bufnr, records, before_open)
  local ctx = { bufnr = bufnr, records = records, before_open = before_open }
  local mo = { buffer = bufnr, nowait = true }

  for _, entry in ipairs(ROW_KEYMAPS) do
    for _, lhs in ipairs(entry.keys) do
      map("n", lhs, function()
        entry.run(ctx)
      end, mo, entry.desc)
      if entry.visual then
        map("x", lhs, function()
          entry.visual(ctx)
        end, mo, entry.desc)
      end
    end
  end
end

---@private
---@internal
---Opens the dashboard in a scrollable floating window (default output).
---@param lines string[]
---@param hls DashboardHighlight[]
---@param records RepoDashboardRecord[]
---@return nil
local function show_popup(lines, hls, records)
  local surf = kit.surface.open({
    lines = lines,
    title = M.summary(records),
    filetype = "gitsuite-dashboard",
    nice_quit = true,
    enter = true,
    focusable = true,
    -- +1 accounts for the winbar legend, which otherwise eats one row of
    -- content out of a height sized exactly to the number of dashboard lines
    -- (make_scratch still clamps this to the editor's available height).
    height = #lines + 1,
    wo = { wrap = false, cursorline = true, winbar = WINBAR },
  })
  if not surf then return end
  _set_buffer_lines(surf.bufnr, lines, hls)
  _attach_row_keymaps(surf.bufnr, records, function()
    surf:close()
  end)
end

---@private
---@internal
---Replaces the current window's buffer with the (reused) dashboard buffer.
---@param lines string[]
---@param hls DashboardHighlight[]
---@param records RepoDashboardRecord[]
---@return nil
local function show_buffer(lines, hls, records)
  local bufnr = vim.fn.bufnr(SCRATCH_NAME)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, SCRATCH_NAME)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "gitsuite-dashboard"
  end

  _set_buffer_lines(bufnr, lines, hls)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_set_option_value("winbar", WINBAR, { win = 0 })
  _attach_row_keymaps(bufnr, records)
end

---@private
---@internal
---Opens (or reuses) a split showing the dashboard buffer.
---@param lines string[]
---@param hls DashboardHighlight[]
---@param vertical boolean
---@param records RepoDashboardRecord[]
---@return nil
local function show_split(lines, hls, vertical, records)
  local bufnr, winid = open_named_scratch(SCRATCH_NAME, lines, {
    filetype = "gitsuite-dashboard",
    split = vertical and "right" or "below",
  })
  _set_buffer_lines(bufnr, lines, hls)
  vim.api.nvim_set_option_value("winbar", WINBAR, { win = winid })
  _attach_row_keymaps(bufnr, records)
end

---@private
---@internal
---Copies the raw dashboard table to the system clipboard.
---@param lines string[]
---@return nil
local function show_clipboard(lines)
  local ok = copy_to_clipboard(table.concat(lines, "\n"))
  if ok then
    notify("Dashboard copied to clipboard", 2)
  else
    notify("Failed to copy dashboard to clipboard", 4)
  end
end

---@private
---@internal
---Writes the raw dashboard table to a file (custom path, or a default under stdpath("cache")).
---@param lines string[]
---@param path string|nil
---@return nil
local function show_path(lines, path)
  local target = (path and path ~= "") and expand_path(path) or DEFAULT_PATH_OUT
  local ok, err = write_to_file(target, table.concat(lines, "\n"))
  if ok then
    notify("Dashboard written to " .. target, 2)
  else
    notify("Failed to write dashboard: " .. tostring(err), 4)
  end
end

---Renders `records` and displays them via the requested output backend.
---@param records RepoDashboardRecord[]
---@param opts? { output?: GitSuiteDashboardOutputMode, path?: string, dir?: string, pages?: table[], page_index?: integer, on_switch_page?: fun(page: table, on_done: fun(records: RepoDashboardRecord[], errors: string[])) }
---@return nil
function M.show(records, opts)
  opts = opts or {}
  local mode = opts.output or "popup"
  local lines, hls = M.render(records)

  -- Only reset the sort cycle for a genuinely new scan, so `reopen()` (which
  -- replays the cached records) doesn't silently undo the user's chosen order.
  if records ~= (_last_view or {}).records then
    _discovery_order = vim.deepcopy(records)
    _sort_index = 1
  end
  _last_view = { records = records, opts = opts, line = (_last_view or {}).line or 2 }

  if mode == "popup" then
    show_popup(lines, hls, records)
  elseif mode == "buffer" then
    show_buffer(lines, hls, records)
  elseif mode == "split" then
    show_split(lines, hls, false, records)
  elseif mode == "vsplit" then
    show_split(lines, hls, true, records)
  elseif mode == "clipboard" then
    show_clipboard(lines)
  elseif mode == "path" then
    show_path(lines, opts.path)
  else
    notify("Unknown dashboard output mode: " .. tostring(mode), 4)
  end

  -- Restore the row the user was on before the dashboard was last torn down.
  local win = vim.api.nvim_get_current_win()
  local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(_last_view.line, count), 0 })
end

---Re-displays the most recent dashboard, using the cached records rather than
---re-scanning the directory. Used to bring the dashboard back after it was
---closed to open a repository's README.
---@return boolean shown False when nothing has been displayed yet this session
function M.reopen()
  if not _last_view then
    notify("No dashboard to return to", 3)
    return false
  end
  M.show(_last_view.records, _last_view.opts)
  return true
end

return M
