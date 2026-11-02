# The daily archive: one row per station and day, with each AWDB element's
# value and QC/QA flags, sorted by (triplet, date). Station metadata lives in
# the subjects file, not on every row.
#
# The layout decides how the archive is split: layout_key("raw", wy = w) is
# the file holding water year w. Layout v0 has one file for every year
# (archive/snotel.parquet; the template has no {wy}, so the resolver ignores
# it); layout v1 has one per water year (raw/snotel_wy{wy}.parquet).
#
# The whole record is refetched from AWDB once a year (archive_refresh_full(),
# run by normals-annual.R) to pick up a year of NRCS edits. Each day the
# current water year is refetched and replaces those rows (archive_refresh()).
# AWDB leaves out values marked suspect, so a value NRCS later flags drops out
# of the archive on the next refresh that covers its date.

# The key of the archive file holding water year wy.
archive_key <- function(wy) layout_key("raw", wy = wy)

# The keys of the files holding water years wys, in order, once each.
archive_keys <- function(wys) unique(vapply(as.integer(wys), archive_key, ""))

# Whether the archive has a file per water year.
archive_by_wy <- function() "wy" %in% layout_vars("raw")

# The water year of each date.
archive_wy <- function(date) normals::year_of(lubridate::as_date(date), "wy")

#' Local paths of the archive files holding water years wys. With wys NULL,
#' the whole archive: its one file, or every water year's file in WORK_DIR
#' (archive_get() or archive_refresh_full() puts them there).
archive_local <- function(wys = NULL) {
  keys <- if (!is.null(wys)) archive_keys(wys)
          else if (!archive_by_wy()) layout_key("raw")
          else archive_local_keys()
  file.path(OUTPUT_DIR, keys)
}

# The keys of the archive files in WORK_DIR, for an archive split by water
# year.
archive_local_keys <- function() {
  prefix <- layout_prefix("raw")
  keys <- paste0(prefix, list.files(file.path(OUTPUT_DIR, prefix), recursive = TRUE))
  sort(keys[layout_classify(keys) %in% "raw"])
}

# The key of a local archive path (local copies sit at their keys under
# OUTPUT_DIR).
archive_path_key <- function(path) substring(path, nchar(OUTPUT_DIR) + 2L)

archive_write_file <- function(tbl, path) {
  fs::dir_create(dirname(path))
  arrow::write_parquet(tbl, sink = path, compression = "zstd", compression_level = 13L,
                       chunk_size = 50000L)
  invisible(path)
}

#' Write archive rows of any water years to their local file(s). Returns the
#' paths written.
archive_write <- function(tbl) {
  if (!archive_by_wy()) return(archive_write_file(tbl, archive_local()))
  rng <- dplyr::collect(dplyr::summarise(tbl, first = min(date), last = max(date)))
  wys <- archive_wy(rng$first):archive_wy(rng$last)
  paths <- character()
  for (w in wys) {
    part <- tbl |>
      dplyr::filter(date >= !!normals::year_start(w, "wy"), date < !!normals::year_start(w + 1L, "wy")) |>
      dplyr::compute()
    if (part$num_rows == 0) next
    paths <- c(paths, archive_write_file(part, file.path(OUTPUT_DIR, archive_key(w))))
  }
  invisible(paths)
}

# Parts written by awdb_fetch_parts() as one sorted Arrow table.
archive_from_parts <- function(files) {
  arrow::open_dataset(files) |>
    dplyr::arrange(triplet, date) |>
    dplyr::compute()
}

# The keys of every archive file in S3, for an archive split by water year.
archive_list <- function() {
  objs <- s3_list_prefix(paws.storage::s3(), S3_BUCKET, layout_prefix("raw"))
  keys <- vapply(objs, \(o) o$Key, "")
  sort(keys[layout_classify(keys) %in% "raw"])
}

#' Download the archive files holding water years wys (default: the whole
#' archive). Returns the local paths of those in S3, or NULL if none are.
archive_get <- function(wys = NULL) {
  keys <- if (!is.null(wys)) archive_keys(wys)
          else if (!archive_by_wy()) layout_key("raw")
          else archive_list()
  got <- keys[vapply(keys, \(k) s3_get_file(S3_BUCKET, k, file.path(OUTPUT_DIR, k)), logical(1))]
  if (length(got)) file.path(OUTPUT_DIR, got)
}

archive_put <- function(paths = archive_local()) {
  for (path in paths) {
    key <- archive_path_key(path)
    s3_put_file(path, S3_BUCKET, key, content_type = "application/vnd.apache.parquet")
    message("  Uploaded ", key)
  }
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
  paths <- archive_write(tbl)
  message("  Archive: ", format(tbl$num_rows, big.mark = ","), " rows, ",
          length(unique(stations$triplet)), " stations requested")
  unlink(parts, recursive = TRUE)
  if (upload) archive_put(paths)
  archive_state_update(paths, upload = upload)
  invisible(paths)
}

#' Refetch a date window for some stations and replace those rows.
#'
#' Fails if an archive file the window falls in is missing, unless the window
#' starts that file (a water year's file, refetched from its first day): run
#' archive_refresh_full() (normals-annual.R) first.
archive_refresh <- function(triplets, begin, end, upload = TRUE) {
  begin <- lubridate::as_date(begin)
  end   <- lubridate::as_date(end)
  message("Archive: refetching ", format(begin), " to ", format(end), " for ",
          length(triplets), " station(s)")
  wys  <- archive_wy(begin):archive_wy(end)
  keys <- vapply(wys, archive_key, "")
  old  <- list()
  for (k in unique(keys)) {
    path <- file.path(OUTPUT_DIR, k)
    if (s3_get_file(S3_BUCKET, k, path)) {
      old[[k]] <- arrow::read_parquet(path, as_data_frame = FALSE)
      if (!"wteq_qc" %in% names(old[[k]]))
        stop(k, " is in the old snotelr format; run archive_refresh_full() first")
    } else {
      w <- min(wys[keys == k])
      starts_file <- begin <= normals::year_start(w, "wy") && archive_key(w - 1L) != k
      if (!starts_file) stop("No archive in ", layout_uri("raw", wy = w),
                             "; run normals-annual.R (or archive_refresh_full()) first")
    }
  }

  parts <- file.path(OUTPUT_DIR, "work", "awdb-recent")
  unlink(parts, recursive = TRUE)
  new <- archive_from_parts(awdb_fetch_parts(triplets, begin, end, parts))

  paths <- character(); n_all <- 0
  for (k in unique(keys)) {
    kw <- wys[keys == k]
    new_k <- if (length(unique(keys)) == 1L) new else
      dplyr::compute(dplyr::filter(new, date >= !!normals::year_start(min(kw), "wy"),
                                   date < !!normals::year_start(max(kw) + 1L, "wy")))
    combined <- if (is.null(old[[k]])) new_k else {
      keep <- old[[k]] |>
        dplyr::filter(!(triplet %in% triplets & date >= begin & date <= end)) |>
        dplyr::compute()
      arrow::concat_tables(keep, new_k$cast(keep$schema)) |>
        dplyr::arrange(triplet, date) |>
        dplyr::compute()
    }
    paths <- c(paths, archive_write_file(combined, file.path(OUTPUT_DIR, k)))
    n_all <- n_all + combined$num_rows
  }
  message("  Archive: ", format(new$num_rows, big.mark = ","), " row(s) refetched, ",
          format(n_all, big.mark = ","), " in all")
  unlink(parts, recursive = TRUE)
  if (upload) archive_put(paths)
  archive_state_update(paths, upload = upload)
  invisible(paths)
}

#' Per-station summary of the archive files given (the cache's
#' state.parquet): first and last dates with any data and with SWE, row count,
#' and when it was refreshed. Internal. For an archive split by water year
#' it covers the files this run refreshed (each day, the current water year).
archive_state_update <- function(paths = archive_local(), upload = TRUE) {
  cols <- c("triplet", "date", "wteq")
  x <- if (length(paths) == 1L) arrow::read_parquet(paths, col_select = dplyr::all_of(cols))
       else dplyr::bind_rows(lapply(paths, arrow::read_parquet, col_select = dplyr::all_of(cols)))
  state <- x |>
    dplyr::summarise(
      first_date      = min(date),
      last_date       = max(date),
      first_swe_date  = if (any(!is.na(wteq))) min(date[!is.na(wteq)]) else as.Date(NA),
      last_swe_date   = if (any(!is.na(wteq))) max(date[!is.na(wteq)]) else as.Date(NA),
      n_records       = dplyr::n(),
      .by = triplet
    ) |>
    dplyr::mutate(updated_at = Sys.time())
  key   <- layout_key("cache", file = "state.parquet")
  local <- file.path(OUTPUT_DIR, key)
  fs::dir_create(dirname(local))
  arrow::write_parquet(state, local, compression = "zstd", compression_level = 13L)
  if (upload) s3_put_file(local, S3_BUCKET, key, content_type = "application/vnd.apache.parquet")
  invisible(state)
}

#' SWE from the archive for normals and percentiles: triplet, date, wteq
#' (inches), with negative values set to NA and rows without SWE dropped.
#' `path` is one or more archive files (default: the whole archive).
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
