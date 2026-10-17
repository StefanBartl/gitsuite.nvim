-- scripts/breaking_eval.lua -- re-measure the breaking-change classifier on its fixture corpus.
--
--   nvim -l scripts/breaking_eval.lua [--corpus=<file>] [--drift]
--
-- Classifies every line of TESTS/fixtures/breaking/corpus.jsonl (or --corpus) again and prints,
-- per tier the classifier gives NOW: commits, hand-labelled breaking ones, precision; then every
-- line whose tier differs from the recorded one (--drift adds the subject). Exit code 1 when a
-- tier moved or a gate fails (sure >= 90 %, probable >= 35 %) -- the verdict of
-- TESTS/gitsuite/plugins_breaking_spec.lua, with the numbers. The tuning loop is in
-- TESTS/fixtures/breaking/README.md.

local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(arg[0], ":p"))))
local corpus, show = root .. "/TESTS/fixtures/breaking/corpus.jsonl", false
for _, a in ipairs(arg) do
  if a == "--drift" then
    show = true
  elseif a:match("^%-%-corpus=") then
    corpus = a:sub(10)
  end
end
vim.opt.rtp:prepend(root)
local B = require("gitsuite.features.plugins.breaking")

local stats, moved, n = {}, {}, 0
for line in io.lines(corpus) do
  if line ~= "" then
    n = n + 1
    local c = vim.json.decode(line)
    local tier = B.classify({ sha = c.sha, subject = c.subject, body = c.body, gone = c.gone }).tier
      or "none"
    local s = stats[tier] or { n = 0, yes = 0 }
    s.n = s.n + 1
    if c.breaking then s.yes = s.yes + 1 end
    stats[tier] = s
    if tier ~= c.tier then
      moved[#moved + 1] = ("  %-28s %s  %s -> %s%s"):format(
        c.repo,
        c.sha:sub(1, 8),
        c.tier,
        tier,
        show and ("  " .. c.subject) or ""
      )
    end
  end
end

print(("corpus: %s (%d commits)"):format(corpus, n))
print(("%-10s %6s %9s %10s"):format("tier", "count", "breaking", "precision"))
local failed = false
for _, tier in ipairs({ "sure", "probable", "hint", "bulk", "none" }) do
  local s = stats[tier] or { n = 0, yes = 0 }
  local p = s.n > 0 and s.yes / s.n or 0
  print(("%-10s %6d %9d %9.1f%%"):format(tier, s.n, s.yes, 100 * p))
  if (tier == "sure" and p < 0.90) or (tier == "probable" and p < 0.35) then failed = true end
end
if #moved > 0 then
  print(("\n%d commit(s) changed tier (recorded -> now):"):format(#moved))
  print(table.concat(moved, "\n"))
end
if failed then print("\ngate failed: sure needs >= 90 %, probable >= 35 %") end
os.exit((failed or #moved > 0) and 1 or 0)
