#!/usr/bin/env Rscript
# viz.R — per-station plots for past dates (backfills)
#
# Runs stage_viz() only: it never touches the archive, the normals or latest/.
# The dates' water years need their normals and percentiles in S3.
#
# Environment variables:
#   VIZ_DATES            Dates to plot: a comma-separated list, where an item
#                        can be a range "A:B" (e.g. 2026-10-01:2026-10-30)
#   VIZ_PERIODS          Comma-separated periods (default: snodas)
#   VIZ_STATIONS         Comma-separated triplets (default: every station
#                        with SWE in the date's water year through the date)
#   S3_BUCKET, WORK_DIR, KEEP_LOCAL, CORES, AWS_PROFILE, AWS_DEFAULT_REGION
#                        As in mco-snotel.R

suppressPackageStartupMessages({
  library(magrittr)
  library(ggplot2)
  library(patchwork)
  library(lubridate)
})

source("R/pipeline_setup.R")
setup_pipeline()

split_env <- \(nm, unset = "") {
  v <- Sys.getenv(nm, unset = unset)
  if (nzchar(v)) trimws(strsplit(v, ",")[[1]])
}
dates <- split_env("VIZ_DATES") %>%
  purrr::map(\(x) {
    ab <- lubridate::as_date(strsplit(x, ":")[[1]])
    if (length(ab) == 2) seq(ab[1], ab[2], by = "day") else ab
  }) %>%
  do.call(c, .)
if (!length(dates) || anyNA(dates)) stop("Set VIZ_DATES, e.g. 2026-10-01:2026-10-30")
periods  <- split_env("VIZ_PERIODS", unset = paste(SNOTEL_PLOT_PERIODS, collapse = ","))
stations <- split_env("VIZ_STATIONS")
stopifnot(all(periods %in% SNOTEL_PERIODS))

for (d in as.list(sort(unique(dates)))) {
  tryCatch(stage_viz(d, periods = periods, stations = stations),
           error = \(e) message("  Plots failed for ", format(d), ": ", conditionMessage(e)))
}
