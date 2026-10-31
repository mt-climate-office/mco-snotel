#!/usr/bin/env bash
# Backfill station plots for a date range: one Fargate task (viz.R) per batch
# of dates, at most MAX_RUNNING at once. Dates whose plots/{date}/index.json
# already lists every period in VIZ_PERIODS are skipped (FORCE=true redoes
# them), so a rerun fills only the gaps.
#
# The dates' water years need their normals and percentiles in S3.
#
# Usage: [VIZ_PERIODS=snodas] scripts/backfill-figures.sh START END [DATES_PER_TASK] [MAX_RUNNING]
#   e.g. scripts/backfill-figures.sh 2026-10-01 2026-10-30 5 4
#        VIZ_PERIODS=30yr,por scripts/backfill-figures.sh 2026-10-01 2026-10-30
set -euo pipefail

PROFILE="mco"
BUCKET="mco-snotel"
CLUSTER="mco-snotel"
TASK_DEF="mco-snotel"
CONTAINER="snotel-pipeline"
SUBNETS="subnet-0b687da7eda8bef8f,subnet-09a22817da9991c3c"
SG="sg-0939029739ce88636"
STARTED_BY="viz-backfill"

START="$1"; END="$2"; PER_TASK="${3:-5}"; MAX_RUNNING="${4:-4}"
FORCE="${FORCE:-false}"
VIZ_PERIODS="${VIZ_PERIODS:-snodas}"

# viz.R uploads index.json last, so a period listed in it is done.
done_for() {
  local index
  index="$(aws s3 cp "s3://$BUCKET/plots/$1/index.json" - --profile "$PROFILE" 2>/dev/null)" || return 1
  python3 -c "
import json, sys
done = set(json.loads(sys.argv[1]).get('periods', []))
sys.exit(0 if set(sys.argv[2].split(',')) <= done else 1)" "$index" "$VIZ_PERIODS"
}

ALL=()
while read -r d; do ALL+=("$d"); done < <(python3 -c "
import datetime as dt
d, e = dt.date.fromisoformat('$START'), dt.date.fromisoformat('$END')
while d <= e: print(d); d += dt.timedelta(days=1)")
PENDING=()
for d in "${ALL[@]}"; do
  if [[ "$FORCE" != "true" ]] && done_for "$d"; then continue; fi
  PENDING+=("$d")
done
echo "${#ALL[@]} date(s) in range; ${#PENDING[@]} to plot ($VIZ_PERIODS), $PER_TASK per task, up to $MAX_RUNNING running."
[[ ${#PENDING[@]} -eq 0 ]] && exit 0

running() {
  aws ecs list-tasks --cluster "$CLUSTER" --started-by "$STARTED_BY" --desired-status RUNNING \
    --profile "$PROFILE" --query 'length(taskArns)' --output text
}

# RUNNING once the task has started; otherwise why it stopped before starting.
started() {
  local s r
  for _ in $(seq 60); do
    read -r s r < <(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$1" --profile "$PROFILE" \
      --query 'tasks[0].[lastStatus, stoppedReason]' --output text)
    case "$s" in
      RUNNING|DEACTIVATING) echo RUNNING; return ;;
      # Started and already exited: counted as launched; a rerun of this
      # script redoes its dates if they did not finish.
      STOPPED|DEPROVISIONING)
        if [[ "$r" == Essential* ]]; then echo RUNNING; else echo "${r:-stopped}"; fi
        return ;;
    esac
    sleep 10
  done
  echo RUNNING
}

for (( i = 0; i < ${#PENDING[@]}; i += PER_TASK )); do
  batch="$(IFS=,; echo "${PENDING[*]:i:PER_TASK}")"
  # A launch can fail when the shared subnets are out of addresses; wait and
  # retry the same batch rather than skipping it.
  while :; do
    while (( $(running) >= MAX_RUNNING )); do sleep 60; done
    out="$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEF" \
      --launch-type FARGATE \
      --started-by "$STARTED_BY" \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}" \
      --overrides "{\"containerOverrides\":[{\"name\":\"$CONTAINER\",\"command\":[\"viz.R\"],
                    \"environment\":[{\"name\":\"VIZ_DATES\",\"value\":\"$batch\"},
                                     {\"name\":\"VIZ_PERIODS\",\"value\":\"$VIZ_PERIODS\"}]}]}" \
      --profile "$PROFILE" --query '[tasks[0].taskArn, failures[0].reason]' --output text)" || out="None	run-task error"
    arn="${out%%$'\t'*}"
    reason="${out#*$'\t'}"
    if [[ "$arn" != "None" && -n "$arn" ]]; then
      # A task can be accepted and then stop before it starts (e.g.
      # InsufficientFreeAddressesInSubnet), so wait until it is running.
      status="$(started "$arn")"
      if [[ "$status" == "RUNNING" ]]; then
        echo "$(date '+%H:%M:%S') launched ${batch%%,*} … ${batch##*,}: ${arn##*/}"
        break
      fi
      reason="$status"
    fi
    echo "$(date '+%H:%M:%S') launch failed for ${batch%%,*} … ${batch##*,} (${reason}); retrying in 2 min"
    sleep 120
  done
  sleep 5
done

echo "All batches launched; waiting for the last tasks to finish."
while (( $(running) > 0 )); do sleep 60; done
echo "Done. Rerun the same command to fill any dates that failed."
