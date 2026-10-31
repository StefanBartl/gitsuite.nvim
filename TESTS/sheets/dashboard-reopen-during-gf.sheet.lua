-- Live check: close `:Git dashboard` while `gf` (fetch the whole page) is still running and open
-- it again (task gitsuite.nvim/dashboard-wiederoeffnen-live-test, which went into
-- gitsuite.nvim/live-test-checklist; the fix is gitsuite.nvim@0f81590 and @73a6399).
-- Automated: six local clones whose `origin` is a local bare repository (file://, no network), one
-- commit ahead of each clone. The real `git fetch` runs, but every remote's upload-pack is wrapped
-- in a small sh script (`remote.origin.uploadpack`) that waits for a gate file of its own: the
-- sheet decides when each fetch may finish, so "close before the batch is through" is not a race.
-- The sh script needs `sh` on PATH for git (Git for Windows brings its own). Sabotage: without the
-- redraw of the reopened dashboard (`_redraw` in view.lua, gitsuite.nvim@0f81590) it is red.
-- Steps: `:Git dashboard`, `gf` and yes (4 fetching, 2 queued), q, `:Git dashboard` again (the rows still
-- show the batch), a second `gf` is refused at once, without a question ("A bulk fetch is already running";
-- gitsuite.nvim/git-dashboard-gf-waehrend-eines-laufenden-batches-fragt-erst), one gate opens
-- (that row settles with its new commit, a queued one starts), all gates open (every row settles,
-- none stays on "fetch..."). A snapshot per state. The look of it, real remotes over the network
-- (slow, failing) and the feel stay with a person.
return {
  id = "gitsuite.dashboard-reopen-during-gf",
  title = "gitsuite.nvim: close and reopen :Git dashboard while gf runs (local remotes)",
  task = "gitsuite.nvim/live-test-checklist",
  engine = "rpc",
  sizes = { { rows = 30, cols = 120 } },
  steps = {
    {
      lua = [[vim.opt.shortmess:append("I"); vim.o.ruler = false; vim.o.showcmd = false
      -- the fetch notifications pile up into a hit-enter prompt that would stop the child.
      -- 'messagesopt' exists from Neovim 0.11 on; the plugin promises 0.10+, so older ones keep
      -- the notifications in a list instead of on the screen (_G.said reads both)
      _G.sheet_said = {}
      if vim.fn.exists("+messagesopt") == 1 then
        vim.o.messagesopt = "wait:0,history:500"
      else
        vim.notify = function(msg) table.insert(_G.sheet_said, tostring(msg)) end
      end]],
      note = "no intro, no ruler; no hit-enter prompt",
    },
    {
      lua = [=[local root = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(root .. "/repos", "p")
      vim.fn.mkdir(root .. "/remotes", "p")
      vim.fn.mkdir(root .. "/work", "p")
      vim.fn.mkdir(root .. "/gates", "p")
      _G.sheet_root = root
      _G.NAMES = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot" }
      -- dates 400 days back from now, so the LAST COMMIT column always reads "1y" (masked in the
      -- snapshots); a fixed date would turn into "10y" one day and widen the column
      local date = os.date("!%Y-%m-%dT12:00:00Z", os.time() - 400 * 86400)
      local env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date }
      local function git(dir, args)
        local argv = { "git", "-c", "user.name=sheet", "-c", "user.email=sheet@example.invalid",
          "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", "-c", "init.defaultBranch=main" }
        if dir then vim.list_extend(argv, { "-C", dir }) end
        vim.list_extend(argv, args)
        local res = vim.system(argv, { text = true, env = env }):wait()
        assert(res.code == 0, "git " .. table.concat(args, " ") .. ": " .. (res.stderr or ""))
      end
      local function write(path, text)
        local f = assert(io.open(path, "wb"))
        f:write(text)
        f:close()
      end
      local function url(path)
        return "file://" .. (path:sub(1, 1) == "/" and "" or "/") .. path
      end
      -- one repository per step: six git processes each, and a step's RPC call has 10 s
      _G.make = function(name)
        local remote, work, clone = root .. "/remotes/" .. name .. ".git", root .. "/work/" .. name, root .. "/repos/" .. name
        git(nil, { "init", "-q", "-b", "main", work })
        git(work, { "commit", "-q", "--allow-empty", "-m", "first" })
        git(nil, { "clone", "-q", "--bare", work, remote })
        git(nil, { "clone", "-q", url(remote), clone })
        -- the remote moves on: after the fetch every clone is one behind
        git(work, { "commit", "-q", "--allow-empty", "-m", "second" })
        git(work, { "push", "-q", url(remote), "main" })
        -- every later upload-pack of this remote waits for its gate file (at most a minute, so a
        -- failed sheet leaves no process behind for long)
        local gate, script = root .. "/gates/" .. name, root .. "/gates/" .. name .. ".sh"
        write(script, ("i=0\nwhile [ ! -f '%s' ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done\n"
          .. 'exec git upload-pack "$@"\n'):format(gate))
        local cfg = assert(io.open(clone .. "/.git/config", "ab"))
        cfg:write(("[remote \"origin\"]\n\tuploadpack = sh '%s'\n"):format(script))
        cfg:close()
      end
      _G.release = function(name)
        write(root .. "/gates/" .. name, "")
      end
      -- progress in memory only: the default ("auto" without fidget) adds one vim.notify per
      -- repository to the flood above (the user-facing side of that is a `manual` entry below)
      require("gitsuite").setup({ progress_style = "statusline", dashboard = { fetch_jobs = 4 } })
      _G.dashboard = function()
        vim.cmd("Git dashboard " .. vim.fn.fnameescape(root .. "/repos"))
      end
      -- the dashboard float of the current tab, if one is open
      _G.dwin = function()
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local b = vim.api.nvim_win_get_buf(w)
          if vim.bo[b].filetype == "gitsuite-dashboard" and vim.api.nvim_win_get_config(w).relative ~= "" then
            return w
          end
        end
      end
      _G.row = function(name)
        local w = _G.dwin()
        if not w then return "" end
        for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)) do
          if l:find(" " .. name .. " ", 1, true) then return l end
        end
        return ""
      end
      -- how many rows show `text` in their STATE column
      _G.count = function(text)
        local n = 0
        for _, name in ipairs(_G.NAMES) do
          if _G.row(name):find(text, 1, true) then n = n + 1 end
        end
        return n
      end
      _G.title = function()
        local w = _G.dwin()
        if not w then return "" end
        local t = vim.api.nvim_win_get_config(w).title or ""
        if type(t) == "table" then
          local parts = {}
          for _, chunk in ipairs(t) do parts[#parts + 1] = chunk[1] end
          t = table.concat(parts)
        end
        return t
      end
      -- the confirm dialog of a whole-page action, if one is open
      _G.asking = function(text)
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if w ~= _G.dwin() and vim.api.nvim_win_get_config(w).relative ~= "" then
            local lines = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), " ")
            if lines:find(text, 1, true) then return true end
          end
        end
        return false
      end
      _G.said = function(text)
        return vim.fn.execute("messages"):find(text, 1, true) ~= nil
          or table.concat(_G.sheet_said, " | "):find(text, 1, true) ~= nil
      end
      _G.verb = function()
        return require("gitsuite.features.dashboard.repo_state").bulk_verb()
      end]=],
      note = "the helpers; gitsuite set up",
    },
    {
      lua = '_G.make("alpha")',
      note = "alpha: a clone one commit behind its local bare remote, the fetch gated",
    },
    { lua = '_G.make("bravo")' },
    { lua = '_G.make("charlie")' },
    { lua = '_G.make("delta")' },
    { lua = '_G.make("echo")' },
    { lua = '_G.make("foxtrot")' },
    { lua = "_G.dashboard()", note = ":Git dashboard on the six clones" },
    {
      wait = [[_G.dwin() ~= nil and _G.count("clean") == 6 and _G.title():find("6 repos", 1, true) ~= nil]],
      timeout = 20000,
      note = "the dashboard is up: six clean rows, nothing behind yet",
    },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "opened", masks = { "%d+y " } },

    { keys = "gf", note = "gf: fetch the whole page" },
    { wait = [[_G.asking("Fetch 6 repositories in this dashboard?")]], note = "it asks first" },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "confirm", masks = { "%d+y " } },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      timeout = 10000,
      note = "four fetches run (dashboard.fetch_jobs), two are queued",
    },
    {
      expect = [[_G.title():find("fetch 0/6", 1, true) ~= nil]],
      note = "the title counts the batch",
    },
    {
      expect = [[_G.row("alpha"):find("fetch...", 1, true) and _G.row("echo"):find("queued", 1, true)
        and _G.row("foxtrot"):find("queued", 1, true)]],
      note = "in row order: alpha to delta run, echo and foxtrot wait",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "running", masks = { "%d+y " } },

    { keys = "q", note = "close the dashboard before any fetch is through" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
    { expect = [[_G.verb() == "fetch"]], note = "the batch keeps running" },

    { lua = "_G.dashboard()", note = ":Git dashboard again (a fresh scan, a fresh window)" },
    {
      wait = [[_G.dwin() ~= nil and _G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      timeout = 20000,
      note = "the reopened dashboard shows the running batch: four fetching, two queued",
    },
    {
      wait = [[_G.title():find("fetch 0/6", 1, true) ~= nil]],
      timeout = 20000,
      note = "once its scan is through, its title counts the batch too",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "reopened", masks = { "%d+y " } },

    { keys = "gf", note = "a second gf in the reopened dashboard" },
    {
      wait = [[_G.said("A bulk fetch is already running")]],
      note = "it is refused at once: a bulk fetch is already running",
    },
    { expect = [[not _G.asking("Fetch 6 repositories")]], note = "without asking first" },
    {
      expect = [[_G.count("⟳ fetch...") == 4 and _G.count("· fetch queued") == 2]],
      note = "no second batch: the rows are as before",
    },

    { lua = '_G.release("alpha")', note = "alpha's fetch may finish" },
    {
      wait = [[_G.row("alpha"):find("↓1", 1, true) and not _G.row("alpha"):find("fetch", 1, true)
        and _G.row("echo"):find("fetch...", 1, true) and _G.count("· fetch queued") == 1]],
      timeout = 20000,
      note = "alpha settles with the new commit (↓1); echo leaves the queue and fetches",
    },
    {
      expect = [[_G.title():find("fetch 1/6", 1, true) ~= nil]],
      note = "the title counts on",
    },
    { lua = 'vim.cmd("echo")' },
    { screen = "progress", masks = { "%d+y " } },

    {
      lua = "for _, name in ipairs(_G.NAMES) do _G.release(name) end",
      note = "every other fetch may finish",
    },
    {
      wait = [[_G.verb() == nil and _G.count("fetch") == 0 and _G.count("↓1") == 6]],
      timeout = 30000,
      note = "the batch is through: every row settles with its new commit, none stays on fetch...",
    },
    {
      expect = [[_G.title():find("fetch", 1, true) == nil and _G.title():find("6 out of sync", 1, true) ~= nil]],
      note = "the title no longer counts a batch; all six are behind",
    },
    {
      expect = [[_G.said("fetch: 6 repositories done, 6 changed, 0 unchanged")]],
      note = "the closing message: every fetch brought a new commit",
    },
    { settle = 300 },
    { lua = 'vim.cmd("echo")' },
    { screen = "settled", masks = { "%d+y " } },

    { keys = "gf", note = "gf again, now that the batch is through" },
    { wait = [[_G.asking("Fetch 6 repositories in this dashboard?")]], note = "it asks" },
    { keys = "y", note = "yes" },
    {
      wait = [[_G.said("fetch: 6 repositories done, 0 changed, 6 unchanged") and _G.verb() == nil
        and _G.count("fetch") == 0]],
      timeout = 30000,
      note = "a new batch runs (the gates are open) and finds nothing new",
    },
    { keys = "q", note = "close the dashboard" },
    { wait = [[_G.dwin() == nil]], note = "the dashboard is gone" },
  },
  judge = {
    "The rows of the running batch read clearly in the reopened dashboard (· fetch queued / ⟳ fetch...) and match the first one",
    "The title's counter (fetch 1/6) is noticeable enough to tell the batch is still running",
    "running/progress/settled: the float keeps the width it was opened with while the STATE and SYNC cells widen -- LAST COMMIT is cut at the border and the title starts with '<' (bug or acceptable?)",
  },
  manual = {
    "With your real repositories over the network: :Git dashboard, gf, close the popup before all repositories are through, :Git dashboard again; the rows go on and all settle",
    "A second gf in the reopened dashboard says 'A bulk fetch is already running' while the first runs",
    "A remote that fails (offline, no access) shows ✗ fetch failed in the reopened dashboard, the closing message names it",
    "In a Neovim without a notifier plugin or fidget (progress_style 'auto' falls back to vim.notify): :Git dashboard on a directory with many clones opens without a 'Press ENTER' prompt during the scan",
    "Enter findings under 'Befunde' in docs/ROADMAP/Final_Checks/gitsuite-live-checks-2026-10-22.md (nvim config), each as a kind: bug task",
  },
}
