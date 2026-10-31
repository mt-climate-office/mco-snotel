#!/usr/bin/env Rscript
# mco-snotel.R — nightly SNOTEL pipeline
#
# Calls the stage functions in R/stages.R. Each stage reads and writes its own
# state in S3, so stages can also be run on their own.
#
#   1. stage_stations()     AWDB station metadata → stations/stations.parquet
#   2. stage_ingest()       refetch this water year from AWDB and replace those
#                           rows of archive/snotel.parquet (NRCS edits recent
#                           values, so the whole water year is refetched)
#   3. stage_percentiles()  this water year's SWE against the frozen normals
#                           (normals are built yearly by normals-annual.R)
#   4. stage_viz()          per-station plots for the newest date with SWE
#   5. stage_publish()      latest/ snapshot and manifest.json
#
# On Oct 1 the new water year has no normals until normals-annual.R runs that
# afternoon, so this run skips Stages 3 and 4.
#
# Environment variables:
#   SNOTEL_DATE          Date to plot and publish (default: the newest date
#                        with SWE this water year)
#   S3_BUCKET            S3 bucket name (default: mco-snotel)
#   WORK_DIR             Local working directory (default: s3)
#   KEEP_LOCAL           Keep files in WORK_DIR as a local cache (default: TRUE;
#                        FALSE in ECS)
#   CORES                Plotting workers (default: 1)
#   AWDB_CONCURRENCY     Parallel AWDB requests (default: 4)
#   CALC_FIGURES         Run Stage 4 (default: FALSE; TRUE in the ECS task)
#   AWS_PROFILE          AWS credentials profile (default: mco)
#   AWS_DEFAULT_REGION   AWS region (default: us-west-2)

suppressPackageStartupMessages({
  library(magrittr)
  library(ggplot2)
  library(patchwork)
  library(lubridate)
})

source("R/pipeline_setup.R")
setup_pipeline()

CALC_FIGURES <- isTRUE(as.logical(Sys.getenv("CALC_FIGURES", unset = "FALSE")))
today <- lubridate::as_date(lubridate::now(tzone = "America/Denver"))

message("=== SNOTEL pipeline: starting ", format(today), " ===")

stations <- stage_stations()
stage_ingest(stations, date = today)

the_date <- Sys.getenv("SNOTEL_DATE", unset = "") %>%
  { if (nzchar(.)) lubridate::as_date(.) else latest_swe_date(today) }
if (is.na(the_date)) the_date <- today
wy <- water_year(the_date)

done <- stage_percentiles(wy)

# A plotting failure still lets the night's tables publish, but the task exits
# non-zero so the failure shows in ECS.
plots_ok <- TRUE
if (CALC_FIGURES && length(done)) {
  plots_ok <- tryCatch({ stage_viz(the_date); TRUE },
                       error = \(e) { message("  Plots failed for ", format(the_date), ": ", conditionMessage(e)); FALSE })
}

stage_publish(the_date)

if (!plots_ok) stop("Plots failed for ", format(the_date), "; tables were published")
message("=== SNOTEL pipeline: done ===")
