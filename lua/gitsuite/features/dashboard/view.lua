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
--- asks, via `ui.kit`'s button-confirm dialog, whether to open that
--- repository's `README.md` (`:edit`, preselected) or browse its root
--- entries instead. Rows with no readable `README.md` skip straight to that
--- file/directory browser (a themed `ui.kit.select` list) rather than a dead-
--- end notification.
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
--- `gp`/`gP`/`gf`/`gu`/`gS` are the whole-directory forms, ignoring marks: push,
--- pull, fetch, update (fetch + ff-only pull, the same pair
--- `:Git dashboard update` runs), or sync (fetch, then pull what is behind and
--- push what is ahead) every repository in the dashboard. Batches run
--- sequentially and report through `utils.progress` -- these are network
--- calls, and forty simultaneous pushes are a rate limit or an auth-prompt
--- storm -- except fetch and sync, which run `dashboard.fetch_jobs` at once:
--- a sync is mostly its fetch, and a repository that needs a pull or a push
--- does it at once after its own fetch -- and every batch is confirmed first,
--- because unlike a single row there is nothing on screen that says what is
--- about to be touched.
---
--- A running batch does not freeze the table: every repository carries its own
--- phase (`features.dashboard.repo_state`: pending -> fetching -> done/failed),
--- shown in its STATE cell and counted in the title, and a row whose phase is
--- settled can be pushed/pulled/fetched while the batch works through the rest.
--- A per-repository lock keeps two writing `git` processes off the same
--- repository; queued or in-flight rows refuse with a message instead.

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
local contextmenu = require("lib.nvim.contextmenu")
local map = require("lib.nvim.bindings.keymap")
local open_named_scratch = require("lib.nvim.window.open_named_scratch")
local copy_to_clipboard = require("lib.nvim.cross.copy_to_clipboard")
local write_to_file = require("lib.nvim.fs.write.to_file")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local repo_actions = require("gitsuite.features.dashboard.actions")
local repos = require("gitsuite.features.dashboard.repos")
local dashboard_one = require("gitsuite.features.dashboard.status").dashboard_one
local repo_state = require("gitsuite.features.dashboard.repo_state")
local bulk_report = require("gitsuite.features.dashboard.bulk_report")
local progress = require("gitsuite.util.progress")
local notify = require("gitsuite.util.notify").notify
local notify_success = require("gitsuite.util.notify").success

---In-flight row actions, keyed by absolute path -> verb ("push", "pull", ...).
---Rendered in place of the row's state so a slow push isn't several seconds of
---no visible change at all.
---
---By path and not by row index, like `_marks`: `s` re-sorts the rows and a
---dashboard opened again mid-action is a fresh scan in discovery order, so an
---index-keyed spinner would land on (and lock out) another repository.
---@type table<string, string>
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
---batch, which walks its rows by index.
---@type string|nil
local _bulk_running

---The most recent dashboard, kept so the popup can be restored after it is torn
---down to open a README. Without this the records only lived in the popup's
---own closure, so closing it meant re-scanning the whole directory to get back.
---@type { records: RepoDashboardRecord[], opts: table, line: integer }|nil
local _last_view

---The dashboard on screen now: the buffer its row keymaps are bound to and the
---records they act on. A batch or row action keeps the buffer and records it
---was started from, but those are gone once the dashboard is closed and opened
---again mid-run (a fresh scan, a fresh buffer) -- so every redraw also lands
---here, and a re-read row is stored here too, or the reopened dashboard would
---keep showing "fetch..." for rows the run long finished.
---@type { bufnr: integer, records: RepoDashboardRecord[] }|nil
local _view

---Every row re-read after an action (see `_store_record`), by path, stamped
---with `_reread_seq` at the time it was stored. A scan running alongside a
---batch (`:Git dashboard` again mid-run) may read a repository before the
---batch's action on it lands; `M.show` puts the newer re-read back in.
---@type table<string, { record: RepoDashboardRecord, seq: integer }>
local _rereads = {}

---Bumped by every stored re-read; see `M.reread_mark`.
---@type integer
local _reread_seq = 0

---Discovery-order snapshot as path -> rank, so the `s` sort cycle can return
---to the order the directory scan produced without re-running it. Only the
---order is kept, never the records: a row re-read since the scan must keep its
---new state when the cycle comes back to discovery order.
---@type table<string, integer>
local _discovery_order = {}

---@private
---@internal
---Builds the path -> rank map `_discovery_order` holds for `records`.
---@param records RepoDashboardRecord[] Dashboard records in discovery order
---@return table<string, integer>
local function _discovery_ranks(records)
  local ranks = {}
  for i, r in ipairs(records) do
    ranks[r.path] = ranks[r.path] or i
  end
  return ranks
end

---Index into `SORT_MODES`; 1 is discovery order.
local _sort_index = 1

local SCRATCH_NAME = "gitsuite://dashboard"
local DEFAULT_PATH_OUT = vim.fn.stdpath("cache") .. "/gitsuite/dashboard.txt"
local SPINNER = "⟳"
---STATE-cell prefixes of a row the running batch has queued / failed on.
local QUEUED = "·"
local FAILED = "✗"
---How often a batch retries a repository whose lock somebody else holds.
local LOCK_RETRY_MS = 100

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
  if r.unscanned then return "" end
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
    local pending = _pending[r.path]
    local phase = repo_state.phase(r.path)
    if pending then
      state = ("%s %s..."):format(SPINNER, pending)
    elseif phase == "pending" then
      state = ("%s %s queued"):format(QUEUED, repo_state.bulk_verb())
    elseif phase == "fetching" then
      state = ("%s %s..."):format(SPINNER, repo_state.bulk_verb())
    elseif phase == "failed" then
      state = ("%s %s failed"):format(FAILED, repo_state.bulk_verb())
    end
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

    local phase = repo_state.phase(r.path)
    local state_hl
    if _pending[r.path] or phase == "fetching" then
      state_hl = HL.pending
    elseif phase == "pending" then
      state_hl = HL.muted
    elseif phase == "failed" or r.state == "error" then
      state_hl = HL.diverged
    elseif r.unscanned then
      state_hl = HL.muted
    else
      state_hl = HL[r.state] or HL.muted
    end
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
  -- A running batch says how far it got, so "which rows are still running" is
  -- answered without scrolling the table for spinners.
  local verb = repo_state.bulk_verb()
  if verb then
    local c = repo_state.counts()
    parts[#parts + 1] = ("%s %d/%d"):format(verb, c.done + c.failed, c.total)
  end

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
---Hard cap on entries listed per directory level. `_list_repo_entries` scans
---synchronously (`fs_scandir`/`fs_scandir_next`/`fs_stat`, no async variant
---threaded through the picker), so an unbounded scan of a huge or
---symlink-heavy directory -- a checked-in `node_modules`/`vendor` tree, say
----- would block Neovim's UI for however long that scan takes. Stopping
---after this many entries keeps the worst case bounded without having to
---rearchitect the picker as async; ordinary repo roots never come close.
local MAX_ENTRIES = 1000

---@private
---@internal
---Lists `dir`'s entries (files and directories, `.git` excluded), sorted
---case-insensitively and capped at `MAX_ENTRIES` (see above; the second
---return value reports whether the cap was hit). A symlink is resolved via
---`fs_realpath` and excluded unless its real target stays inside
---`repo_root` -- without this, a single symlink pointing outside the
---repository (accidental or crafted) would let the browser recurse into and
---`:edit` arbitrary files elsewhere on disk, with the picker showing only
---the bare entry name and no indication anything left the repo. A symlink
---that resolves inside the repo is otherwise classified normally via
---`fs_stat` (`fs_scandir_next` alone reports it as `"link"`, not
---`"directory"`).
---@param dir string
---@param repo_root string Absolute repo root; bounds symlink containment
---@return { name: string, is_dir: boolean }[] entries
---@return boolean truncated
local function _list_repo_entries(dir, repo_root)
  local uv = vim.uv or vim.loop
  local entries = {}
  local handle = uv.fs_scandir(dir)
  if not handle then return entries, false end

  -- `root_real` is nil when `repo_root` itself can't be resolved (a
  -- transient sharing violation, a network share, ...). Falling back to the
  -- raw, non-canonicalized `repo_root` here while every symlink TARGET below
  -- is always compared via its fully resolved real path would be an
  -- asymmetric comparison: if `repo_root`'s literal spelling ever differs
  -- from its canonical form (a `subst` drive, a junction in its ancestry, an
  -- 8.3 short name), a genuinely in-repo symlink could silently fail the
  -- prefix check and vanish from the listing with no error shown. Instead,
  -- when the root itself can't be resolved, containment can't be verified
  -- for ANY symlink this call encounters, so every symlink is excluded
  -- (fail closed) rather than compared against an unreliable raw string.
  local root_real = uv.fs_realpath(repo_root)
  local root_key = root_real and repos.normalize_path(root_real)
  local truncated = false

  -- Counts every entry the scan LOOKS AT, not just the ones that end up
  -- included: a directory dominated by excluded symlinks (e.g. a pnpm
  -- node_modules, whose symlinks by design resolve outside the repo) would
  -- otherwise never trip this cap -- #entries would stay near zero while the
  -- loop kept paying a blocking fs_realpath per excluded symlink over the
  -- whole directory, reproducing the unbounded-scan problem this cap exists
  -- to prevent.
  local scanned = 0

  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    if name ~= ".git" then
      -- Checked only once a *real* next entry is confirmed to exist (i.e.
      -- after this fs_scandir_next call already returned one): checking
      -- `scanned >= MAX_ENTRIES` before fetching the next entry would report
      -- `truncated = true` for a directory with EXACTLY MAX_ENTRIES entries
      -- too, even though nothing was actually cut -- a false-positive "more
      -- were truncated" notification for the common case of a directory
      -- that just happens to land on the cap.
      if scanned >= MAX_ENTRIES then
        truncated = true
        break
      end
      scanned = scanned + 1
      local path = dir .. "/" .. name
      local is_dir = typ == "directory"
      local include = true
      if typ == "link" then
        local target_real = root_key and uv.fs_realpath(path)
        local target_key = target_real and repos.normalize_path(target_real)
        include = target_key ~= nil
          and (target_key == root_key or target_key:sub(1, #root_key + 1) == root_key .. "/")
        if include then
          local stat = uv.fs_stat(path)
          is_dir = stat ~= nil and stat.type == "directory"
        end
      end
      if include then entries[#entries + 1] = { name = name, is_dir = is_dir } end
    end
  end

  table.sort(entries, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return entries, truncated
end

---@private
---@internal
---Opens `path` (`:edit`) and, on an interactive dashboard, binds `q` to wipe
---it and return to the dashboard. Shared by the README shortcut and the
---file browser below.
---@param path string
---@param before_open? fun(): nil Called right before the file is opened (e.g. to close a popup)
---@return nil
local function _open_repo_path(path, before_open)
  if before_open then before_open() end
  vim.cmd.edit(vim.fn.fnameescape(path))

  -- Bound explicitly rather than via a BufWinLeave autocmd: navigating away
  -- with `:edit other` would also fire that, and silently resurrecting the
  -- dashboard on an unrelated buffer switch is worse than not restoring it.
  if not _last_view then return end
  local buf = vim.api.nvim_get_current_buf()
  map("n", "q", function()
    vim.cmd("bwipeout")
    M.reopen()
  end, { buffer = buf, nowait = true }, "Close and return to the gitsuite dashboard")
  notify("q returns to the dashboard", 3)
end

---@private
---@internal
---Lets the user pick a file or directory from `record`'s root -- or, on a
---recursive call, from one of its subdirectories -- to jump into. This is
---the fallback when there is no README.md, and also reachable as a third
---option when there is one. README.md, when present, is preselected (root
---level only).
---
---Selecting a directory re-opens this same picker one level deeper instead
---of `:edit`ing it: `:edit <dir>` only does anything useful when a file
---explorer plugin (netrw, or a replacement) has claimed directory buffers,
---which this codebase cannot assume -- e.g. this user's own config disables
---netrw outright in favor of a separate filetree plugin that never sees a
---`:edit`-opened directory buffer. A `..` entry is added below the repo root
---so a wrong turn isn't a dead end (root itself has none, so browsing can't
---walk above the repository).
---@param record RepoDashboardRecord
---@param before_open? fun(): nil
---@param dir? string Absolute path to browse; defaults to `record.path`
---@param label? string Short display name for `dir`; defaults to `record.name`
---@return nil
local function _browse_repo(record, before_open, dir, label)
  local base_dir = dir or record.path
  local entries, truncated = _list_repo_entries(base_dir, record.path)
  local at_root = base_dir == record.path
  if not at_root then table.insert(entries, 1, { name = "..", is_dir = true, up = true }) end
  if #entries == 0 then
    notify("No files found in " .. (label or record.name), 3)
    return
  end
  if truncated then
    notify(
      ("Showing first %d entries of %s (more were truncated)"):format(
        MAX_ENTRIES,
        label or record.name
      ),
      3
    )
  end

  local initial_index = 1
  if at_root then
    for i, e in ipairs(entries) do
      if not e.is_dir and e.name:lower() == "readme.md" then
        initial_index = i
        break
      end
    end
  end

  -- Remember where we were before the popup is torn down, so `q` can put the
  -- dashboard back on the same row.
  if _last_view then _last_view.line = vim.api.nvim_win_get_cursor(0)[1] end

  kit.select({
    items = entries,
    title = ('Jump into "%s"'):format(label or record.name),
    format_item = function(e)
      if e.up then return ".." end
      return e.is_dir and (e.name .. "/") or e.name
    end,
    initial_index = initial_index,
    on_select = function(entry)
      if entry.up then
        local parent = vim.fn.fnamemodify(base_dir, ":h")
        local parent_label = parent == record.path and record.name
          or vim.fn.fnamemodify(parent, ":t")
        _browse_repo(record, before_open, parent, parent_label)
        return
      end
      local path = base_dir .. "/" .. entry.name
      if entry.is_dir then
        _browse_repo(record, before_open, path, entry.name)
      else
        _open_repo_path(path, before_open)
      end
    end,
  })
end

---@private
---@internal
---Confirms with the user, then opens `record`'s README.md (`:edit`, the
---preselected default) -- or, when there is no README.md, or the user picks
---"Browse files…", lets them jump to any file/directory in the repo root
---instead (see `_browse_repo`).
---@param record RepoDashboardRecord
---@param before_open? fun(): nil Called right before the file is opened (e.g. to close a popup)
---@return nil
local function _open_readme(record, before_open)
  local readme_path = record.path .. "/README.md"
  if not require("lib.nvim.fs.is_readable_file")(readme_path) then
    _browse_repo(record, before_open)
    return
  end

  -- Remember where we were before the popup is torn down, so `q` can put the
  -- dashboard back on the same row.
  if _last_view then _last_view.line = vim.api.nvim_win_get_cursor(0)[1] end

  kit.confirm({
    question = ('Open README.md of "%s"?'):format(record.name),
    choices = { "Open README.md", "Browse files…" },
    on_answer = function(choice)
      if choice == "Open README.md" then
        _open_repo_path(readme_path, before_open)
      elseif choice == "Browse files…" then
        _browse_repo(record, before_open)
      end
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
---Widest display cell any of `lines` needs, plus the two-cell margin
---`lib.nvim.window.make_scratch` itself gives a float whose width was never
---given explicitly -- mirrored here so a *resize* ends up exactly as wide as
---an `M.open` with these same `lines` would have opened.
---@param lines string[]
---@return integer
local function _content_width(lines)
  local w = 0
  for _, line in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(line))
  end
  return w + 2
end

---@private
---@internal
---Resizes a floating window to fit `lines` and re-centers it, exactly as
---`lib.nvim.window.make_scratch` sizes and centers one at open -- a resize
---has to redo that math itself, since changing `width`/`height` alone would
---leave the window's top-left corner fixed and the float drifting off-centre
---as it grows or shrinks. A no-op on a window that isn't a float (or isn't
---valid any more) rather than an error, since the live popup's window may
---have been closed by the user while its scan was still running.
---
---`title`, when given, widens the float to fit it as well: the title is
---drawn into the top border, and one wider than the window is cut off from
---the left ("<te Dashboard — ..."). Both sizes are clamped to the editor the
---way `make_scratch` clamps them at open, so a resize never asks for more
---than the screen has.
---@param winid integer
---@param lines string[]
---@param title string|nil
---@return nil
local function _resize_float(winid, lines, title)
  if not vim.api.nvim_win_is_valid(winid) then return end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, winid)
  if not (ok and cfg and cfg.relative and cfg.relative ~= "") then return end
  local width = _content_width(lines)
  if title then width = math.max(width, vim.fn.strdisplaywidth(title)) end
  width = math.max(1, math.min(width, vim.o.columns - 4))
  -- +1 accounts for the winbar legend, which otherwise eats one row of
  -- content out of a height sized exactly to the number of dashboard lines
  -- (see `show_popup`'s own fresh-open height, which this mirrors).
  local height = math.max(1, math.min(#lines + 1, vim.o.lines - 4))
  cfg.width = width
  cfg.height = height
  cfg.row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
  cfg.col = math.max(0, math.floor((vim.o.columns - width) / 2))
  pcall(vim.api.nvim_win_set_config, winid, cfg)
end

---@private
---@internal
---Redraws the whole table into `bufnr`, preserving the cursor position.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@return nil
local function _draw(bufnr, records)
  local win = vim.fn.bufwinid(bufnr)
  local cursor = (win ~= -1) and vim.api.nvim_win_get_cursor(win) or nil
  local lines, hls = M.render(records)
  _set_buffer_lines(bufnr, lines, hls)
  if cursor then pcall(vim.api.nvim_win_set_cursor, win, cursor) end

  -- A float's title is stamped once at open, but the summary it carries counts
  -- marks and dirty repositories -- both of which change while the window
  -- stays open. Re-stamping here is what keeps "3 marked" honest.
  -- Its size is fitted again too: a batch widens the table while it runs (the
  -- STATE column's "⟳ fetch...", a SYNC column once the first fetch lands)
  -- and the summary grows by "fetch 1/6"; a float kept at its open width cut
  -- LAST COMMIT off on the right and the title off on the left.
  if win ~= -1 then
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg and cfg.relative and cfg.relative ~= "" and cfg.title then
      local title = M.summary(records)
      cfg.title = title
      pcall(vim.api.nvim_win_set_config, win, cfg)
      _resize_float(win, lines, title)
    end
  end
end

---@private
---@internal
---Redraws `records` into `bufnr`, and the dashboard on screen now (`_view`) as
---well when that is another one: a run started from a dashboard that was
---closed and reopened meanwhile still keeps the reopened one current. The
---current one is drawn last, so where both share a buffer it wins.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@return nil
local function _redraw(bufnr, records)
  _draw(bufnr, records)
  local view = _view
  if view and (view.bufnr ~= bufnr or view.records ~= records) then
    _draw(view.bufnr, view.records)
  end
end

---@private
---@internal
---Replaces the row of `new_record`'s repository in `list`, if it holds one.
---@param list RepoDashboardRecord[]
---@param new_record RepoDashboardRecord
---@return nil
local function _replace_by_path(list, new_record)
  for i, r in ipairs(list) do
    if r.path == new_record.path then
      list[i] = new_record
      return
    end
  end
end

---@private
---@internal
---Stores a re-read row by path: into the `records` the action was started on,
---and into the dashboard on screen now when that holds other records (see
---`_view`).
---
---By path and not at the index the row had when the re-read began: `s` may
---re-sort the rows and a page reload may refill them while the re-read runs,
---so that index can hold another repository by now.
---@param records RepoDashboardRecord[]
---@param new_record RepoDashboardRecord|nil Nil when the re-read failed: nothing changes
---@return nil
local function _store_record(records, new_record)
  if not new_record then return end
  _reread_seq = _reread_seq + 1
  _rereads[new_record.path] = { record = new_record, seq = _reread_seq }
  _replace_by_path(records, new_record)
  local current = _view and _view.records
  if current and current ~= records then _replace_by_path(current, new_record) end
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
      _store_record(records, new_record)
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
---@param action_fn fun(repo: string, on_done: GitSuiteDashboardActionDone): nil One of `repo_actions.push/pull/fetch`
---@return nil
local function _run_row_action(bufnr, records, verb, action_fn)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local idx = line - 1
  local record = records[idx]
  if not record then return end
  if _pending[record.path] then
    notify(("%s: %s already running"):format(record.name, _pending[record.path]), 3)
    return
  end
  -- A running batch no longer blocks every row: only the rows it has not
  -- settled yet refuse, and the lock keeps this action and any other writer
  -- off the same repository (see `features.dashboard.repo_state`).
  local acquired, why = repo_state.acquire(record.path, verb)
  if not acquired then
    notify(("%s: %s"):format(record.name, why), 3)
    return
  end

  -- WARN (not INFO): a deliberate "in progress" color, distinct from the
  -- green notify_success() the completion below uses on success and the red
  -- ERROR on failure. (An earlier version of this comment claimed INFO-level
  -- messages are invisible by default -- that isn't true of this codebase's
  -- actual notify config, toast_min_level is INFO; don't revive that as a
  -- reason to keep this WARN if it's ever revisited.)
  notify(("%s %s ..."):format(verb, record.name), 3)
  local handle = progress.create(("%s %s"):format(verb, record.name))

  _pending[record.path] = verb
  _redraw(bufnr, records)

  local function on_done(ok, err)
    vim.schedule(function()
      repo_state.unlock(record.path)
      -- The lock held until just now keeps any other action off this
      -- repository, so its spinner is this action's own.
      _pending[record.path] = nil
      if ok then
        notify_success(("%s: %s done"):format(record.name, verb))
        if handle then handle:finish(("%s %s done"):format(verb, record.name)) end
      else
        notify(("%s: %s failed - %s"):format(record.name, verb, err or "unknown error"), 4)
        if handle then handle:finish(("%s %s failed"):format(verb, record.name)) end
      end
      -- The row may have moved meanwhile (`s` re-sorts in place): look it
      -- up again by path. `_store_record` also carries the re-read into a
      -- dashboard opened again since.
      for i, r in ipairs(records) do
        if r.path == record.path then
          _refresh_row(bufnr, records, i)
          return
        end
      end
      _redraw(bufnr, records)
    end)
  end

  -- A synchronous throw must not leave the lock held: the repository would
  -- refuse every later action until Neovim restarts.
  local started, start_err = pcall(action_fn, record.path, on_done)
  if not started then on_done(false, tostring(start_err)) end
end

---@private
---@internal
---Refuses a new batch while one is running, with the message saying so.
---Called before a batch's question is asked, so a second `gf` (or `gF`, `gP`,
---...) during a batch is refused at once instead of after a pointless yes.
---@return boolean refused
local function _refuse_while_bulk()
  if not _bulk_running then return false end
  notify(("A bulk %s is already running"):format(_bulk_running), 3)
  return true
end

---@private
---@internal
---Runs `action_fn` against every record named by `indices`, one after another,
---then reports a single summary: per repository what changed, what failed and
---why, what was skipped, and a count of the rest
---(`gitsuite.features.dashboard.bulk_report`).
---
---One after another for push and pull: `git push` over forty clones at once is a rate
---limit, forty credential prompts, or both, and the queue is the same shape
---`repo_updater` already uses for a directory-wide update. Cancelling through
---the progress handle stops the queue from starting further repositories
---rather than killing the one in flight -- interrupting a `pull` mid-write is
---the one outcome worth avoiding. A `fetch` batch is the exception: it only
---reads the remote, so `dashboard.fetch_jobs` of them run at once.
---@param bufnr integer
---@param records RepoDashboardRecord[]
---@param verb string Human-readable action name, used in notifications
---@param action_fn fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
---@param indices integer[] Record indices to act on, in row order
---@return nil
local function _run_bulk(bufnr, records, verb, action_fn, indices)
  local total = #indices
  if total == 0 then return end

  -- Checked again here: a batch may have started while the question was open.
  if _refuse_while_bulk() then return end
  ---@type string[]
  local paths = {}
  for _, idx in ipairs(indices) do
    local busy = _pending[records[idx].path] or repo_state.holder(records[idx].path)
    if busy then
      notify(("%s: %s already running"):format(records[idx].name, busy), 3)
      return
    end
    paths[#paths + 1] = records[idx].path
  end

  -- Every target is queued up front, so the whole batch is visible as a column
  -- of "queued" cells instead of one row lighting up at a time with no clue
  -- what else is behind it. Per-repository phases (not `_pending`) carry this,
  -- so a row the batch is through with can take its own action meanwhile.
  _bulk_running = verb
  -- The generation keeps this batch's callbacks out of a newer batch's phases:
  -- should one start before this one is through (a page reload resets
  -- `_bulk_running`), this one's late callbacks still release their locks but
  -- neither move the newer batch's rows nor end it.
  local generation = repo_state.begin_bulk(verb, paths)
  _redraw(bufnr, records)

  local handle = progress.create(("%s %d repositories"):format(verb, total), total)
  local cancelled = false
  if handle then handle:on_cancel(function()
    cancelled = true
  end) end

  -- Filled per position in `indices`, so the summary lists repositories in
  -- row order whichever of the parallel ones finished first.
  ---@type table<integer, GitSuiteBulkResult>
  local results = {}
  local succeeded, completed = 0, 0
  -- Only `fetch` and `sync` run several at once: a fetch reads the remote and
  -- nothing else, and a sync is a fetch first (a pull or push follows only for
  -- the repositories that are behind or ahead, and `dashboard.fetch_jobs` bounds
  -- those too), while a push or pull over many clones at once is the rate limit /
  -- prompt storm described above.
  local limit = (verb == "fetch" or verb == "sync")
      and require("gitsuite.config").get().dashboard.fetch_jobs
    or 1
  local next_pos, running, finished = 1, 0, false

  local function finish()
    -- Clears the queue's own phases as well as the cancelled tail's. Row
    -- actions started meanwhile keep their `_pending` spinner and lock. A
    -- superseded batch ends nothing: the running flag is the newer one's.
    if repo_state.end_bulk(generation) then _bulk_running = nil end
    _redraw(bufnr, records)

    if handle then handle:finish(("%s: %d of %d repositories"):format(verb, succeeded, total)) end
    ---@type GitSuiteBulkResult[]
    local ordered = {}
    for pos = 1, total do
      if results[pos] then ordered[#ordered + 1] = results[pos] end
    end
    local message, any_failed = bulk_report.format(verb, ordered, total)
    if any_failed then
      notify(message, vim.log.levels.WARN)
    else
      notify_success(message)
    end
  end

  local pump

  local function launch(record, pos)
    repo_state.set_phase(record.path, "fetching", generation)
    _redraw(bufnr, records)
    if handle then handle:update({ text = record.name, current = completed, total = total }) end

    local function on_done(ok, err, detail, skipped)
      vim.schedule(function()
        repo_state.unlock(record.path)
        if ok then succeeded = succeeded + 1 end
        results[pos] = {
          name = record.name,
          ok = ok and true or false,
          err = (not ok) and (err or "unknown error") or nil,
          detail = ok and detail or nil,
          skipped = ok and skipped or nil,
        }

        -- The row is re-read *before* its slot is given up, not alongside it:
        -- fired off in parallel, the last repository's re-read would still be
        -- in flight when `finish()` draws the table and announces the batch as
        -- done, leaving that one row showing the state it had before its own
        -- push. The phase settles only after that re-read, so a row action
        -- started on it never races the batch's own stale refresh.
        dashboard_one(record.path, function(new_record)
          vim.schedule(function()
            _store_record(records, new_record)
            repo_state.set_phase(record.path, ok and "done" or "failed", generation)
            _redraw(bufnr, records)
            running = running - 1
            completed = completed + 1
            pump()
          end)
        end)
      end)
    end

    local started, start_err = pcall(action_fn, record.path, on_done)
    if not started then on_done(false, tostring(start_err)) end
  end

  -- Fills the free slots in row order; also the way the batch ends, once the
  -- last slot is given back.
  pump = function()
    if finished then return end
    while running < limit and not cancelled and next_pos <= total do
      local idx = indices[next_pos]
      local record = records[idx]
      -- Row actions only start on settled rows and this one is still queued, so
      -- the lock is normally free; should anything else hold it, the queue waits
      -- for it rather than starting a second `git` on the same repository.
      if not repo_state.try_lock(record.path, verb) then
        vim.defer_fn(pump, LOCK_RETRY_MS)
        return
      end
      local pos = next_pos
      next_pos = next_pos + 1
      running = running + 1
      launch(record, pos)
    end
    if running == 0 and (cancelled or next_pos > total) then
      finished = true
      finish()
    end
  end

  pump()
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
---@param action_fn fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
---@param indices integer[]
---@param what string Noun phrase describing the target set, e.g. "marked repositories"
---@return nil
local function _confirm_bulk(bufnr, records, verb, action_fn, indices, what)
  if #indices == 0 then
    notify("No repositories to " .. verb, 3)
    return
  end
  if _refuse_while_bulk() then return end

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
---@param action_fn fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
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
---@param action_fn fun(repo: string, on_done: GitSuiteDashboardActionDone): nil
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

---@private
---@internal
---`gP`: asks whether to pull only the repositories behind their upstream or
---all of them (`dashboard.pull_scope` picks the focused default), naming the
---ones whose behind state is unknown, then runs the chosen batch.
---@param ctx DashboardRowContext
---@return nil
local function _pull_all(ctx)
  if #ctx.records == 0 then
    notify("No repositories to pull", 3)
    return
  end
  if _refuse_while_bulk() then return end
  local scope = require("gitsuite.config").get().dashboard.pull_scope
  local plan = require("gitsuite.features.dashboard.pull_scope").plan(ctx.records, scope)
  kit.confirm({
    question = plan.question,
    choices = plan.choices,
    on_answer = function(choice)
      local indices = choice and plan.targets[choice]
      if not indices then return end
      if #indices == 0 then
        notify("No repositories behind their upstream - fetch first (gf) or pull all", 3)
        return
      end
      _run_bulk(ctx.bufnr, ctx.records, "pull", repo_actions.pull, indices)
    end,
  })
end

---@private
---@internal
---Where `E` can send a report, in the order they are offered.
---@type { label: string, id: "clipboard"|"buffer"|"file" }[]
local EXPORT_TARGETS = {
  { label = "Clipboard", id = "clipboard" },
  { label = "New buffer", id = "buffer" },
  { label = "File", id = "file" },
}

---@private
---@internal
---Opens `lines` in a fresh scratch buffer; `q` wipes it and returns to the dashboard.
---@param lines string[]
---@param id string Report id, for the buffer's name
---@param before_open? fun(): nil Closes a popup dashboard first
---@return nil
local function _export_to_buffer(lines, id, before_open)
  if before_open then before_open() end
  vim.cmd.enew()
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "gitsuite://dashboard-export-" .. id)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if _last_view then
    map("n", "q", function()
      vim.cmd("bwipeout")
      M.reopen()
    end, { buffer = buf, nowait = true }, "Close and return to the gitsuite dashboard")
  end
end

---@private
---@internal
---Writes `lines` to a path asked for, defaulting to a file under the cache directory.
---@param lines string[]
---@param id string Report id, for the default file name
---@return nil
local function _export_to_file(lines, id)
  local default = ("%s/gitsuite/dashboard-%s.txt"):format(vim.fn.stdpath("cache"), id)
  vim.ui.input(
    { prompt = "Export to file: ", default = default, completion = "file" },
    function(input)
      if not input or input == "" then return end
      local target = expand_path(input)
      local ok, err = write_to_file(target, table.concat(lines, "\n") .. "\n")
      if ok then
        notify("Dashboard written to " .. target, 2)
      else
        notify("Failed to write dashboard: " .. tostring(err), 4)
      end
    end
  )
end

---@private
---@internal
---`E`: asks which report to export (all with status, dirty, behind, ...), then
---where to put it (clipboard, new buffer, file).
---@param ctx DashboardRowContext
---@return nil
local function _export(ctx)
  local export = require("gitsuite.features.dashboard.export")
  if #ctx.records == 0 then
    notify("No repositories to export", 3)
    return
  end
  local reports = export.reports(ctx.records)
  kit.select({
    items = reports,
    title = "Export which repositories?",
    format_item = function(rep)
      return rep.label
    end,
    on_select = function(rep)
      if #rep.indices == 0 then
        notify("Nothing to export: no repository is " .. rep.title, 3)
        return
      end
      kit.select({
        items = EXPORT_TARGETS,
        title = ("Export %s to"):format(rep.title),
        format_item = function(target)
          return target.label
        end,
        on_select = function(target)
          local lines = export.build(rep.id, ctx.records)
          if not lines then return end
          if target.id == "clipboard" then
            if copy_to_clipboard(table.concat(lines, "\n")) then
              notify(("Copied %s to the clipboard"):format(rep.label), 2)
            else
              notify("Failed to copy to the clipboard", 4)
            end
          elseif target.id == "buffer" then
            _export_to_buffer(lines, rep.id, ctx.before_open)
          else
            _export_to_file(lines, rep.id)
          end
        end,
      })
    end,
  })
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
---@param ranks table<string, integer> Discovery-order snapshot (path -> rank)
---@return nil
local function _sort_records(records, mode, ranks)
  table.sort(records, function(a, b)
    if mode == "discovery" then
      local ra, rb = ranks[a.path] or math.huge, ranks[b.path] or math.huge
      if ra ~= rb then return ra < rb end
      return a.name:lower() < b.name:lower()
    elseif mode == "name" then
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
---Guards against `_switch_page` firing twice before its own async scan
---resolves (e.g. a double-tap on the page-next key): `_last_view.opts.
---page_index` only advances once that scan's callback runs, so two
---quick presses would otherwise both compute the same target page and
---dispatch two overlapping, redundant scans of it, whichever resolves last
---silently winning.
---@type boolean
local _page_switching = false

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
  -- A page reload starts from a clean slate (`_pending` is reset below);
  -- a row action still running would lose its spinner and its re-read
  -- would land on a page that may not even hold its repository.
  if next(_pending) ~= nil then
    notify("Cannot switch pages while a row action is still running", 3)
    return
  end
  if _page_switching then
    notify("Already loading a page -- wait for it to finish", 3)
    return
  end

  local current_index = view_state.opts.page_index or 1
  local new_index = ((current_index - 1 + delta) % #pages) + 1
  local page = pages[new_index]

  _page_switching = true
  notify(("Loading %s ..."):format(page.name or "dashboard"), 3)
  -- `on_switch_page` is a caller-supplied callback (features/dashboard/
  -- init.lua's `scan_page`) that can throw synchronously -- e.g. a
  -- malformed `dashboard.groups` entry that slipped past config
  -- validation -- before it ever invokes its own `on_done`. Without the
  -- pcall, that leaves `_page_switching` stuck `true` forever: every later
  -- `<C-l>`/`<C-h>`/`R` hits the guard above and refuses to run, for the
  -- rest of the session.
  local switch_ok, switch_err = pcall(on_switch_page, page, function(records, errors)
    vim.schedule(function()
      _page_switching = false
      _pending = {}
      _marks = {}
      _sort_index = 1
      _bulk_running = nil
      repo_state.end_bulk()
      _discovery_order = _discovery_ranks(records)
      for i = #ctx.records, 1, -1 do
        ctx.records[i] = nil
      end
      for i, r in ipairs(records) do
        ctx.records[i] = r
      end

      local new_opts = vim.tbl_extend("force", view_state.opts, { page_index = new_index })
      -- The rows on screen (`ctx.records`, filled in place), not the scan's
      -- own table: a re-read or re-sort changes only those, and `reopen()`
      -- must show them, not the stale, unsorted scan.
      _last_view = { records = ctx.records, opts = new_opts, line = 2 }
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
  if not switch_ok then
    _page_switching = false
    notify(("Failed to load %s: %s"):format(page.name or "dashboard", switch_err), 4)
  end
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
    label = "<CR> Open",
    desc = "Open README.md (or browse files) of repository under cursor",
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
    desc = "Pull the repositories behind their upstream, or every one (asks; marks ignored)",
    run = function(ctx)
      _pull_all(ctx)
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
    keys = { "gS" },
    desc = "Sync every repository in the dashboard: fetch, then pull those behind and push those ahead; diverged ones are only reported (marks ignored)",
    run = function(ctx)
      _run_all(ctx, "sync", repo_actions.sync)
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
      -- A batch walks its rows by index, so reordering mid-batch would move
      -- rows out from under it. Row actions (`_pending`, by path) look their
      -- row up again by path once they settle and do not block a re-sort.
      if _bulk_running then
        notify(("Cannot re-sort while a bulk %s is running"):format(_bulk_running), 3)
        return
      end

      _sort_index = (_sort_index % #SORT_MODES) + 1
      local mode = SORT_MODES[_sort_index]
      _sort_records(ctx.records, mode, _discovery_order)
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
    keys = { "E" },
    label = "E Export",
    desc = "Export a report (all, dirty, behind, ...) to the clipboard, a new buffer or a file",
    run = _export,
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

-- ── Context menu (<RightMouse>) ──────────────────────────────────────────
-- Right-click opens a menu built entirely from `ROW_KEYMAPS` itself (via
-- `_keymap_entry` below): every item calls the exact same `entry.run(ctx)`
-- a key already does, so there is no second implementation of fetch/pull/
-- push/mark/open/... to keep in sync with the keys. "Owns its buffer" shape
-- (see `lib.nvim.contextmenu`'s README) -- this lives beside the keymaps it
-- mirrors rather than in `gitsuite.integrations.menu` (a "contributes only"
-- module for OTHER plugins' buffers), the same split filetree.nvim draws
-- between its own `features/ui/context_menu` and `integrations/menu.lua`.

---@private
---@internal
---Finds the `ROW_KEYMAPS` entry bound on `key` (its first lhs is enough --
---every entry's lhs set names one logical action). A lookup rather than a
---positional index into `ROW_KEYMAPS`, so reordering that table can never
---silently point a menu item at the wrong action.
---@param key string
---@return DashboardRowKeymap
local function _keymap_entry(key)
  for _, entry in ipairs(ROW_KEYMAPS) do
    if entry.keys[1] == key then return entry end
  end
  error("gitsuite dashboard context menu: no ROW_KEYMAPS entry for " .. key, 2)
end

---@private
---@internal
---One repository's lock/bulk-phase state, as a short phrase for a menu
---item's `rtxt` -- nil when nothing is holding it. Reads the exact same
---state `M.render`'s STATE column already shows (`repo_state.phase`/
---`.holder`), not a second "is this busy" policy: `repo_state.acquire` is
---still the one place that actually decides and refuses, reached the normal
---way once the item itself is clicked (`_run_row_action`).
---@param path string
---@return string|nil
local function _busy_reason(path)
  local phase = repo_state.phase(path)
  if phase == "pending" then return ("%s queued"):format(repo_state.bulk_verb()) end
  if phase == "fetching" then return ("%s running"):format(repo_state.bulk_verb()) end
  local holder = repo_state.holder(path)
  if holder then return holder .. " running" end
  return nil
end

---@private
---@internal
---The menu's items: with repositories marked, the bulk-capable actions
---(push/pull/fetch already switch to the marked set on their own -- see
---`_run_marked_or_row`) under a heading naming the count; otherwise the
---single-row actions for the repository under the cursor (moved there by
---`_dashboard_context_menu` below), headed by its name. The whole-dashboard
---group (marks ignored, same as `g`-prefixed keys) is always offered.
---@param ctx DashboardRowContext
---@return Lib.ContextMenu.Item[]
local function _context_menu_items(ctx)
  local out = {}

  ---@param key string
  ---@return fun(): nil
  local function call(key)
    local entry = _keymap_entry(key)
    return function()
      entry.run(ctx)
    end
  end

  local marked = _marked_indices(ctx.records)
  if #marked > 0 then
    contextmenu.group(
      out,
      contextmenu.heading(("%d marked repositories"):format(#marked)),
      contextmenu.entry(true, "Push", call("p"), "p"),
      contextmenu.entry(true, "Pull", call("P"), "P"),
      contextmenu.entry(true, "Fetch", call("f"), "f"),
      contextmenu.entry(true, "Clear marks", call("M"), "M")
    )
  else
    local record = _record_at_cursor(ctx.records)
    if record then
      local busy = _busy_reason(record.path)
      local busy_opts = busy and { hl = HL.muted } or nil
      contextmenu.group(
        out,
        contextmenu.heading(record.name),
        contextmenu.entry(true, "Open", call("<CR>"), "<CR>"),
        contextmenu.entry(true, "Push", call("p"), busy or "p", busy_opts),
        contextmenu.entry(true, "Pull", call("P"), busy or "P", busy_opts),
        contextmenu.entry(true, "Fetch", call("f"), busy or "f", busy_opts),
        contextmenu.entry(true, "Status", call("S"), "S"),
        contextmenu.entry(true, "Lazygit", call("L"), "L"),
        contextmenu.entry(true, "Re-read", call("r"), "r"),
        contextmenu.entry(true, _marks[record.path] and "Unmark" or "Mark", call("m"), "m"),
        contextmenu.entry(true, "Yank path", call("y"), "y"),
        contextmenu.entry(true, "Remove from page", call("x"), "x")
      )
    end
  end

  contextmenu.group(
    out,
    contextmenu.heading("Whole dashboard"),
    contextmenu.entry(#ctx.records > 0, "Fetch all", call("gf"), "gf"),
    contextmenu.entry(#ctx.records > 0, "Pull all…", call("gP"), "gP"),
    contextmenu.entry(#ctx.records > 0, "Push all", call("gp"), "gp"),
    contextmenu.entry(#ctx.records > 0, "Update all", call("gu"), "gu"),
    contextmenu.entry(#ctx.records > 0, "Sync all", call("gS"), "gS")
  )

  return out
end

---@private
---@internal
---Whether the current mode is some flavor of Visual (`v`/`V`/CTRL-V) -- the
---mode `<RightMouse>` fires in when a selection was left open by a previous
---drag/`m` and nothing has closed it since (the same condition `m`'s own
---Visual-mode handler is implicitly bound on, by mode `"x"`).
---@return boolean
local function _in_visual_mode()
  return vim.fn.mode():match("^[vV\22]") ~= nil
end

---@private
---@internal
---`get_items` for `contextmenu.bind_buffer`, called synchronously on
---`<RightMouse>`.
---
---A Visual selection is converted to marks first -- the exact same step
---`m`'s own Visual-mode handler takes (`_mark_rows`), so a selection and
---marks are one input to the items below, not two that could disagree.
---Otherwise the cursor moves to the row under the mouse pointer: every item
---`_context_menu_items` returns is borrowed from `ROW_KEYMAPS`, which acts
---on "the row under the cursor", so this is what makes that end up being
---the row the user actually pointed at rather than wherever the cursor was
---left standing.
---@param ctx DashboardRowContext
---@return Lib.ContextMenu.Item[]
local function _dashboard_context_menu(ctx)
  if _in_visual_mode() then
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then
      first, last = last, first
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    local changed = _mark_rows(ctx.records, first, last, true)
    _redraw(ctx.bufnr, ctx.records)
    if changed > 0 then
      notify(("Marked %d repositor%s"):format(changed, changed == 1 and "y" or "ies"), 3)
    end
  else
    local ok, pos = pcall(vim.fn.getmousepos)
    if ok and type(pos) == "table" and pos.winid == vim.api.nvim_get_current_win() then
      local idx = pos.line - 1
      if ctx.records[idx] then pcall(vim.api.nvim_win_set_cursor, pos.winid, { pos.line, 0 }) end
    end
  end

  return _context_menu_items(ctx)
end

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
  _view = { bufnr = bufnr, records = records }

  if require("gitsuite.config").get().dashboard.context_menu then
    contextmenu.bind_buffer(bufnr, function()
      return _dashboard_context_menu(ctx)
    end, { desc = "GitSuite dashboard: right-click context menu" })
  end

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

---The live-scan popup `M.live_begin` opens, kept so `M.live_discover`/
---`M.live_record` can keep filling it and `show_popup` can hand its window
---over to the finished table instead of opening a second one on top of it.
---`nil` while no scan is live.
---@type { surf: Lib.UI.Kit.Surface, order: string[], rows: table<string, RepoDashboardRecord> }|nil
local _live

---@private
---@internal
---The placeholder a not-yet-read repository is shown as. Its name is already
---known from the path alone (directory discovery, not a git call); every
---other column is unknown, which is what `unscanned` tells `_sync_cell` (so
---it reads blank rather than the misleading "no upstream") and `M.render`'s
---own highlight pick (so it reads muted rather than whatever `HL[r.state]`
---would otherwise resolve to).
---@param path string
---@return RepoDashboardRecord
local function _placeholder_record(path)
  return {
    name = vim.fn.fnamemodify(path, ":t"),
    path = path,
    branch = "",
    ahead = 0,
    behind = 0,
    has_upstream = false,
    dirty = 0,
    state = "scanning",
    last_commit = nil,
    unscanned = true,
  }
end

---@private
---@internal
---Re-renders `_live`'s rows, in discovery order, into its popup -- resizing
---it to fit every time, since a row's rendered width (a branch name, a sync
---count) is only known once that repository's own read comes back, unlike
---the row count itself (already fixed at `M.live_discover`). A no-op once
---the popup is gone (the user closed it mid-scan -- the scan itself is not
---cancelled by this, it simply has nowhere left to report into until it
---finishes and `show_popup` opens a fresh window for the final table).
---@return nil
local function _live_redraw()
  if not (_live and _live.surf:is_valid()) then return end
  local records = {}
  for _, path in ipairs(_live.order) do
    records[#records + 1] = _live.rows[path]
  end
  local lines, hls = M.render(records)
  _resize_float(_live.surf.winid, lines)
  _set_buffer_lines(_live.surf.bufnr, lines, hls)
  local done = 0
  for _, r in ipairs(records) do
    if not r.unscanned then done = done + 1 end
  end
  _live.surf:set_title(("GitSuite Dashboard — scanning %d/%d"):format(done, #records))
end

---Opens the live popup immediately, before anything about the scan it is
---about to show is known yet -- `:Git dashboard` used to read every
---repository before opening any window at all, which on a directory of a
---few dozen clones was a noticeable wait staring at nothing. A no-op (and
---`false`) for every output mode but "popup": `show_buffer`/`show_split`
---already reuse their window/buffer across calls, so the wait this closes
---was never theirs to begin with.
---@param mode GitSuiteDashboardOutputMode
---@return boolean started
function M.live_begin(mode)
  if mode ~= "popup" then return false end
  local surf = kit.surface.open({
    lines = { "Scanning repositories ..." },
    title = "GitSuite Dashboard",
    filetype = "gitsuite-dashboard",
    nice_quit = true,
    enter = true,
    focusable = true,
    height = 2,
    wo = { wrap = false, cursorline = true, winbar = WINBAR },
  })
  if not surf then return false end
  _live = { surf = surf, order = {}, rows = {} }
  return true
end

---Replaces the placeholder line with one row per repository -- called once,
---synchronously, as soon as the full repository list is known, before any of
---their statuses are read. The row count is fixed from here on (every name
---is already known from its path); the window's width still grows and
---shrinks as branches and sync counts come in -- see `_live_redraw`.
---@param paths string[]
---@return nil
function M.live_discover(paths)
  if not (_live and _live.surf:is_valid()) then return end
  _live.order = paths
  for _, path in ipairs(paths) do
    _live.rows[path] = _placeholder_record(path)
  end
  _live_redraw()
end

---Fills in one repository's row once its status read settles -- called once
---per repository, in whatever order the reads happen to finish.
---@param path string
---@param record RepoDashboardRecord|nil
---@param _err string|nil Unused: the per-repository failure is also collected into `M.scan`'s own `errors` list, which `features.dashboard.init` already reports.
---@return nil
function M.live_record(path, record, _err)
  if not (_live and _live.surf:is_valid()) then return end
  if record then
    _live.rows[path] = record
  else
    local r = _placeholder_record(path)
    r.state, r.unscanned = "error", false
    _live.rows[path] = r
  end
  _live_redraw()
end

---Tears the live popup down without handing it to `show_popup` -- the scan
---came back with nothing to show at all (an inaccessible directory, an empty
---one), so `features.dashboard.init` reports that by notification instead,
---exactly as it did before the live popup existed.
---@return nil
function M.live_abort()
  if _live then _live.surf:close() end
  _live = nil
end

---@private
---@internal
---Opens the dashboard in a scrollable floating window (default output).
---Reuses `M.live_begin`'s window in place when a live scan opened one for
---this same `:Git dashboard` invocation, rather than opening a second
---floating window on top of it.
---@param lines string[]
---@param hls DashboardHighlight[]
---@param records RepoDashboardRecord[]
---@return nil
local function show_popup(lines, hls, records)
  if _live and _live.surf:is_valid() then
    local surf = _live.surf
    _live = nil
    local title = M.summary(records)
    _resize_float(surf.winid, lines, title)
    _set_buffer_lines(surf.bufnr, lines, hls)
    surf:set_title(title)
    _attach_row_keymaps(surf.bufnr, records, function()
      surf:close()
    end)
    return
  end
  _live = nil

  local title = M.summary(records)
  local surf = kit.surface.open({
    lines = lines,
    title = title,
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
  -- `make_scratch` sizes by the lines alone; a title wider than them (a long
  -- page name, a running batch's "fetch 1/6") would open cut off.
  _resize_float(surf.winid, lines, title)
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

---Marks the start of a scan: hand the value to `M.show` as `reread_since`, and
---every row re-read after this point (a batch's or a row action's, landing
---while the scan runs) replaces what the scan read of that repository.
---@return integer mark
function M.reread_mark()
  return _reread_seq
end

---Renders `records` and displays them via the requested output backend.
---@param records RepoDashboardRecord[]
---@param opts? { output?: GitSuiteDashboardOutputMode, path?: string, dir?: string, pages?: table[], page_index?: integer, on_switch_page?: fun(page: table, on_done: fun(records: RepoDashboardRecord[], errors: string[])), reread_since?: integer }
---@return nil
function M.show(records, opts)
  opts = opts or {}
  local mode = opts.output or "popup"

  -- Only reset the sort cycle for a genuinely new scan, so `reopen()` (which
  -- replays the cached records) doesn't silently undo the user's chosen order.
  if records ~= (_last_view or {}).records then
    -- A row re-read after the scan began is at least as new as what the scan
    -- read of it -- and newer when the scan got there before a still running
    -- batch's action on it landed.
    if opts.reread_since then
      for i, r in ipairs(records) do
        local hit = _rereads[r.path]
        if hit and hit.seq > opts.reread_since then records[i] = hit.record end
      end
    end
    _discovery_order = _discovery_ranks(records)
    _sort_index = 1
  end
  _last_view = { records = records, opts = opts, line = (_last_view or {}).line or 2 }
  local lines, hls = M.render(records)

  -- Only the interactive backends open/focus a dashboard window at all --
  -- "clipboard"/"path" (and an unrecognized mode) never do, so restoring a
  -- cursor position afterwards would move it in whatever window/buffer the
  -- user already had focused (their own file), not the dashboard.
  local interactive = mode == "popup" or mode == "buffer" or mode == "split" or mode == "vsplit"

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

  if interactive then
    -- Restore the row the user was on before the dashboard was last torn down.
    local win = vim.api.nvim_get_current_win()
    local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(_last_view.line, count), 0 })
  end
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
