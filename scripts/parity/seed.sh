#!/usr/bin/env bash
# Seed the test bucket with what a daily run for the given dates reads, by
# server-side copy from production, so a shadow run starts from production's
# state and does not download from NOAA (SNODAS) again.
#
# Usage:
#   scripts/parity/seed.sh [options] DATE [DATE ...]      (DATE = YYYY-MM-DD)
#
# Options:
#   --project snodas|snotel  Default: the repository this script is in.
#   --dry-run                Print the copy list (and its size); copy nothing.
#   --profile NAME           AWS CLI profile (default: mco-shadow-<project>,
#                            see README "Shadow runs"). The dry run only reads
#                            production, so any profile that can read it works.
#   --asof TIME              SNODAS: copy the state files as they were just
#                            before TIME (UTC, e.g. 2026-10-30T16:03:36+00:00).
#                            Default: when the earliest date's tar reached raw/.
#   --noaa                   SNODAS: do not copy the tars of the dates and later
#                            ones, so the shadow run downloads them from NOAA as
#                            production did (for an unattended run without
#                            SNODAS_DATE; see README).
#   --wipe                   Delete every object in the test bucket first
#                            (it is versioned; versions expire after 30 days).
#
# Kept byte-identical in mco-snodas and mco-snotel (check-identical.sh).
# Buckets and keys come from the project's layout resolver (R/layout_cli.R and
# config/layout.yml; for the other project, from its checkout beside this one,
# or LAYOUT_CONFIG). The keys below are those of layout_version 0.
#
# SNODAS, for each date d (stages.R, calc_*_normals.R, wbd.R):
#   cache/dates_state.parquet, cache/normals_state.parquet, manifest.parquet
#       as of --asof, so d (and later dates) are not yet ingested: the run
#       makes d's COGs (Stage 2) from the tar, then its percentiles (Stage 3).
#   raw/SNODAS_{yyyymmdd}.tar for d and every later date in production, so
#       discovery finds nothing new to fetch from NOAA (skipped with --noaa).
#   cogs/{rd}/snodas_swe_{rd}.tif, rd = d minus 1..30 years, from 2003-09-30:
#       the reference years Stage 3 reads (d's own COG is the run's output).
#   normals/gridded/{ecdf,zig,zig_smooth}/{d}/: the frozen normals, without
#       *_swe_ptile.tif and *_swe_standardized.tif (outputs).
#   normals/zonal/wbd/{ecdf,zig,zig_smooth}/{d}/: the frozen zonal normals.
#       Stage 3 rewrites their swe columns in place, so these are inputs and
#       outputs: use diff.R --newer-than to see they were rewritten.
#   normals/zonal/wbd/observed/wy{WY}_swe.parquet       (rows for d replaced)
#   normals/zonal/wbd/by_zone/wy{WY}/*_swe.parquet      (Stage 5)
#   normals/gridded/zig_smooth/wy{WY}/build.json        (Stage 5 axes)
#   cache/plot_axes/wy{WY}_hypsomeswe.parquet           (Stage 5 axes)
#   cache/data/: snodas_mask.tif, snodas_elevation.tif, wbd_huc8.tif(.aux.xml),
#       wbd_names.parquet, wbd_zones.parquet
#   Not copied (outputs): cogs/{d}/, normals/zonal/wbd/raw/{d}/, plots/{d}/,
#   latest/.
#
# SNOTEL, for each date d (the run refetches the water year from AWDB at run
# time, so a past date cannot be replayed exactly; stages.R, archive.R):
#   archive/snotel.parquet                      (water-year rows replaced)
#   normals/reference/wy{WY}.parquet
#   normals/{30yr,snodas,por}/wy{WY}/normals.parquet and provenance.json
#   plots/{d}/index.json, if any                (merged by Stage 4)
#   Not copied (outputs): stations/, cache/state.parquet, normals/*/observed/,
#   plots/{d}/*.png, latest/.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT=""; DRY_RUN=0; PROFILE=""; ASOF=""; NOAA=0; WIPE=0; DATES=()
while (($#)); do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --asof)    ASOF="$2"; shift 2 ;;
    --noaa)    NOAA=1; shift ;;
    --wipe)    WIPE=1; shift ;;
    -h|--help) usage 0 ;;
    -*)        echo "Unknown option: $1" >&2; usage ;;
    *)         DATES+=("$1"); shift ;;
  esac
done
((${#DATES[@]})) || usage
for d in "${DATES[@]}"; do
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "Not a date: $d" >&2; exit 2; }
done
# shellcheck disable=SC2207  # dates have no spaces; bash 3.2 has no mapfile
DATES=($(printf '%s\n' "${DATES[@]}" | sort -u))

if [[ -z "$PROJECT" ]]; then
  if   [[ -f "$REPO_ROOT/mco-snodas.R" ]]; then PROJECT=snodas
  elif [[ -f "$REPO_ROOT/mco-snotel.R" ]]; then PROJECT=snotel
  else echo "Cannot tell the project; pass --project" >&2; exit 2; fi
fi
[[ "$PROJECT" == snodas || "$PROJECT" == snotel ]] || { echo "Unknown project: $PROJECT" >&2; exit 2; }

# The project's layout: this repository's, or the other project's checkout
# beside it. Production keys only: LAYOUT_BUCKET, S3_BUCKET and LAYOUT_PREFIX
# are ignored.
if [[ -f "$REPO_ROOT/mco-${PROJECT}.R" ]]; then LAYOUT_YML="$REPO_ROOT/config/layout.yml"
else LAYOUT_YML="${LAYOUT_CONFIG:-$REPO_ROOT/../mco-${PROJECT}/config/layout.yml}"; fi
[[ -f "$LAYOUT_YML" ]] || { echo "No layout for $PROJECT at $LAYOUT_YML; set LAYOUT_CONFIG" >&2; exit 2; }
L() { env -u LAYOUT_BUCKET -u S3_BUCKET -u LAYOUT_PREFIX LAYOUT_CONFIG="$LAYOUT_YML" \
        Rscript "$REPO_ROOT/R/layout_cli.R" "$@"; }

SRC="$(L bucket)"
DST="${SRC}-test"
PROFILE="${PROFILE:-mco-shadow-${PROJECT}}"
# Never write to anything but a -test bucket.
[[ "$DST" == *-test && "$DST" != "$SRC" ]] || { echo "Refusing to write to $DST" >&2; exit 2; }

aws_() { AWS_PAGER="" aws --profile "$PROFILE" --region us-west-2 "$@"; }

PLAN="$(mktemp)"; MISSING="$(mktemp)"
trap 'rm -f "$PLAN" "$MISSING"' EXIT

# key<TAB>size<TAB>version ("-" = current) for each object under a prefix.
list_prefix() {
  aws_ s3api list-objects-v2 --bucket "$SRC" --prefix "$1" --output json \
    | jq -r '.Contents[]? | [.Key, (.Size|tostring), "-"] | @tsv'
}
# One key, current version; recorded as missing if absent.
add_key() {
  local hit; hit="$(list_prefix "$1" | awk -F'\t' -v k="$1" '$1 == k')"
  if [[ -n "$hit" ]]; then echo "$hit" >> "$PLAN"; else echo "$1" >> "$MISSING"; fi
}
# Optional key: silently skipped if absent.
add_key_opt() { list_prefix "$1" | awk -F'\t' -v k="$1" '$1 == k' >> "$PLAN"; }
# Every key under a prefix, minus the keys given after it.
add_prefix() {
  local p="$1" n; shift
  n="$(list_prefix "$p" | awk -F'\t' -v skip="$*" 'BEGIN { split(skip, s, " "); for (i in s) x[s[i]] = 1 }
                                                   !($1 in x)' | tee -a "$PLAN" | wc -l)"
  ((n > 0)) || echo "$p (empty prefix)" >> "$MISSING"
}
# One key as it was just before $ASOF (the newest version older than it; none
# if that is a delete marker or there is no older version).
add_key_asof() {
  aws_ s3api list-object-versions --bucket "$SRC" --prefix "$1" --output json \
    | jq -r --arg k "$1" --arg t "$ASOF" '
        [ (.Versions[]? | . + {del: false}), (.DeleteMarkers[]? | . + {del: true}) ]
        | map(select(.Key == $k and .LastModified < $t)) | sort_by(.LastModified) | last
        | if . == null or .del then empty else [.Key, (.Size|tostring), .VersionId] | @tsv end' \
    > "$PLAN.one"
  if [[ -s "$PLAN.one" ]]; then cat "$PLAN.one" >> "$PLAN"; else echo "$1 (no version before $ASOF)" >> "$MISSING"; fi
  rm -f "$PLAN.one"
}

water_year() { local y=$((10#${1:0:4})) m=$((10#${1:5:2})); echo $(( m >= 10 ? y + 1 : y )); }
leap() { local y=$1; (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); }
# d minus k years; Feb 29 rolls back to Feb 28 (lubridate %m-%).
minus_years() {
  local y=$((10#${1:0:4} - $2)) md="${1:5:5}"
  [[ "$md" == 02-29 ]] && ! leap "$y" && md=02-28
  printf '%04d-%s\n' "$y" "$md"
}

if [[ "$PROJECT" == snodas ]]; then
  D0="${DATES[0]}"; D0C="${D0//-/}"
  TAR0="$(L key raw_tar date="$D0")"
  if [[ -z "$ASOF" ]]; then
    ASOF="$(aws_ s3api list-objects-v2 --bucket "$SRC" --prefix "$TAR0" --output json \
              | jq -r --arg k "$TAR0" '.Contents[]? | select(.Key == $k) | .LastModified')"
    [[ -n "$ASOF" ]] || { echo "No $TAR0 in $SRC; pass --asof" >&2; exit 1; }
  fi
  echo "State as of: $ASOF (just before ${D0}'s tar reached $(dirname "$TAR0")/)" >&2

  for k in "$(L key cache file=dates_state.parquet)" "$(L key cache file=normals_state.parquet)" \
           "$(L key raw_manifest)"; do
    add_key_asof "$k"
  done

  # The tars of D0 and later: keys like TAR0 with a later date in place of D0's.
  if ((NOAA == 0)); then
    pre="${TAR0%%"$D0C"*}"; suf="${TAR0#*"$D0C"}"
    list_prefix "$pre" | awk -F'\t' -v pre="$pre" -v suf="$suf" -v d0="$D0C" '
      { c = substr($1, length(pre) + 1, 8) }
      index($1, pre) == 1 && substr($1, length(pre) + 9) == suf &&
      c ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/ && c >= d0' >> "$PLAN"
  fi

  for f in snodas_mask.tif snodas_elevation.tif wbd_huc8.tif wbd_huc8.tif.aux.xml wbd_names.parquet; do
    add_key "$(L key cache file="data/$f")"
  done
  add_key "$(L key subjects)"

  WYS=()
  for d in "${DATES[@]}"; do
    rds=()
    for k in $(seq 1 30); do
      rd="$(minus_years "$d" "$k")"
      [[ "$rd" < 2003-09-30 ]] && break
      rds+=("$rd")
    done
    if ((${#rds[@]})); then
      for key in $(L keys raw_cog date="$(IFS=,; echo "${rds[*]}")" var=swe); do add_key "$key"; done
    fi
    for fl in ecdf zig zig_smooth; do
      # The frozen normals, without the date's percentile grids (outputs).
      add_prefix "$(L prefix normals_grid flavor="$fl" date="$d")" \
        $(L keys percentile_grid flavor="$fl" date="$d" stat=ptile,standardized)
      add_prefix "$(L prefix normals_table_day flavor="$fl" date="$d")"
    done
    WYS+=("$(water_year "$d")")
  done
  for wy in $(printf '%s\n' "${WYS[@]}" | sort -u); do
    add_key "$(L key percentiles wy="$wy" type=swe)"
    add_key "$(L key normals_grid_build wy="$wy")"
    add_key_opt "$(L key cache file="plot_axes/wy${wy}_hypsomeswe.parquet")"
    # Every zone's swe file: keys like the template's with any zone.
    pre="$(L prefix normals_by_subject wy="$wy")"
    suf="$(L key normals_by_subject wy="$wy" subject=ZONE type=swe)"; suf="${suf#"${pre}ZONE"}"
    list_prefix "$pre" | awk -F'\t' -v pre="$pre" -v suf="$suf" '
      { z = substr($1, length(pre) + 1, length($1) - length(pre) - length(suf)) }
      index($1, pre) == 1 && length($1) > length(pre) + length(suf) &&
      substr($1, length($1) - length(suf) + 1) == suf && z !~ /\//' >> "$PLAN"
  done
else
  add_key "$(L key raw)"
  WYS=()
  for d in "${DATES[@]}"; do
    WYS+=("$(water_year "$d")")
    add_key_opt "$(L key plot_index date="$d")"
  done
  ROLES=($(L roles))
  for wy in $(printf '%s\n' "${WYS[@]}" | sort -u); do
    add_key "$(L key reference wy="$wy")"
    for r in "${ROLES[@]}"; do
      add_key "$(L key normals_table role="$r" wy="$wy")"
      add_key "$(L key provenance role="$r" wy="$wy")"
    done
  done
fi

sort -u -o "$PLAN" "$PLAN"
n="$(wc -l < "$PLAN" | tr -d ' ')"
bytes="$(awk -F'\t' '{s += $2} END {printf "%.0f", s}' "$PLAN")"
human="$(awk -v b="$bytes" 'BEGIN {split("B KiB MiB GiB TiB", u); i = 1; while (b >= 1024 && i < 5) {b /= 1024; i++}; printf "%.1f %s", b, u[i]}')"

if ((DRY_RUN)); then
  printf '%s\t%s\t%s\n' size version key
  awk -F'\t' '{printf "%s\t%s\t%s\n", $2, $3, $1}' "$PLAN"
fi
echo "${n} object(s), ${human} (${bytes} bytes): s3://${SRC} -> s3://${DST} [${PROJECT}: ${DATES[*]}]" >&2
if [[ -s "$MISSING" ]]; then
  echo "Not in production, so not copied ($(wc -l < "$MISSING" | tr -d ' ')):" >&2
  sed 's/^/  /' "$MISSING" >&2
fi
((DRY_RUN)) && exit 0

if ((WIPE)); then
  echo "Wiping s3://${DST}" >&2
  aws_ s3 rm "s3://${DST}" --recursive --only-show-errors
fi

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
copy_one() {  # key size version
  if [[ "$3" == "-" ]]; then
    aws_ s3 cp "s3://${SRC}/$1" "s3://${DST}/$1" --only-show-errors
  else
    aws_ s3api copy-object --bucket "$DST" --key "$1" \
      --copy-source "${SRC}/$1?versionId=$3" --output text --query VersionId > /dev/null
  fi
}
export -f copy_one aws_
export SRC DST PROFILE
tr '\t' '\n' < "$PLAN" | xargs -n 3 -P 8 bash -c 'copy_one "$@"' _
echo "Seeded ${n} object(s) at ${started}. Compare a run's outputs with" >&2
echo "  scripts/parity/diff.R --newer-than ${started} --ref s3://${SRC}/<prefix> --cand s3://${DST}/<prefix>" >&2
