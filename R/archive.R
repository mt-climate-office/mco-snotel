# The daily archive (archive/snotel.parquet): one row per station and day,
# with each AWDB element's value and QC/QA flags, sorted by (triplet, date).
# Station metadata lives in stations/stations.parquet, not on every row.
#
# The whole record is refetched from AWDB once a year (archive_refresh_full(),
# run by normals-annual.R) to pick up a year of NRCS edits. Each night the
# current water year is refetched and replaces those rows (archive_refresh()).
# AWDB leaves out values marked suspect, so a value NRCS later flags drops out
# of the archive on the next refresh that covers its date.

archive_local <- function() file.path(OUTPUT_DIR, S3_KEY_ARCHIVE)

archive_write <- function(tbl, path = archive_local()) {
  fs::dir_create(dirname(path))
  arrow::write_parquet(tbl, sink = path, compression = "zstd", compression_level = 13L,
                       chunk_size = 50000L)
  invisible(path)
}

# Parts written by awdb_fetch_parts() as one sorted Arrow table.
archive_from_parts <- function(files) {
  arrow::open_dataset(files) |>
    dplyr::arrange(triplet, date) |>
    dplyr::compute()
}

# Download the archive, if there is one in S3. Returns the local path or NULL.
archive_get <- function() {
  path <- archive_local()
  if (s3_get_file(S3_BUCKET, S3_KEY_ARCHIVE, path)) path
}

archive_put <- function(path = archive_local()) {
  s3_put_file(path, S3_BUCKET, S3_KEY_ARCHIVE, content_type = "application/vnd.apache.parquet")
  message("  Uploaded ", S3_KEY_ARCHIVE)
}

#' Refetch every station's whole record and replace the archive.
archive_refresh_full <- function(stations, upload = TRUE) {
  message("Archive: refetching every station's record from AWDB")
  parts <- file.path(OUTPUT_DIR, "work", "awdb-full")
  unlink(parts, recursive = TRUE)
  # Each station from its AWDB begin date; a few report data from before it.
  begin <- pmax(lubridate::as_date("1900-01-01"),
                dplyr::coalesce(stations$begin_date, lubridate::as_date("1900-01-01")) - 366L)
  files <- awdb_fetch_parts(stations$triplet, begin, Sys.Date(), parts)
  tbl <- archive_from_parts(files)
  archive_write(tbl)
  message("  Archive: ", format(tbl$num_rows, big.mark = ","), " rows, ",
          length(unique(stations$triplet)), " stations requested")
  unlink(parts, recursive = TRUE)
  if (upload) archive_put()
  archive_state_update(upload = upload)
  invisible(archive_local())
}

#' Refetch a date window for some stations and replace those rows.
#'
#' Fails if there is no archive in the current format yet: run
#' archive_refresh_full() (normals-annual.R) first.
archive_refresh <- function(triplets, begin, end, upload = TRUE) {
  begin <- lubridate::as_date(begin)
  end   <- lubridate::as_date(end)
  message("Archive: refetching ", format(begin), " to ", format(end), " for ",
          length(triplets), " station(s)")
  path <- archive_get()
  if (is.null(path)) stop("No archive in s3://", S3_BUCKET, "/", S3_KEY_ARCHIVE,
                          "; run normals-annual.R (or archive_refresh_full()) first")
  old <- arrow::read_parquet(path, as_data_frame = FALSE)
  if (!"wteq_qc" %in% names(old))
    stop(S3_KEY_ARCHIVE, " is in the old snotelr format; run archive_refresh_full() first")

  parts <- file.path(OUTPUT_DIR, "work", "awdb-recent")
  unlink(parts, recursive = TRUE)
  new <- archive_from_parts(awdb_fetch_parts(triplets, begin, end, parts))

  keep <- old |>
    dplyr::filter(!(triplet %in% triplets & date >= begin & date <= end)) |>
    dplyr::compute()
  combined <- arrow::concat_tables(keep, new$cast(keep$schema)) |>
    dplyr::arrange(triplet, date) |>
    dplyr::compute()
  archive_write(combined, path)
  message("  Archive: ", format(new$num_rows, big.mark = ","), " row(s) refetched, ",
          format(combined$num_rows, big.mark = ","), " in all")
  unlink(parts, recursive = TRUE)
  if (upload) archive_put(path)
  archive_state_update(upload = upload)
  invisible(path)
}

#' Per-station summary of the archive (cache/state.parquet): first and last
#' dates with any data and with SWE, row count, and when it was refreshed.
archive_state_update <- function(path = archive_local(), upload = TRUE) {
  state <- arrow::read_parquet(path, col_select = c("triplet", "date", "wteq")) |>
    dplyr::summarise(
      first_date      = min(date),
      last_date       = max(date),
      first_swe_date  = if (any(!is.na(wteq))) min(date[!is.na(wteq)]) else as.Date(NA),
      last_swe_date   = if (any(!is.na(wteq))) max(date[!is.na(wteq)]) else as.Date(NA),
      n_records       = dplyr::n(),
      .by = triplet
    ) |>
    dplyr::mutate(updated_at = Sys.time())
  local <- file.path(OUTPUT_DIR, S3_KEY_STATE)
  fs::dir_create(dirname(local))
  arrow::write_parquet(state, local, compression = "zstd", compression_level = 13L)
  if (upload) s3_put_file(local, S3_BUCKET, S3_KEY_STATE, content_type = "application/vnd.apache.parquet")
  invisible(state)
}

#' SWE from the archive for normals and percentiles: triplet, date, wteq
#' (inches), with negative values set to NA and rows without SWE dropped.
archive_swe <- function(path = archive_local(), from = NULL, before = NULL) {
  x <- arrow::open_dataset(path) |>
    dplyr::select(triplet, date, wteq) |>
    dplyr::filter(!is.na(wteq))
  if (!is.null(from))   x <- dplyr::filter(x, date >= !!lubridate::as_date(from))
  if (!is.null(before)) x <- dplyr::filter(x, date <  !!lubridate::as_date(before))
  dplyr::collect(x) |>
    dplyr::mutate(wteq = dplyr::if_else(wteq < 0, NA_real_, wteq)) |>
    dplyr::filter(!is.na(wteq))
}
