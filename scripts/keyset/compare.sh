#!/usr/bin/env bash
# Compare two harness logs (run/s3.log): the operations in order, and the set
# of keys for each operation. Exits non-zero on any difference.
#
# Usage: scripts/keyset/compare.sh <run A> <run B>
set -euo pipefail
A="$1/s3.log"; B="$2/s3.log"
fail=0
echo "operations: $(wc -l < "$A") vs $(wc -l < "$B")"
if cmp -s "$A" "$B"; then echo "  ordered logs identical"; else echo "  ordered logs DIFFER"; diff "$A" "$B" | head -20; fail=1; fi
for op in $(cut -f1 "$A" "$B" | sort -u); do
  a="$(awk -F'\t' -v op="$op" '$1 == op {print $2 "\t" $3 "\t" $4}' "$A" | sort -u)"
  b="$(awk -F'\t' -v op="$op" '$1 == op {print $2 "\t" $3 "\t" $4}' "$B" | sort -u)"
  na=$(grep -c . <<< "$a" || true); nb=$(grep -c . <<< "$b" || true)
  if [[ "$a" == "$b" ]]; then printf '  %-10s %6d distinct keys, identical\n' "$op" "$na"
  else printf '  %-10s %6d vs %d distinct keys, DIFFER\n' "$op" "$na" "$nb"; diff <(echo "$a") <(echo "$b") | head -10; fail=1; fi
done
exit "$fail"
