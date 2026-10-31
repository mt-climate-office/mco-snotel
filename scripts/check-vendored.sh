#!/usr/bin/env bash
# Check the code vendored from mco-snodas against a checkout of it, at the
# commit recorded in each file's header (README, "Vendored code").
#
# Usage: scripts/check-vendored.sh [path/to/mco-snodas]   (default: ../mco-snodas)
#
# Exits non-zero if a vendored file differs from its source at that commit,
# apart from the header (and, for scripts/test_distributions.R, the path of
# R/zig_spline_normals.R). After re-vendoring at a new commit, update the
# headers and VENDORED_FROM below.
set -euo pipefail

SNODAS="${1:-../mco-snodas}"
VENDORED_FROM="62fe19a"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

upstream() { git -C "${SNODAS}" show "${VENDORED_FROM}:$1"; }
# Lines of a function, from its definition to the first line that is "}".
fn() { awk -v f="^$1 <- function" '$0 ~ f {p=1} p {print} p && /^}/ {exit}'; }
# Strip the vendoring header: everything through the first blank line.
body() { awk 'p {print} !p && /^$/ {p=1}' "$1"; }

fail=0
check() {  # check <label> <expected> <actual>
  if diff -q <(printf '%s\n' "$2") <(printf '%s\n' "$3") > /dev/null; then
    echo "  ok      $1"
  else
    echo "  DIFFERS $1"; diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20; fail=1
  fi
}

echo "Vendored code vs mco-snodas@${VENDORED_FROM} (${SNODAS})"
for f in ecdf_impl.h ecdf.cpp zig.cpp zig_spline.cpp qnorm_grid.cpp; do
  check "src/$f" "$(upstream "src/$f")" "$(body "src/$f")"
done
check "R/zig_spline_normals.R" "$(upstream R/calc_snodas_zig_spline_normals.R)" "$(body R/zig_spline_normals.R)"

plot_up="$(upstream R/plot.R | awk '/^huc_display_name/ {exit} {print}')"
check "R/plot.R" "${plot_up}" "$(body R/plot.R)"

utils_up="$(upstream R/utils.R | awk '/^# Quantile probabilities/ {p=1} p')"
check "R/utils.R" "${utils_up}" "$(body R/utils.R)"
check "R/s3.R" "$(upstream R/s3.R)" "$(body R/s3.R)"

sync_up="$( (upstream R/pipeline_sync.R | awk '/^#. List all S3 objects/ {p=1} p' | fn s3_list_prefix | sed '1i\
#'"'"' List all S3 objects under a prefix, handling pagination.'; echo
             upstream R/pipeline_sync.R | awk '/^#. Run an `aws s3` command/ {p=1} p' | awk '{print} /^}/ {exit}'; echo
             upstream R/normals_annual.R | fn s3_exists) )"
check "R/s3_sync.R" "${sync_up}" "$(body R/s3_sync.R)"

# The test script keeps its shebang; its header is lines 2-4.
test_up="$(upstream scripts/test_distributions.R | sed 's#source("R/calc_snodas_zig_spline_normals.R")#source("R/zig_spline_normals.R")#')"
check "scripts/test_distributions.R" "${test_up}" "$(sed '2,4d' scripts/test_distributions.R)"

for f in mco_logo.png umt_logo.png plot_palette.png; do
  if cmp -s <(upstream "$f") "$f"; then echo "  ok      $f"; else echo "  DIFFERS $f"; fail=1; fi
done

exit "${fail}"
