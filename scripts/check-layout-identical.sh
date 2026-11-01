#!/usr/bin/env bash
# Check that the layout resolver is byte-identical to the other repository's
# copy (mco-snodas <-> mco-snotel) at a given ref. Only config/layout.yml
# differs between the two.
#
# Usage: scripts/check-layout-identical.sh [path/to/other-repo] [ref]
#   default repo: ../mco-snotel from mco-snodas, ../mco-snodas from mco-snotel
#   default ref:  HEAD
#
# Exits non-zero if a file differs or is in only one copy.
set -euo pipefail

FILES=(
  R/layout.R
  R/layout_cli.R
  scripts/test_layout.R
  scripts/check-layout-identical.sh
  scripts/layout/v1-snotel.yml
  scripts/layout/v1-snodas.yml
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
if   [[ -f mco-snodas.R ]]; then OTHER_NAME=mco-snotel
elif [[ -f mco-snotel.R ]]; then OTHER_NAME=mco-snodas
else echo "Run from mco-snodas or mco-snotel" >&2; exit 2; fi
OTHER="${1:-../${OTHER_NAME}}"
REF="${2:-HEAD}"

echo "layout resolver vs ${OTHER_NAME}@${REF} (${OTHER})"
fail=0
for f in "${FILES[@]}"; do
  here=0; there=0
  [[ -f "${f}" ]] && here=1
  git -C "${OTHER}" cat-file -e "${REF}:${f}" 2>/dev/null && there=1
  if   ((here && !there)); then echo "  ONLY HERE  ${f}"; fail=1
  elif ((!here && there)); then echo "  ONLY THERE ${f}"; fail=1
  elif ((!here && !there)); then echo "  MISSING    ${f}"; fail=1
  elif cmp -s <(git -C "${OTHER}" show "${REF}:${f}") "${f}"; then echo "  ok         ${f}"
  else echo "  DIFFERS    ${f}"; fail=1
  fi
done
exit "${fail}"
