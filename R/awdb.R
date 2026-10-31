# NRCS Air and Water Database (AWDB) REST API: SNOTEL station metadata and
# daily data.
#
#   https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html
#
# Values come back in AWDB's stored units (inches, °F) with their QC and QA
# flags. Data NRCS marks suspect is filtered out by the API
# (returnSuspectData = false, the default), so the archive never holds it.
# Daily values are stamped at the end of their period (periodRef = END, the
# default), as NRCS reports them.
#
# A request may name at most 1000 station elements and span at most 500,000
# values (stations × elements × days, counted over the requested dates), so
# data is fetched in batches packed under both limits (awdb_batches()).

AWDB_BASE <- "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1"

# AWDB element code → archive column. PREC is water-year accumulated
# precipitation; PRCP its daily increment.
AWDB_ELEMENTS <- c(WTEQ = "wteq", SNWD = "snwd", PREC = "prec", PRCP = "prcp",
                   TMAX = "tmax", TMIN = "tmin", TAVG = "tavg")

AWDB_MAX_ELEMENTS <- 1000L    # station elements per request
AWDB_MAX_VALUES   <- 450000L   # values per request (AWDB's limit is 500,000)

awdb_request <- function(endpoint, ...) {
  httr2::request(AWDB_BASE) |>
    httr2::req_url_path_append(endpoint) |>
    httr2::req_url_query(...) |>
    httr2::req_user_agent("mco-snotel (Montana Climate Office; https://climate.umt.edu)") |>
    httr2::req_timeout(900) |>
    # AWDB explains a 400 in the body's "message".
    httr2::req_error(body = \(resp) tryCatch(httr2::resp_body_json(resp)$message, error = \(e) NULL)) |>
    # AWDB answers heavy load with 5xx; back off and try again.
    httr2::req_retry(max_tries = 6, retry_on_failure = TRUE,
                     is_transient = \(resp) httr2::resp_status(resp) %in% c(429, 500, 502, 503, 504),
                     backoff = \(i) min(300, 10 * 2^(i - 1)))
}

#' Every SNOTEL station, active or not.
#'
#' @return One row per station. `station` is the triplet with ":" replaced by
#'   "_", for file names. `active` is TRUE while the station is still
#'   reporting (AWDB gives active stations an end date of 2100-01-01).
awdb_stations <- function() {
  x <- awdb_request("stations", stationTriplets = "*:*:SNTL", activeOnly = "false",
                    returnStationElements = "false") |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE) |>
    tibble::as_tibble()
  col <- \(nm, f = identity) if (nm %in% names(x)) f(x[[nm]]) else f(rep(NA, nrow(x)))
  day <- \(v) lubridate::as_date(substr(v, 1, 10))
  tibble::tibble(
    triplet      = x$stationTriplet,
    station      = gsub(":", "_", x$stationTriplet, fixed = TRUE),
    site_id      = as.integer(x$stationId),
    state        = x$stateCode,
    network      = x$networkCode,
    name         = x$name,
    county       = col("countyName", as.character),
    huc          = col("huc", as.character),
    elevation_ft = col("elevation", as.numeric),
    latitude     = col("latitude", as.numeric),
    longitude    = col("longitude", as.numeric),
    begin_date   = col("beginDate", day),
    end_date     = col("endDate", day),
    # AWDB gives active stations an end date of 2100-01-01; a missing one is
    # treated the same, so the station is still fetched.
    active       = is.na(end_date) | end_date >= lubridate::as_date("2100-01-01")
  ) |>
    dplyr::arrange(triplet)
}

#' Daily data for some stations as one wide table.
#'
#' @param triplets Station triplets (at most 1000 / length(elements)).
#' @param begin,end Date range (inclusive).
#' @return triplet, site_id, date, then for each element its value and _qc and _qa
#'   flags (e.g. wteq, wteq_qc, wteq_qa). Days with no value for any element
#'   are absent.
awdb_data <- function(triplets, begin, end, elements = names(AWDB_ELEMENTS)) {
  stopifnot(length(triplets) * length(elements) <= 1000L)
  x <- awdb_request("data",
                    stationTriplets = paste(triplets, collapse = ","),
                    elements        = paste(elements, collapse = ","),
                    duration        = "DAILY",
                    beginDate       = format(lubridate::as_date(begin)),
                    endDate         = format(lubridate::as_date(end)),
                    returnFlags     = "true") |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = TRUE)

  long <- purrr::map2(x$stationTriplet, x$data, \(trip, d) {
    if (!NROW(d)) return(NULL)
    purrr::map2(d$stationElement$elementCode, d$values, \(el, v) {
      if (!NROW(v)) return(NULL)
      tibble::tibble(triplet = trip, element = el,
                     date  = lubridate::as_date(v$date),
                     value = as.numeric(v$value),
                     qc    = if (is.null(v$qcFlag)) NA_character_ else as.character(v$qcFlag),
                     qa    = if (is.null(v$qaFlag)) NA_character_ else as.character(v$qaFlag))
    }) |> purrr::list_rbind()
  }) |> purrr::list_rbind()

  awdb_wide(long, elements)
}

# Long (triplet, element, date, value, qc, qa) → one row per station and day,
# with every element's columns present even when no station reported it.
awdb_wide <- function(long, elements = names(AWDB_ELEMENTS)) {
  cols <- unname(unlist(lapply(AWDB_ELEMENTS[elements], \(e) paste0(e, c("", "_qc", "_qa")))))
  if (is.null(long) || !nrow(long))
    long <- tibble::tibble(triplet = character(), element = character(), date = as.Date(character()),
                           value = numeric(), qc = character(), qa = character())
  wide <- long |>
    dplyr::mutate(element = unname(AWDB_ELEMENTS[element])) |>
    tidyr::pivot_wider(id_cols = c(triplet, date), names_from = element,
                       values_from = c(value, qc, qa), names_glue = "{element}_{.value}")
  names(wide) <- sub("_value$", "", names(wide))
  for (nm in setdiff(cols, names(wide)))
    wide[[nm]] <- if (grepl("_q[ca]$", nm)) NA_character_ else NA_real_
  wide |>
    dplyr::mutate(site_id = as.integer(sub(":.*", "", triplet))) |>
    dplyr::select(triplet, site_id, date, dplyr::all_of(cols)) |>
    dplyr::arrange(triplet, date)
}

#' Pack stations into requests under AWDB's limits.
#'
#' @param begin Per-station first dates (stations are grouped by them, so a
#'   station with a short record is not padded out to a long one's dates).
#' @return A list of list(triplets, begin).
awdb_batches <- function(triplets, begin, end, n_elements = length(AWDB_ELEMENTS)) {
  begin <- rep_len(lubridate::as_date(begin), length(triplets))
  end   <- lubridate::as_date(end)
  o <- order(begin, triplets)
  batches <- list()
  cur <- character(); cur_begin <- NULL
  for (i in o) {
    b <- if (length(cur)) min(cur_begin, begin[i]) else begin[i]
    n <- length(cur) + 1L
    fits <- n * n_elements <= AWDB_MAX_ELEMENTS &&
      n * n_elements * (as.integer(end - b) + 1L) <= AWDB_MAX_VALUES
    if (length(cur) && !fits) {
      batches[[length(batches) + 1L]] <- list(triplets = cur, begin = cur_begin)
      cur <- character(); b <- begin[i]
    }
    cur <- c(cur, triplets[i]); cur_begin <- b
  }
  if (length(cur)) batches[[length(batches) + 1L]] <- list(triplets = cur, begin = cur_begin)
  batches
}

#' Fetch daily data for many stations in batches, writing each batch to a
#' parquet part under `dir` so a whole record is never in memory at once.
#'
#' @param begin One date, or one per station (e.g. each station's begin_date).
#' @return The part files, invisibly. Fails if any batch fails after retries.
awdb_fetch_parts <- function(triplets, begin, end, dir,
                             concurrency = as.integer(Sys.getenv("AWDB_CONCURRENCY", unset = "4"))) {
  fs::dir_create(dir)
  batches <- awdb_batches(triplets, begin, end)
  message("  AWDB: ", length(triplets), " station(s) through ", format(lubridate::as_date(end)),
          " in ", length(batches), " request(s)")
  files <- file.path(dir, sprintf("part-%04d.parquet", seq_along(batches)))
  t0 <- Sys.time()
  res <- parallel::mclapply(seq_along(batches), \(i) tryCatch({
    awdb_data(batches[[i]]$triplets, batches[[i]]$begin, end) |>
      arrow::write_parquet(files[i])
    ""
  }, error = \(e) paste0(batches[[i]]$triplets[1], "…: ", conditionMessage(e))),
  mc.cores = max(1L, concurrency), mc.preschedule = FALSE)
  bad <- vapply(res, \(r) !is.character(r) || nzchar(r), logical(1))
  if (any(bad))
    stop(sum(bad), " AWDB request(s) failed, e.g. ", format(res[[which(bad)[1]]]))
  message("  AWDB: done in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
  invisible(files)
}
