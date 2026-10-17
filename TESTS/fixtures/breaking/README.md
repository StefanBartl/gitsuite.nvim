# Breaking-change fixtures

Data for `TESTS/gitsuite/plugins_breaking_spec.lua`. Real commits of public
Neovim plugins, as their clones held them on 2026-10-17; nothing here is made up.

## `corpus.jsonl` — the fixture gate

One commit per line:

| Field | Meaning |
| --- | --- |
| `repo`, `sha` | Where it comes from |
| `subject`, `body` | Raw message text (bodies keep their CRLF where the commit has one; cut at a line break below 1500 bytes) |
| `gone` | Lua files the commit deleted (only when there are any) |
| `tier` | What `breaking.classify` said when the line was recorded: `sure`, `probable`, `hint`, `bulk` or `none` |
| `breaking` | The hand label (one judge) |
| `note` | Why, where the label is not obvious |

The spec fails when a commit's tier changes (**drift 0**: a rule change has to
update the recorded tier on purpose) and when the share of `breaking = true`
falls below 90 % among `sure` or below 35 % among `probable`.

**Label rule:** a commit is breaking when a user of the plugin has to change
something (configuration, a mapping, a call, an installed dependency, the
Neovim version) to keep what worked before, or notices a default behaviour that
flipped. Not breaking: CI, tests, documentation, new features that are opt-in,
cosmetic changes, internal refactors. A parser bump of nvim-treesitter is
labelled not breaking from a user's point of view (it is formally breaking for
query authors), which is why it is a tier of its own.

The selection: from the newest 300 commits of the 50 local clones (10,710
commits; the classifier flags 103 `sure`, 45 `probable`), all `probable` ones,
the `sure` ones minus some repetitions of the same repository, a sample of hints, of unflagged
commits and of reverts, and the edge cases the spec names (`!` inside a subject
or in body prose, `feat(a,b)!:`, a misplaced `!`, CRLF bodies, a revert whose
body says "breaking").

## `nvim-treesitter-f873ec29-e289100f.jsonl` — the reference update

The 86 commits of the nvim-treesitter update that started the feature
(`f873ec29..e289100f`, `git log --topo-order`, newest first): 26 `!` commits =
3 real ones (positions 17, 43, 46 of 86) + 23 parser bumps; the subject "update
parser and queries" occurs 27 times.

## Re-measuring and tuning a rule

`nvim -l scripts/breaking_eval.lua [--drift]` classifies the corpus again and
prints the precision per tier and every line whose tier moved (exit code 1 on a
move or a failed gate). As of 2026-10-17: sure 50 of 55 (91 %), probable 25 of
45 (56 %), hint 4 of 12, parser bumps 0 of 5, unflagged 2 of 28 (blind spots:
behaviour changes without any marker).

1. Change a rule in `lua/gitsuite/features/plugins/breaking.lua`.
2. Run the script with `--drift`; judge every moved line by its label.
3. Keep the change only if the gates hold and the moves are wanted, then update
   the `tier` of the moved lines here (drift 0 means: a tier changes on purpose)
   and run the spec.

To widen the corpus, classify the newest commits of the local clones
(`git log -300 --no-merges --format=%s%x00%b`, raw, so CRLF bodies stay raw),
pick candidates per tier, label them by the rule above and append them; the
spec keeps the corpus between 120 and 150 lines.
