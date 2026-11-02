#!/usr/bin/env bash
# Check that no code spells out an S3 key, prefix or bucket: every key comes
# from the layout resolver (R/layout.R, config/layout.yml). Flags, in R, shell
# and Terraform files tracked by git:
#   - a quoted string starting with a top-level folder of the layout ("plots/",
#     "normals/...") or naming a top-level file ("manifest.parquet");
#   - a top-level folder as a file.path() element (file.path("cache", ...));
#   - a top-level folder after a variable or in an s3:// URI ($DATA/plots/,
#     "s3://${B}/latest/");
#   - a literal bucket: s3://name, or the layout's bucket (or its -test copy)
#     quoted on a line about a bucket.
# The folders, files and bucket are read from config/layout.yml, so the same
# script serves mco-snodas and mco-snotel (kept byte-identical; see
# scripts/check-layout-identical.sh). Comments are skipped. A line that must
# keep a path (published text, a Terraform import id) ends with "layout-ok".
#
# Usage: scripts/check-no-paths.sh        exits 1 and lists the lines found
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
layout() { env -u LAYOUT_BUCKET -u S3_BUCKET -u LAYOUT_PREFIX Rscript R/layout_cli.R "$@"; }

# Top-level folders and files: each template's first path element, before any
# variable ("{dir}README.md" has none).
read -r -a TOP <<< "$(layout artifacts | awk -F'\t' 'NR > 1 { t = $2; sub(/\{.*/, "", t); if (t != "") print t }' |
  awk '{ n = index($0, "/"); print (n ? substr($0, 1, n - 1) "/" : $0) }' | sort -u | tr '\n' ' ')"
BUCKET="$(layout bucket)"
dirs=(); files=()
for t in "${TOP[@]}"; do
  if [[ "$t" == */ ]]; then dirs+=("${t%/}"); else files+=("$t"); fi
done
esc() { printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'; }
alt() { local o="" x; for x in "$@"; do o+="${o:+|}$(esc "$x")"; done; printf '%s' "$o"; }
D="$(alt "${dirs[@]}")"
F="$(alt "${files[@]:-}")"
B="$(esc "$BUCKET")"

PATTERNS=(
  "[\"'](${D})/"
  "file\\.path\\(.*[\"'](${D})[\"']"
  "(\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?|s3://[^\"' ]*)/(${D})(/|[\"'])"
  "s3://[A-Za-z0-9]"
  "[Bb][Uu][Cc][Kk][Ee][Tt].*[\"']${B}(-test)?[\"']|[\"']${B}(-test)?[\"'].*[Bb][Uu][Cc][Kk][Ee][Tt]"
  "[Bb][Uu][Cc][Kk][Ee][Tt][A-Za-z_]*:[[:space:]]*${B}"
)
[[ -n "$F" ]] && PATTERNS+=("[\"'](${F})[\"']")

# The resolver and the scripts that test it hold paths by design.
EXCLUDE='^(R/layout\.R|R/layout_cli\.R|scripts/test_layout\.R|scripts/check-[a-z-]*\.sh|scripts/layout/)'
FILES=()
while IFS= read -r f; do FILES+=("$f"); done < <(
  git ls-files -- '*.R' '*.sh' '*.tf' '*.py' 'docker-compose.yml' 'Dockerfile' | grep -Ev "$EXCLUDE")

found=0
for f in "${FILES[@]}"; do
  # Drop comment lines and trailing comments without quotes; keep line numbers.
  hits="$(awk '{ line = $0
                 if (line ~ /^[[:space:]]*(#|\/\/)/) next
                 if (line ~ /layout-ok[[:space:]]*$/) next
                 sub(/[[:space:]]#[^"'\'']*$/, "", line)
                 print NR ":" line }' "$f" |
          grep -E "$(IFS='|'; echo "${PATTERNS[*]}")" || true)"
  if [[ -n "$hits" ]]; then
    found=1
    printf '%s\n' "$hits" | sed "s#^#${f}:#"
  fi
done

if ((found)); then
  echo "Build these keys with the layout resolver (layout_key(), layout_prefix(), R/layout_cli.R)," >&2
  echo "or end the line with 'layout-ok' if the path is not a key the code uses." >&2
  exit 1
fi
echo "ok: no hard-coded S3 paths (bucket ${BUCKET}; top level: ${TOP[*]})"
