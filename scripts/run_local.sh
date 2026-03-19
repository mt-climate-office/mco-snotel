#!/usr/bin/env bash
# run_local.sh — Run the SNOTEL pipeline locally, auto-refreshing AWS SSO
# credentials whenever they expire. State is saved after each run, so
# each restart picks up where the last one left off.
set -euo pipefail

while true; do
  echo "=== Refreshing AWS SSO credentials ==="
  aws sso login --profile mco

  # Export short-lived STS credentials as env vars. paws.storage picks these
  # up via the standard env-var credential provider and never touches the SSO
  # cache, so it won't hit SSO token expiry errors mid-run.
  eval "$(aws configure export-credentials --profile mco --format env)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  echo "=== Starting pipeline ==="
  if docker compose up --exit-code-from mco-snotel; then
    echo "=== Pipeline completed successfully ==="
    break
  fi

  echo "=== Pipeline exited; refreshing credentials and retrying... ==="
done
