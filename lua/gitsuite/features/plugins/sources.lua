---@module 'gitsuite.features.plugins.sources'
--- Which plugins are installed, and which clone a user-supplied target means.
---
--- Reads, never writes: the source adapters (`adapter/lazy`, `adapter/pack`,
--- `adapter/clones`) only look at data the plugin manager already holds or at
--- directories, and nothing here spawns a process -- completion calls this on
--- every `<Tab>`.
---
--- `plugins.sources = "auto"` is `adapter.resolve_first({ "lazy", "pack",
--- "clones" })` -- the first caller that function ever had. An explicit list
--- is the union of those sources that are available, deduplicated by path.

local adapter = require("gitsuite.adapter")
local config = require("gitsuite.config")
local repos = require("gitsuite.util.repos")
local text = require("gitsuite.features.plugins.text")
local remote = require("lib.nvim.git.remote")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local to_absolute = require("lib.nvim.cross.fs.to_absolute")
local uv = vim.uv or vim.loop

local M = {}

---@type string[]
local AUTO = { "lazy", "pack", "clones" }

---@class GitSuite.Plugins.ListOpts
---@field sources? "auto"|string[]  Overrides `plugins.sources`.
---@field roots? string[]           Overrides `plugins.roots`.
---@field include_local? boolean    `false` drops `dir`-mode plugins (lazy.nvim never updates them; usually your own repos). Default `true`.

---The installed plugins and where the list came from.
---@param opts? GitSuite.Plugins.ListOpts
---@return GitSuite.Plugins.Ref[] refs Sorted by name; empty when no source has anything.
---@return string[] used The sources that supplied them (one for "auto").
---@return string[] errors What a source reported instead of a list (shape of lazy.nvim's data changed, ...).
function M.list(opts)
  opts = opts or {}
  local cfg = config.get().plugins
  local sources = opts.sources or cfg.sources
  local list_opts = { roots = opts.roots or cfg.roots }

  ---@type GitSuite.Plugins.Ref[], string[], string[]
  local refs, used, errors = {}, {}, {}

  if sources == "auto" then
    local remaining = vim.list_slice(AUTO)
    while #remaining > 0 do
      local source, name = adapter.resolve_first(remaining)
      if not source or not name then break end
      ---@diagnostic disable-next-line: undefined-field
      local got, err = source.list(list_opts)
      -- An empty list is not an answer while another source is left: a plugin
      -- manager that is loaded but manages nothing yet (or lazy.nvim before its
      -- first install) must not hide clones the next source would find.
      if got and (#got > 0 or #remaining == 1) then
        refs, used = got, { name }
        break
      end
      if not got then errors[#errors + 1] = ("%s: %s"):format(name, err or "failed") end
      remaining = vim.tbl_filter(function(candidate)
        return candidate ~= name
      end, remaining)
    end
  else
    local seen = {}
    local explicit = sources --[[@as string[] ]]
    for _, name in ipairs(explicit) do
      local source = adapter.resolve(name)
      if source then
        ---@diagnostic disable-next-line: undefined-field
        local got, err = source.list(list_opts)
        if got then
          used[#used + 1] = name
          for _, ref in ipairs(got) do
            local key = repos.normalize_path(ref.dir)
            if not seen[key] then
              seen[key] = true
              refs[#refs + 1] = ref
            end
          end
        else
          errors[#errors + 1] = ("%s: %s"):format(name, err or "failed")
        end
      end
    end
    table.sort(refs, function(a, b)
      return a.name < b.name
    end)
  end

  if opts.include_local == false then
    refs = vim.tbl_filter(function(ref)
      return not ref.is_local
    end, refs)
  end
  return refs, used, errors
end

---Up to three installed plugin names that contain `needle` (case-insensitive),
---for a "did you mean" in an error.
---@param refs GitSuite.Plugins.Ref[]
---@param needle string
---@return string[]
local function suggestions(refs, needle)
  local out = {}
  needle = needle:lower()
  for _, ref in ipairs(refs) do
    if ref.name:lower():find(needle, 1, true) then
      out[#out + 1] = ref.name
      if #out == 3 then break end
    end
  end
  return out
end

---Resolve what the user typed to a clone: an installed plugin's name, the
---`owner/repo` of its remote, or a path to a git repository.
---
---Never reaches for the network: a well-formed `owner/repo` that is not
---installed is refused with a message that says why, instead of being cloned
---or looked up.
---@param raw string
---@param opts? GitSuite.Plugins.ListOpts
---@return GitSuite.Plugins.Target|nil target
---@return string|nil err
function M.resolve(raw, opts)
  if type(raw) ~= "string" or raw == "" then return nil, "no plugin or path given" end
  if raw:find("%z") then return nil, "the target contains a NUL byte" end
  local refs = M.list(opts)

  for _, ref in ipairs(refs) do
    if ref.name == raw then
      return { kind = "plugin", name = ref.name, dir = ref.dir, ref = ref }
    end
  end
  -- Same name in another case: accepted only when it is unambiguous.
  local folded = {}
  for _, ref in ipairs(refs) do
    if ref.name:lower() == raw:lower() then folded[#folded + 1] = ref end
  end
  if #folded == 1 then
    local ref = folded[1]
    return { kind = "plugin", name = ref.name, dir = ref.dir, ref = ref }
  end
  if #folded > 1 then
    local names = vim.tbl_map(function(ref)
      return ref.name
    end, folded)
    return nil,
      ("'%s' matches several plugins that differ only in case: %s -- type the exact name"):format(
        text.one_line(raw),
        text.one_line(table.concat(names, ", "))
      )
  end

  local wanted = raw:lower()
  for _, ref in ipairs(refs) do
    local parsed = ref.url and remote.parse_remote(ref.url)
    if parsed and ("%s/%s"):format(parsed.owner, parsed.repo):lower() == wanted then
      return { kind = "plugin", name = ref.name, dir = ref.dir, ref = ref }
    end
  end

  local abs = to_absolute(expand_path(raw))
  local stat = uv.fs_stat(abs)
  if not stat or stat.type ~= "directory" then
    if raw:match("^[%w_.-]+/[%w_.-]+$") then
      return nil,
        ("'%s' is not an installed plugin (gitsuite only reads local clones and never fetches or clones)"):format(
          raw
        )
    end
    local hint = suggestions(refs, raw)
    return nil,
      ("'%s' is neither an installed plugin nor a directory%s"):format(
        raw,
        #hint > 0 and (" -- did you mean " .. table.concat(hint, ", ") .. "?") or ""
      )
  end

  local marker = repos.git_marker(abs)
  if not marker then return nil, ("'%s' is not a git repository (no .git)"):format(abs) end
  if marker == "file" then
    return nil,
      ("'%s': .git is a file (a worktree or submodule); point at the main checkout instead"):format(
        abs
      )
  end
  return { kind = "path", name = vim.fs.basename(abs), dir = abs }, nil
end

---The installed plugin that contains the current buffer's file, if any.
---@param bufnr? integer
---@return GitSuite.Plugins.Target|nil
function M.of_buffer(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr or 0)
  if file == "" then return nil end
  local refs = M.list()

  ---Whether `path` lies inside `ref.dir`, comparing the spellings `resolve`
  ---gives each (lexical, or both after symlinks are resolved).
  ---@param ref GitSuite.Plugins.Ref
  ---@param path string
  ---@param resolved boolean
  ---@return boolean
  local function inside(ref, path, resolved)
    local dir = ref.dir
    if resolved then dir = uv.fs_realpath(dir) or dir end
    local prefix = repos.normalize_path(dir) .. "/"
    return repos.normalize_path(path):sub(1, #prefix) == prefix
  end

  for _, ref in ipairs(refs) do
    if inside(ref, file, false) then
      return { kind = "plugin", name = ref.name, dir = ref.dir, ref = ref }
    end
  end
  -- A symlinked plugin folder (or a symlinked temp dir, as on macOS): the
  -- buffer's name and the manager's path may spell the same place differently.
  local real = uv.fs_realpath(file)
  if real then
    for _, ref in ipairs(refs) do
      if inside(ref, real, true) then
        return { kind = "plugin", name = ref.name, dir = ref.dir, ref = ref }
      end
    end
  end
  return nil
end

---`<Tab>` candidates for a target: installed plugin names that start with the
---typed text, then directories.
---@param lead string
---@return string[]
function M.complete(lead)
  local out, seen = {}, {}
  ---@param candidate string
  local function add(candidate)
    if not seen[candidate] then
      seen[candidate] = true
      out[#out + 1] = candidate
    end
  end

  local needle = lead:lower()
  local ok, refs = pcall(M.list)
  for _, ref in ipairs(ok and refs or {}) do
    if needle == "" or ref.name:lower():sub(1, #needle) == needle then add(ref.name) end
  end
  local env_ok, env = pcall(function()
    return require("lib.nvim.system.env").get()
  end)
  if
    env_ok
    and env.repo_base
    and env.repo_base ~= ""
    and ("$REPOS_DIR"):lower():sub(1, #needle) == needle
  then
    add("$REPOS_DIR")
  end
  -- `getcompletion` expands wildcards and backticks (a shell command!) in what
  -- it is given; a half-typed word never needs either, so such a lead gets no
  -- directory completion rather than a surprise.
  if lead:find("[/\\~$.]") and not lead:find("[`*%z]") then
    local dir_ok, dirs = pcall(vim.fn.getcompletion, lead, "dir")
    for _, dir in ipairs(dir_ok and dirs or {}) do
      add(dir)
    end
  end
  return out
end

return M
