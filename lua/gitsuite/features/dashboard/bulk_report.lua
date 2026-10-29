---@module 'gitsuite.features.dashboard.bulk_report'
---@brief The closing notification of a dashboard batch: per repository what happened.
---@description
--- A batch over a page of clones used to end with a bare count ("sync: 12
--- repositories done"), which says nothing about *which* repositories were
--- pulled, pushed or left alone. This module turns the per-repository results
--- the bulk queue collects into one message:
---
---   sync: 1 of 9 failed, 2 changed, 6 unchanged
---
---   Failed:
---     beta: diverged: 1 ahead, 1 behind - neither pulled nor pushed
---   Changed:
---     alpha: pulled 3 commits
---     gamma: pushed 1 commit
---
--- Repositories without anything to report are only counted, never listed: on a
--- page of forty clones the interesting few must not drown in "up to date".
--- No buffers, windows or git: the wording is tested without a dashboard.

---@class GitSuiteDashboardBulkReport
local M = {}

---One repository's result in a batch.
---@class GitSuiteBulkResult
---@field name string Repository name as the dashboard shows it
---@field ok boolean
---@field err string|nil Failure reason (`ok == false`)
---@field detail string|nil What changed (`ok == true`); nil means nothing did
---@field skipped string|nil Why there was nothing to work on (`ok == true`)

---`n` followed by `one` or `many`.
---@param n integer
---@param one string
---@param many string
---@return string
local function count(n, one, many)
  return ("%d %s"):format(n, n == 1 and one or many)
end

---Lines of git's stderr that say what went wrong, as opposed to "To <url>" or "hint: ..." around them.
---@type string[]
local REASON_PATTERNS = { "^!", "^error:", "^fatal:" }

---One line for a failure reason: a single-line `err` as it is; of a multi-line one (git's raw stderr,
---say of a refused push) the first line that names the reason (`! [rejected] ...`, `error:`, `fatal:`),
---else its first non-empty line, so every line of the Failed section belongs to the repository it names.
---@param err string|nil
---@return string
local function reason(err)
  ---@type string[]
  local lines = {}
  for line in (err or ""):gmatch("[^\r\n]+") do
    line = vim.trim(line)
    if line ~= "" then lines[#lines + 1] = line end
  end
  if #lines == 0 then return "unknown error" end
  for _, line in ipairs(lines) do
    for _, pat in ipairs(REASON_PATTERNS) do
      if line:find(pat) then return line end
    end
  end
  return lines[1]
end

---Builds the closing message of a batch.
---@param verb string The batch's verb ("sync", "fetch", ...)
---@param results GitSuiteBulkResult[] One per repository that ran, in row order
---@param total integer Repositories the batch was started for (more than `#results` when cancelled)
---@return string message
---@return boolean failed Whether any repository failed
function M.format(verb, results, total)
  ---@type string[], string[], string[]
  local failed, changed, skipped = {}, {}, {}
  local unchanged = 0
  for _, r in ipairs(results) do
    if not r.ok then
      failed[#failed + 1] = ("  %s: %s"):format(r.name, reason(r.err))
    elseif r.skipped then
      skipped[#skipped + 1] = ("  %s: %s"):format(r.name, r.skipped)
    elseif r.detail then
      changed[#changed + 1] = ("  %s: %s"):format(r.name, r.detail)
    else
      unchanged = unchanged + 1
    end
  end

  ---@type string[]
  local head = {}
  if #failed > 0 then
    head[1] = ("%s: %d of %d failed"):format(verb, #failed, total)
  else
    head[1] = ("%s: %s done"):format(verb, count(#results, "repository", "repositories"))
  end
  head[#head + 1] = ("%d changed"):format(#changed)
  if #skipped > 0 then head[#head + 1] = ("%d skipped"):format(#skipped) end
  head[#head + 1] = ("%d unchanged"):format(unchanged)
  local not_started = total - #results
  if not_started > 0 then head[#head + 1] = ("%d not started (cancelled)"):format(not_started) end

  ---@type string[]
  local lines = { table.concat(head, ", ") }
  for _, section in ipairs({
    { "Failed:", failed },
    { "Changed:", changed },
    { "Skipped:", skipped },
  }) do
    if #section[2] > 0 then
      if #lines == 1 then lines[2] = "" end
      lines[#lines + 1] = section[1]
      vim.list_extend(lines, section[2])
    end
  end
  return table.concat(lines, "\n"), #failed > 0
end

---`n` commits, with the noun agreeing.
---@param n integer
---@return string
function M.commits(n)
  return count(n, "commit", "commits")
end

return M
