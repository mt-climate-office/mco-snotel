#!/usr/bin/env bash
# Check that scripts/parity/ is byte-identical to the other repository's copy
# (mco-snodas <-> mco-snotel) at a given ref.
#
# Usage: scripts/parity/check-identical.sh [path/to/other-repo] [ref]
#   default repo: ../mco-snotel from mco-snodas, ../mco-snodas from mco-snotel
#   default ref:  HEAD
#
# Exits non-zero if a file differs or is in only one copy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
if   [[ -f mco-snodas.R ]]; then OTHER_NAME=mco-snotel
elif [[ -f mco-snotel.R ]]; then OTHER_NAME=mco-snodas
else echo "Run from mco-snodas or mco-snotel" >&2; exit 2; fi
OTHER="${1:-../${OTHER_NAME}}"
REF="${2:-HEAD}"

ours="$(find scripts/parity -maxdepth 1 -type f | sed "s#^scripts/parity/##" | sort)"
theirs="$(git -C "${OTHER}" ls-tree --name-only "${REF}" scripts/parity/ | sed 's#^scripts/parity/##' | sort)"

echo "scripts/parity vs ${OTHER_NAME}@${REF} (${OTHER})"
fail=0
for f in $(printf '%s\n' "${ours}" "${theirs}" | sort -u); do
  if [[ ! -f "scripts/parity/${f}" ]]; then echo "  ONLY THERE ${f}"; fail=1; continue; fi
  if ! grep -qxF "${f}" <<< "${theirs}"; then echo "  ONLY HERE  ${f}"; fail=1; continue; fi
  if cmp -s <(git -C "${OTHER}" show "${REF}:scripts/parity/${f}") "scripts/parity/${f}"; then
    echo "  ok         ${f}"
  else
    echo "  DIFFERS    ${f}"; fail=1
  fi
done
exit "${fail}"
