# Pipeline stages. Each reads its inputs from S3 (or OUTPUT_DIR) and writes
# its outputs back, so stages can also be run on their own.
#
#   stage_stations()     AWDB station metadata → stations/stations.parquet
#   stage_ingest()       this water year from AWDB → archive/snotel.parquet
#   stage_normals()      frozen normals for a water year (normals-annual.R)
#   stage_percentiles()  observed SWE against the frozen normals
#   stage_viz()          per-station plots
#   stage_publish()      latest/ snapshot and manifest.json

PARQUET_TYPE <- "application/vnd.apache.parquet"

# Captions for the normals flavors, as in mco-snodas.
SNOTEL_PLOT_FLAVORS <- c(ecdf = "Empirical History", zig = "Fitted History",
                         zig_smooth = "Smoothed History")

# Periods plotted every night; viz.R plots others on request.
SNOTEL_PLOT_PERIODS <- "snodas"

normals_prefix <- function(period, wy) file.path(S3_PREFIX_NORMALS, period, paste0("wy", wy))
reference_key  <- function(wy) file.path(S3_PREFIX_NORMALS, "reference", paste0("wy", wy, ".parquet"))
observed_key   <- function(period, wy) file.path(S3_PREFIX_NORMALS, period, "observed", paste0("wy", wy, ".parquet"))

write_pq <- function(x, path, chunk_size = NULL) {
  fs::dir_create(dirname(path))
  arrow::write_parquet(x, sink = path, compression = "zstd", compression_level = 13L,
                       use_dictionary = TRUE, chunk_size = chunk_size)
  invisible(path)
}

# Upload a local directory to an S3 prefix. Parquet gets its media type; the
# CLI guesses the rest (JSON, CSV, PNG).
s3_sync_dir <- function(local_dir, prefix, exclude = NULL) {
  dest <- shQuote(paste0("s3://", S3_BUCKET, "/", prefix))
  src  <- shQuote(local_dir)
  ex   <- as.vector(rbind(rep("--exclude", length(exclude)), shQuote(exclude)))
  aws_s3(c("sync", src, dest, "--exclude", shQuote("*"), "--include", shQuote("*.parquet"),
           ex, "--content-type", PARQUET_TYPE))
  aws_s3(c("sync", src, dest, "--exclude", shQuote("*.parquet"), ex))
}

# A local copy of an S3 object: downloaded when `refresh` or missing locally.
# Returns the path, or NULL when the object is not in S3.
s3_local <- function(key, refresh = TRUE) {
  local <- file.path(OUTPUT_DIR, key)
  if (!refresh && file.exists(local)) return(local)
  if (s3_get_file(S3_BUCKET, key, local)) local
}

stations_read <- function(refresh = FALSE) {
  path <- s3_local(S3_KEY_STATIONS, refresh)
  if (is.null(path)) stop("No ", S3_KEY_STATIONS, " in S3; run stage_stations()")
  arrow::read_parquet(path)
}


# ── Stations ──────────────────────────────────────────────────────────────────

stage_stations <- function(upload = TRUE) {
  message("Stations: AWDB metadata")
  stations <- awdb_stations()
  local <- write_pq(stations, file.path(OUTPUT_DIR, S3_KEY_STATIONS))
  if (upload) s3_put_file(local, S3_BUCKET, S3_KEY_STATIONS, content_type = PARQUET_TYPE)
  message("  ", nrow(stations), " stations, ", sum(stations$active), " active")
  invisible(stations)
}


# ── Ingest ────────────────────────────────────────────────────────────────────

#' Refetch the water year to date for stations reporting in it.
stage_ingest <- function(stations, date = Sys.Date(), upload = TRUE) {
  begin <- water_year_start(date)
  live  <- stations$triplet[stations$active | dplyr::coalesce(stations$end_date >= begin, FALSE)]
  archive_refresh(live, begin, date, upload = upload)
}


# ── Normals (annual) ──────────────────────────────────────────────────────────

#' Build and publish the frozen normals for water year wy, every period.
#'
#' Freezes the record before wy as normals/reference/wy{wy}.parquet, then
#' writes, for each period, normals/{period}/wy{wy}/:
#'   normals.parquet                 every flavor, date and station
#'   by_station/{station}.parquet    the same, one file per station
#'   zig_smooth_coef.parquet         spline coefficients per station
#'   zig_smooth_diagnostics.parquet  fit status, lambda and EDF per station
#'   zig_smooth_basis.csv            the basis, cycle days 1-365
#'   zig_smooth_model.json           how to rebuild the curves
#'   provenance.json                 reference years and build details
stage_normals <- function(wy, periods = SNOTEL_PERIODS, cores = CORES, upload = TRUE) {
  wy <- as.integer(wy)
  message("Normals: WY", wy)
  wy_start <- lubridate::make_date(wy - 1L, 10, 1)
  ref <- archive_swe(before = wy_start) %>% dplyr::arrange(triplet, date)
  ref_local <- write_pq(ref, file.path(OUTPUT_DIR, reference_key(wy)))
  if (upload) s3_put_file(ref_local, S3_BUCKET, reference_key(wy), content_type = PARQUET_TYPE)
  sm <- swe_matrix(ref)

  for (period in periods) {
    t0  <- Sys.time()
    res <- calc_station_normals(sm, wy, period, cores = cores)
    out <- file.path(OUTPUT_DIR, normals_prefix(period, wy))
    unlink(out, recursive = TRUE)

    write_pq(res$normals, file.path(out, "normals.parquet"))
    write_pq(res$coef, file.path(out, "zig_smooth_coef.parquet"))
    write_pq(res$diagnostics, file.path(out, "zig_smooth_diagnostics.parquet"))
    by_station <- split(res$normals, res$normals$triplet)
    purrr::iwalk(by_station, \(x, trip)
      write_pq(x, file.path(out, "by_station", paste0(gsub(":", "_", trip, fixed = TRUE), ".parquet"))))

    # Consumers rebuild a day's curves as basis row %*% coefficients, then the
    # parameters as zig_spline_params() does (model.json spells it out).
    utils::write.csv(zig_spline_basis(at = 1:365)$X, file.path(out, "zig_smooth_basis.csv"), row.names = FALSE)
    jsonlite::write_json(list(water_year = wy, period = period, k = ZIG_SMOOTH_K, lambda = as.list(ZIG_SMOOTH_LAMBDA),
                              method = "daily ZIG statistics smoothed over the year: logit(p_zero) by penalised binomial likelihood; log(l1) and log(L-CV) of positive SWE by penalised weighted least squares (weights = positive years)",
                              parameters = paste0("p_zero = plogis(eta_nu); L-CV clamped to [", ZIG_SMOOTH_LCV_RANGE[1], ", ", ZIG_SMOOTH_LCV_RANGE[2],
                                                  "]; shape = Hosking's PELGAM approximation from L-CV; scale = l1 / shape"),
                              basis = "mgcv cyclic cubic P-spline (bs = 'cp'), cycle days 1-365 (Oct 1 = 1; Feb 29 = 151.5)",
                              status = "0 ok; 1 no snow on record; 2 p_zero only (too few positive values); 3 no data; 4 p_zero fit did not converge; 5 ok, l1 and L-CV constant",
                              built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
                         file.path(out, "zig_smooth_model.json"), auto_unbox = TRUE, pretty = TRUE)
    with_normals <- unique(res$normals$triplet[!is.na(res$normals$q0500)])
    jsonlite::write_json(list(water_year = wy, period = period,
                              reference_water_years = range(res$years),
                              reference_record = reference_key(wy),
                              n_stations = length(sm$stations),
                              n_stations_with_normals = length(with_normals),
                              min_valid_years = min(10L, length(res$years)),
                              flavors = SNOTEL_FLAVORS,
                              units = "inches",
                              source = "NRCS AWDB REST API, daily WTEQ",
                              methods = "mco-snodas@62fe19a (src/, R/zig_spline_normals.R)",
                              built_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
                         file.path(out, "provenance.json"), auto_unbox = TRUE, pretty = TRUE)

    if (upload) s3_sync_dir(out, normals_prefix(period, wy))
    message("  ", period, ": ", length(with_normals), " of ", length(sm$stations),
            " stations with normals, in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
  }
  invisible(NULL)
}


# ── Percentiles ───────────────────────────────────────────────────────────────

#' Percentiles of this water year's SWE against the frozen normals, every
#' period: normals/{period}/observed/wy{wy}.parquet, rewritten whole each time
#' so NRCS edits to this year's values carry through.
#'
#' @return The periods written (none if the normals are not built yet).
stage_percentiles <- function(wy, periods = SNOTEL_PERIODS, upload = TRUE) {
  wy <- as.integer(wy)
  message("Percentiles: WY", wy)
  ref_path <- s3_local(reference_key(wy), refresh = FALSE)
  if (is.null(ref_path)) {
    message("  No normals for WY", wy, " yet (", reference_key(wy), "); run normals-annual.R")
    return(invisible(character()))
  }
  sm  <- swe_matrix(arrow::read_parquet(ref_path))
  obs <- archive_swe(from = lubridate::make_date(wy - 1L, 10, 1),
                     before = lubridate::make_date(wy, 10, 1))

  done <- character()
  for (period in periods) {
    np <- s3_local(file.path(normals_prefix(period, wy), "normals.parquet"), refresh = FALSE)
    if (is.null(np)) { message("  ", period, ": no normals"); next }
    pc <- calc_station_percentiles(sm, obs, arrow::read_parquet(np), normals_years(sm, wy, period))
    if (is.null(pc)) next
    # About a month of one flavor per row group, so a reader can fetch one
    # date's rows by the date statistics.
    local <- write_pq(pc, file.path(OUTPUT_DIR, observed_key(period, wy)),
                      chunk_size = 31L * dplyr::n_distinct(pc$triplet))
    if (upload) s3_put_file(local, S3_BUCKET, observed_key(period, wy), content_type = PARQUET_TYPE)
    message("  ", period, ": ", length(unique(pc$date)), " date(s), ", length(unique(pc$triplet)), " stations")
    done <- c(done, period)
  }
  invisible(done)
}


# ── Plots ─────────────────────────────────────────────────────────────────────

#' Per-station seasonal SWE plots for one date:
#' plots/{date}/{period}/{flavor}/swe/usdm/{station}.png, then
#' plots/{date}/index.json, uploaded last so its presence means the date's
#' plots are complete. A station's flavors share their SWE axis.
#'
#' @param stations Triplets to plot (default: every station with SWE in the
#'   water year through the date, active or since retired).
stage_viz <- function(date, periods = SNOTEL_PLOT_PERIODS, stations = NULL,
                      cores = CORES, upload = TRUE) {
  date <- lubridate::as_date(date)
  wy   <- water_year(date)
  meta <- stations_read()
  q_cols <- c("q0010", "q0020", "q0050", "q0100", "q0200", "q0300", "q0500",
              "q0700", "q0800", "q0900", "q0950", "q0980", "q0990")
  out_root <- file.path(OUTPUT_DIR, S3_PREFIX_PLOTS, format(date))
  message("Plots for ", format(date), ": ", paste(periods, collapse = ", "))

  errors <- character(); n_stations <- 0L; ref_years_out <- list()
  for (period in periods) {
    np <- s3_local(file.path(normals_prefix(period, wy), "normals.parquet"), refresh = FALSE)
    op <- s3_local(observed_key(period, wy), refresh = upload)
    if (is.null(np) || is.null(op)) { message("  ", period, ": no normals or percentiles for WY", wy); next }
    normals  <- arrow::read_parquet(np, col_select = c("flavor", "date", "triplet",
                                                       "ref_first_wy", "ref_last_wy", dplyr::all_of(q_cols)))
    observed <- arrow::read_parquet(op, col_select = c("flavor", "date", "triplet", "swe", "swe_ptile")) %>%
      dplyr::filter(date <= !!date)
    prov <- s3_local(file.path(normals_prefix(period, wy), "provenance.json"), refresh = FALSE)
    if (!is.null(prov)) ref_years_out[[period]] <- jsonlite::read_json(prov, simplifyVector = TRUE)$reference_water_years

    todo <- if (is.null(stations)) unique(observed$triplet) else stations
    todo <- sort(intersect(todo, unique(normals$triplet)))
    n_stations <- max(n_stations, length(todo))
    normals  <- split(normals[normals$triplet %in% todo, ], normals$triplet[normals$triplet %in% todo])
    observed <- split(observed[observed$triplet %in% todo, ], observed$triplet[observed$triplet %in% todo])

    plot_station <- function(trip) {
      st <- meta[meta$triplet == trip, ]
      o  <- observed[[trip]]
      x  <- dplyr::left_join(normals[[trip]],
                             if (is.null(o)) tibble::tibble(flavor = character(), date = as.Date(character()),
                                                            swe = numeric(), swe_ptile = numeric())
                             else dplyr::select(o, -triplet),
                             by = c("flavor", "date"))
      # Observed SWE only through the plotted date, so a rerun for an earlier
      # date does not pick up later observations.
      x[x$date > date, c("swe", "swe_ptile")] <- NA
      y_max <- max(x$q0990, x$swe, 0, na.rm = TRUE)
      # The station's own reference years; the period's if it has no normals.
      ref_years <- if (all(is.na(x$q0500))) ref_years_out[[period]]
                   else c(min(x$ref_first_wy, na.rm = TRUE), max(x$ref_last_wy, na.rm = TRUE))
      for (fl in names(SNOTEL_PLOT_FLAVORS)) {
        xs <- x[x$flavor == fl, ]
        snodas_save_png(plot_snotel(xs, st, normals_label = SNOTEL_PLOT_FLAVORS[[fl]],
                                    ref_years = ref_years, y_max = if (y_max > 0) y_max),
                        file.path(out_root, period, fl, "swe", "usdm", paste0(st$station, ".png")))
      }
      invisible(TRUE)
    }

    # Forked workers inherit the data and functions. A failed station is
    # logged, not fatal, so one odd station cannot block the night's plots.
    t0 <- Sys.time()
    chunks  <- split(todo, (seq_along(todo) - 1L) %% max(1L, cores))
    results <- parallel::mclapply(chunks, \(ts) {
      vapply(ts, \(t) tryCatch({ plot_station(t); "" },
                               error = \(e) paste0(t, ": ", conditionMessage(e))),
             character(1))
    }, mc.cores = max(1L, cores), mc.preschedule = FALSE)
    if (any(vapply(results, \(r) is.null(r) || inherits(r, "try-error"), logical(1))))
      stop("A plotting worker died (likely out of memory)")
    errs <- unlist(results); errs <- errs[nzchar(errs)]
    errors <- c(errors, errs)
    message("  ", period, ": ", length(todo), " stations in ",
            round(difftime(Sys.time(), t0, units = "mins"), 1), " min; ", length(errs), " failed")
    if (length(errs)) message("  e.g. ", paste(utils::head(errs, 3), collapse = " | "))
  }
  if (!length(ref_years_out)) return(invisible(NULL))

  # One index per date, listing every period plotted for it so far.
  index_key <- file.path(S3_PREFIX_PLOTS, format(date), "index.json")
  old <- if (upload) s3_local(index_key) else file.path(OUTPUT_DIR, index_key)
  if (!is.null(old) && !file.exists(old)) old <- NULL
  old_periods <- if (!is.null(old)) jsonlite::read_json(old, simplifyVector = TRUE)$reference_water_years
  ref_years_all <- utils::modifyList(as.list(old_periods %||% list()), ref_years_out)
  fs::dir_create(out_root)
  n_files <- length(list.files(out_root, pattern = "\\.png$", recursive = TRUE))
  jsonlite::write_json(
    list(date = format(date), periods = I(names(ref_years_all)), flavors = names(SNOTEL_PLOT_FLAVORS),
         types = I("swe"), styles = I("usdm"), n_stations = n_stations, n_plots = n_files,
         path = "{period}/{flavor}/{type}/{style}/{station}.png",
         reference_water_years = ref_years_all,
         failed = as.list(errors), created = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    file.path(out_root, "index.json"), auto_unbox = TRUE, pretty = TRUE)

  if (upload) {
    # index.json last, so its presence in S3 means the date's plots are complete.
    s3_sync_dir(out_root, file.path(S3_PREFIX_PLOTS, format(date)), exclude = "index.json")
    s3_put_file(file.path(out_root, "index.json"), S3_BUCKET, index_key, content_type = "application/json")
    if (!KEEP_LOCAL) unlink(out_root, recursive = TRUE)
  }
  invisible(out_root)
}


# ── Publish ───────────────────────────────────────────────────────────────────

#' Copy the current tables into latest/ (server-side) and write
#' latest/manifest.json. latest/ is cached briefly by the CDN, so consumers
#' that want tonight's values read it rather than the dated paths.
stage_publish <- function(date) {
  date <- lubridate::as_date(date)
  wy   <- water_year(date)
  message("Publish: latest/ for ", format(date))
  s3 <- paws.storage::s3()

  copies <- c(stats::setNames(S3_KEY_STATIONS, file.path(S3_PREFIX_LATEST, "stations.parquet")),
              stats::setNames(vapply(SNOTEL_PERIODS, \(p) observed_key(p, wy), ""),
                              file.path(S3_PREFIX_LATEST, paste0("observed_", SNOTEL_PERIODS, ".parquet"))))
  files <- character()
  for (dest in names(copies)) {
    src <- copies[[dest]]
    if (!s3_exists(src)) next
    s3$copy_object(Bucket = S3_BUCKET, CopySource = paste0(S3_BUCKET, "/", src), Key = dest)
    files <- c(files, dest)
  }

  normals <- purrr::compact(stats::setNames(lapply(SNOTEL_PERIODS, \(p)
    if (s3_exists(file.path(normals_prefix(p, wy), "normals.parquet"))) normals_prefix(p, wy)), SNOTEL_PERIODS))
  plots_key <- file.path(S3_PREFIX_PLOTS, format(date))
  manifest <- jsonlite::toJSON(
    purrr::compact(list(
      date        = format(date),
      water_year  = wy,
      updated     = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      archive     = S3_KEY_ARCHIVE,
      files       = files,
      normals     = if (length(normals)) normals,
      plots       = if (s3_exists(file.path(plots_key, "index.json"))) plots_key
    )),
    auto_unbox = TRUE, pretty = TRUE)
  s3$put_object(Bucket = S3_BUCKET, Key = file.path(S3_PREFIX_LATEST, "manifest.json"),
                Body = charToRaw(manifest), ContentType = "application/json")
  message("  latest/manifest.json: ", length(files), " file(s)")
  invisible(NULL)
}

#' The newest date with SWE in this water year's archive, up to `date`.
latest_swe_date <- function(date = Sys.Date()) {
  wy_start <- water_year_start(date)
  x <- arrow::open_dataset(archive_local()) |>
    dplyr::filter(!is.na(wteq), date >= !!wy_start, date <= !!lubridate::as_date(date)) |>
    dplyr::summarise(d = max(date)) |>
    dplyr::collect()
  if (!nrow(x) || is.na(x$d)) NA else x$d
}
