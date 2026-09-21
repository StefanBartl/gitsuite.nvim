#!/usr/bin/env bash
#
# Runs the busted/plenary spec suite headlessly. Wraps
# scripts/minimal_init.lua -- see that file for what it does and why.
#
#   scripts/test.sh                    every spec under TESTS/
#   scripts/test.sh path/to_spec.lua   a single spec file
#
# Env vars (all optional -- see scripts/minimal_init.lua's own fallbacks):
#   LIB_NVIM_DIR      path to a lib.nvim checkout
#   DIFF_NVIM_DIR     path to a diff.nvim checkout
#   PLENARY_DIR       path to a plenary.nvim checkout

set -euo pipefail

cd "$(dirname "$0")/.."

command -v nvim >/dev/null 2>&1 || {
  printf '\033[31m%s\033[0m\n' "nvim is not on PATH." >&2
  exit 1
}

target="${1:-TESTS/}"

if [[ "$target" == *.lua ]]; then
  # NOT ":PlenaryBustedFile $target": that command spawns its own fresh
  # headless nvim subprocess and has no way to hand it minimal_init (its
  # underlying harness.test_file() takes no opts at all) -- the child would
  # boot with none of lib.nvim/diff.nvim/plenary on 'runtimepath' and fall
  # through to silently picking up whatever a real user config happens to
  # provide instead. require("plenary.busted").run(file) runs the spec
  # in-process, in the nvim this script already configured via -u below.
  cmd="lua require('plenary.busted').run('$target')"
else
  cmd="PlenaryBustedDirectory $target { minimal_init = 'scripts/minimal_init.lua', sequential = true }"
fi

exec nvim --clean --headless -u scripts/minimal_init.lua -c "$cmd"
