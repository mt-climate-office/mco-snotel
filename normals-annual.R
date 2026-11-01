#!/usr/bin/env Rscript
# normals-annual.R — yearly SNOTEL normals build
#
# Runs on Oct 1, after the daily run has ingested Sep 30:
#   1. stage_stations()          refresh station metadata
#   2. archive_refresh_full()    refetch every station's whole record from
#                                AWDB, picking up a year of NRCS edits
#   3. stage_normals()           freeze the record before the new water year and
#                                build its normals for every period and flavor,
#                                with the outlook's persistence
#   4. stage_percentiles()       the new water year's SWE so far
#   5. stage_outlook(), stage_viz(), stage_publish()
#                                the outlook, plots and latest/ for the newest date
#
# Environment variables:
#   WATER_YEAR           Water year to build (default: the one in progress, in
#                        Mountain time). Builds for past years rebuild their
#                        normals but do not plot or publish.
#   SKIP_REFRESH         Build from the archive as it is, without refetching it
#                        (default: FALSE)
#   PERIODS              Comma-separated periods (default: 30yr,snodas,por)
#   CALC_FIGURES         Plot the newest date afterwards (default: FALSE; TRUE
#                        in the ECS task)
#   S3_BUCKET, WORK_DIR, KEEP_LOCAL, CORES, AWDB_CONCURRENCY, AWS_PROFILE,
#   AWS_DEFAULT_REGION   As in mco-snotel.R

suppressPackageStartupMessages({
  library(magrittr)
  library(ggplot2)
  library(patchwork)
  library(lubridate)
})

source("R/pipeline_setup.R")
setup_pipeline()

today        <- lubridate::as_date(lubridate::now(tzone = "America/Denver"))
wy           <- as.integer(Sys.getenv("WATER_YEAR", unset = water_year(today)))
SKIP_REFRESH <- isTRUE(as.logical(Sys.getenv("SKIP_REFRESH", unset = "FALSE")))
CALC_FIGURES <- isTRUE(as.logical(Sys.getenv("CALC_FIGURES", unset = "FALSE")))
periods      <- strsplit(Sys.getenv("PERIODS", unset = paste(SNOTEL_PERIODS, collapse = ",")), ",")[[1]]
stopifnot(all(periods %in% SNOTEL_PERIODS))

message("=== SNOTEL normals: WY", wy, " (", paste(periods, collapse = ", "), ") ===")

stations <- stage_stations()
if (SKIP_REFRESH) {
  if (is.null(archive_get())) stop("No archive in S3 to build from; unset SKIP_REFRESH")
} else {
  archive_refresh_full(stations)
}

stage_normals(wy, periods = periods)
done <- stage_percentiles(wy, periods = periods)

plots_ok <- TRUE; outlook_ok <- TRUE
if (wy == water_year(today)) {
  the_date <- latest_swe_date(today)
  if (!is.na(the_date)) {
    if (length(done))
      outlook_ok <- tryCatch({ stage_outlook(the_date, periods = done); TRUE },
                             error = \(e) { message("  Outlook failed for ", format(the_date), ": ", conditionMessage(e)); FALSE })
    if (CALC_FIGURES && any(SNOTEL_PLOT_PERIODS %in% done))
      plots_ok <- tryCatch({ stage_viz(the_date); TRUE },
                           error = \(e) { message("  Plots failed for ", format(the_date), ": ", conditionMessage(e)); FALSE })
    stage_publish(the_date)
  }
}

# Normals and tables are published either way; the task exits non-zero so a
# plotting failure shows in ECS.
if (!outlook_ok) stop("Outlook failed; normals and tables were published")
if (!plots_ok) stop("Plots failed; normals and tables were published")
message("=== SNOTEL normals: done ===")
