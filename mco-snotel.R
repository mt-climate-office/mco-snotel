#!/usr/bin/env Rscript
# mco-snotel.R — SNOTEL data archive pipeline
#
# On each run the script:
#   1. Refreshes station metadata.
#   2. Downloads the complete record for every station from the NRCS API and
#      stores each station as a raw Parquet file in S3. S3 versioning preserves
#      the full download history.
#   3. Combines all raw station files into a partitioned Arrow dataset
#      (Hive partitioning: site_id={id}/part-0.parquet, sorted by date within
#      each partition) optimised for cloud-native queries by station and date.
#   4. Updates per-station state.
#
# Environment variables:
#   S3_BUCKET            S3 bucket name              (default: mco-snotel)
#   WORK_DIR             Local working directory     (default: s3)
#   KEEP_LOCAL           Keep local files after run  (default: FALSE)
#   CORES                Parallel download workers   (default: 4)
#   AWS_PROFILE          AWS credentials profile     (default: mco)
#   AWS_DEFAULT_REGION   AWS region                  (default: us-west-2)

library(magrittr)
library(tidyverse)
library(snotelr)
library(arrow)
library(paws.storage)
library(lubridate)
library(fs)
library(furrr)

Sys.setenv(
  AWS_PROFILE        = Sys.getenv("AWS_PROFILE",        unset = "mco"),
  AWS_DEFAULT_REGION = Sys.getenv("AWS_DEFAULT_REGION", unset = "us-west-2")
)

S3_BUCKET  <- Sys.getenv("S3_BUCKET",  unset = "mco-snotel")
OUTPUT_DIR <- Sys.getenv("WORK_DIR",   unset = "s3")
KEEP_LOCAL <- isTRUE(as.logical(Sys.getenv("KEEP_LOCAL", unset = "TRUE")))
CORES      <- as.integer(Sys.getenv("CORES", unset = "4"))

# ── S3 prefix / key constants ─────────────────────────────────────────────────
S3_PREFIX_RAW     <- "raw"        # raw/{site_id}.parquet (versioned)
S3_PREFIX_ARCHIVE <- "archive"    # archive/site_id={id}/part-0.parquet
S3_KEY_STATIONS   <- "stations/stations.parquet"
S3_KEY_STATE      <- "cache/state.parquet"

# ── S3 helpers ────────────────────────────────────────────────────────────────
s3_client <- paws.storage::s3()

s3_get_file <- function(bucket, key, local_path) {
  tryCatch({
    fs::dir_create(fs::path_dir(local_path), recurse = TRUE)
    obj <- s3_client$get_object(Bucket = bucket, Key = key)
    writeBin(obj$Body, local_path)
    invisible(local_path)
  }, error = function(e) invisible(NULL))
}

s3_put_file <- function(bucket, key, local_path,
                        content_type = "application/octet-stream") {
  s3_client$put_object(
    Bucket      = bucket,
    Key         = key,
    Body        = local_path,
    ContentType = content_type
  )
  message(sprintf("  -> s3://%s/%s", bucket, key))
  invisible(key)
}

# Upload every file under local_dir to s3://bucket/s3_prefix/...
s3_put_dir <- function(bucket, s3_prefix, local_dir) {
  files <- fs::dir_ls(local_dir, recurse = TRUE, type = "file")
  purrr::walk(files, function(f) {
    key <- paste0(s3_prefix, "/", fs::path_rel(f, local_dir))
    s3_put_file(bucket, key, f)
  })
}

# ── Setup ─────────────────────────────────────────────────────────────────────
fs::dir_create(OUTPUT_DIR, recurse = TRUE)

message("=== SNOTEL Archive Pipeline: starting ===")
message(sprintf("Bucket: %s | Work dir: %s | Cores: %d", S3_BUCKET, OUTPUT_DIR, CORES))

future::plan(future::multisession, workers = CORES)

# ── Step 1: Station metadata ──────────────────────────────────────────────────
message("\n--- Step 1: Station metadata ---")

stations_local <- fs::path(OUTPUT_DIR, "stations", "stations.parquet")
fs::dir_create(fs::path_dir(stations_local), recurse = TRUE)

stations <- snotelr::snotel_info()
message(sprintf("  %d stations found", nrow(stations)))

arrow::write_parquet(stations, stations_local, compression = "zstd")
s3_put_file(S3_BUCKET, S3_KEY_STATIONS, stations_local)

# ── Step 2: Download raw data for all stations ────────────────────────────────
message("\n--- Step 2: Downloading raw station data ---")

raw_dir <- fs::path(OUTPUT_DIR, "raw")
fs::dir_create(raw_dir, recurse = TRUE)

download_station <- function(sid) {
  tryCatch(
    snotelr::snotel_download(
      site_id  = sid,
      internal = TRUE
    ),
    error = function(e) {
      message(sprintf("  WARN: station %d: %s", sid, conditionMessage(e)))
      NULL
    }
  )
}

raw_list <- furrr::future_map(
  stations$site_id,
  download_station,
  .options  = furrr::furrr_options(seed = TRUE),
  .progress = TRUE
) %>%
  purrr::set_names(stations$site_id)

# Save each station as raw/{site_id}.parquet and upload to S3 (versioned)
message("  Saving and uploading raw station files...")
purrr::iwalk(raw_list, function(df, sid) {
  if (is.null(df)) return(invisible(NULL))
  local_path <- fs::path(raw_dir, paste0(sid, ".csv"))
  readr::write_csv(df, local_path)
  s3_put_file(S3_BUCKET, paste0(S3_PREFIX_RAW, "/", sid, ".csv"), local_path,
              content_type = "text/csv")
})

n_downloaded <- sum(!purrr::map_lgl(raw_list, is.null))
message(sprintf("  Downloaded %d of %d stations", n_downloaded, length(stations$site_id)))

# ── Step 3: Build partitioned Arrow dataset from raw files ────────────────────
message("\n--- Step 3: Building partitioned archive ---")

# Combine all raw station data into one table, normalising date type
combined <- fs::dir_ls(raw_dir, glob = "*.csv") %>%
  purrr::map(readr::read_csv, col_types = readr::cols(.default = "c"), show_col_types = FALSE) %>%
  purrr::compact() %>%
  dplyr::bind_rows() %>%
  dplyr::mutate(
    date    = lubridate::as_date(date),
    site_id = as.integer(site_id)
  ) %>%
  dplyr::distinct(site_id, date, .keep_all = TRUE) %>%
  dplyr::arrange(site_id, date)

message(sprintf("  %d total records across %d stations",
                nrow(combined), dplyr::n_distinct(combined$site_id)))

# Write as a Hive-partitioned Arrow dataset:
#   archive/site_id={id}/part-0.parquet
# Partitioning by site_id enables partition pruning for single-station queries.
# Data is sorted by date within each partition for efficient date-range filtering.
archive_local_dir <- fs::path(OUTPUT_DIR, "archive")
if (fs::dir_exists(archive_local_dir)) fs::dir_delete(archive_local_dir)

arrow::write_dataset(
  combined,
  path                  = archive_local_dir,
  format                = "parquet",
  partitioning          = "site_id",
  existing_data_behavior = "overwrite"
)

message(sprintf("  Uploading %d partition files to S3...",
                length(fs::dir_ls(archive_local_dir, recurse = TRUE, type = "file"))))
s3_put_dir(S3_BUCKET, S3_PREFIX_ARCHIVE, archive_local_dir)

# ── Step 4: Update per-station state ──────────────────────────────────────────
message("\n--- Step 4: Updating state ---")

state_local <- fs::path(OUTPUT_DIR, "cache", "state.parquet")
fs::dir_create(fs::path_dir(state_local), recurse = TRUE)

new_state <- combined %>%
  dplyr::group_by(site_id) %>%
  dplyr::summarise(
    last_date  = max(date, na.rm = TRUE),
    n_records  = dplyr::n(),
    updated_at = lubridate::now(tzone = "America/Denver"),
    .groups    = "drop"
  )

arrow::write_parquet(new_state, state_local, compression = "zstd")
s3_put_file(S3_BUCKET, S3_KEY_STATE, state_local)

# ── Cleanup ───────────────────────────────────────────────────────────────────
future::plan(future::sequential)

if (!KEEP_LOCAL) {
  message("\nCleaning up local working directory...")
  fs::dir_delete(OUTPUT_DIR)
}

message("\n=== SNOTEL Archive Pipeline: done ===")
