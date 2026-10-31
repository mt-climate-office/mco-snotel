#!/usr/bin/env bash
# Upload s3-docs/**/README.md to the same paths in the bucket, as text/markdown.
# Usage: scripts/publish-bucket-readmes.sh [--dryrun]
set -euo pipefail

cd "$(dirname "$0")/../s3-docs"
aws s3 cp . "s3://mco-snotel/" --recursive --exclude "*" --include "*README.md" \
  --content-type "text/markdown; charset=utf-8" --profile mco "$@"
