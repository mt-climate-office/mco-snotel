#!/usr/bin/env bash
# Upload s3-docs/**/README.md to the same paths in the bucket, as text/markdown
# (the layout's readme artifact, {dir}README.md). s3-docs/ mirrors the bucket:
# each README.md documents its folder.
#
# The bucket, root prefix and folders come from the layout resolver
# (R/layout_cli.R; needs R and the yaml package), reading LAYOUT_CONFIG,
# default config/layout-v1.yml. LAYOUT_BUCKET and LAYOUT_PREFIX apply as in
# R/layout.R, e.g. LAYOUT_BUCKET=<bucket>-test for a test bucket.
#
# Before uploading, every README's folder is checked against the layout: it
# must be the start of some artifact's key, so a README left for a retired
# path stops the upload. Uploads add or replace; nothing is deleted.
#
# Kept byte-identical in mco-snotel and mco-snodas.
#
# Usage: scripts/publish-bucket-readmes.sh [--dryrun]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAYOUT_CONFIG="${LAYOUT_CONFIG:-${REPO_ROOT}/config/layout-v1.yml}"
layout() { Rscript "${REPO_ROOT}/R/layout_cli.R" "$@"; }

DEST="s3://$(layout bucket)/$(layout prefix)"
README="$(basename "$(layout key readme dir=)")"
TEMPLATES="$(layout artifacts | awk -F'\t' 'NR > 1 { print $2 }')"

cd "${REPO_ROOT}/s3-docs"
bad=0
while IFS= read -r f; do
  dir="${f#./}"; dir="${dir%"${README}"}"
  [[ -z "${dir}" ]] && continue
  if ! grep -qxF -- "${dir}" <<< "$(printf '%s\n' "${TEMPLATES}" | cut -c1-"${#dir}")"; then
    echo "s3-docs/${dir}${README}: ${dir} is not a folder of $(basename "${LAYOUT_CONFIG}")" >&2
    bad=1
  fi
done < <(find . -name "${README}" | sort)
((bad)) && exit 1

aws s3 cp . "${DEST}" --recursive --exclude "*" --include "*${README}" \
  --content-type "text/markdown; charset=utf-8" --profile mco "$@"
