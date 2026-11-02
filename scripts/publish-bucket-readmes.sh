#!/usr/bin/env bash
# Upload s3-docs/**/README.md to the same paths in the bucket, as text/markdown
# (the layout's readme artifact, {dir}README.md). The bucket and root prefix
# come from the layout resolver (R/layout_cli.R; needs R and the yaml package).
# Usage: scripts/publish-bucket-readmes.sh [--dryrun]
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="s3://$(Rscript R/layout_cli.R bucket)/$(Rscript R/layout_cli.R prefix)"
cd s3-docs
aws s3 cp . "$DEST" --recursive --exclude "*" --include "*README.md" \
  --content-type "text/markdown; charset=utf-8" --profile mco "$@"
