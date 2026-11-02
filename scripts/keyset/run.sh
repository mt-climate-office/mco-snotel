#!/usr/bin/env bash
# Run scripts/keyset/harness.R in the pipeline image, on a checkout.
#
# Usage: scripts/keyset/run.sh <image> <code> <seed> <run> <entry script> [VAR=value ...]
#   e.g. scripts/keyset/run.sh mco-snotel:test ../main seed runs/main-daily mco-snotel.R \
#          SNOTEL_DATE=2026-10-31 CALC_FIGURES=true CORES=4
# The checkout and seed are mounted read-only; the run directory is written.
# WORK_DIR stays inside the container (fs::dir_create() cannot set modes on a
# Docker Desktop bind mount).
# The harness runs from this checkout, so both sides use the same stubs.
set -euo pipefail
IMAGE="$1"; CODE="$(cd "$2" && pwd)"; SEED="$(cd "$3" && pwd)"; RUN="$4"; ENTRY="$5"; shift 5
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$RUN"; RUN="$(cd "$RUN" && pwd)"
envs=(); for kv in "$@"; do envs+=(-e "$kv"); done
docker run --rm --platform linux/amd64 --network none \
  -v "$CODE":/code:ro -v "$SEED":/seed:ro -v "$RUN":/out -v "$HERE":/harness:ro \
  -e HARNESS_WORK=/tmp/work ${envs[@]+"${envs[@]}"} --entrypoint Rscript "$IMAGE" /harness/harness.R /code /seed /out "$ENTRY"
