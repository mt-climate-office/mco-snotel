# Station SWE normals: the mco-snodas zonal method applied to each station's
# own daily SWE record. A station is one series, as a watershed is in
# calc_zonal_normals(means = …), so the three flavors are fitted exactly as
# there:
#   ecdf        zero-inflated type-7 ECDF (src/ecdf.cpp)
#   zig         zero-inflated gamma by L-moments (src/zig.cpp)
#   zig_smooth  the daily ZIG's statistics smoothed over the water year with
#               cyclic P-splines (src/zig_spline.cpp, R/zig_spline_normals.R)
#
# Normals for water year W (Oct 1 – Sep 30, named for the year it ends in) are
# built once, as W starts, from the record before it, for three reference
# periods (SNOTEL_PERIODS):
#   30yr    the 30 water years before W
#   snodas  the water years the SNODAS normals use: from WY2004 (SNODAS's
#           first complete year) or W - 30, whichever is later, to W - 1
#   por     each station's whole period of record before W
# A date's reference values are the same calendar day in each reference year
# (Feb 29 → Feb 28), as normals_reference_years() in mco-snodas. Years with
# no value are skipped; a date needs min(10, years in the period) valid years
# (MIN_VALID_YEARS in src/ecdf_impl.h).
#
# The frozen record (normals/reference/wy{W}.parquet) is what the normals
# were built from; daily percentiles are computed against it, as mco-snodas
# computes them against its saved raw means, so later NRCS edits to the
# historical record do not shift the normals mid-year.

SNOTEL_PERIODS      <- c("30yr", "snodas", "por")
SNOTEL_FLAVORS      <- c("ecdf", "zig", "zig_smooth")
SNODAS_FIRST_WY     <- 2004L

#' Reference water years of a period, for the normals of water year wy.
#'
#' @param first_wy First water year of the record (for "por").
period_years <- function(wy, period, first_wy) {
  switch(period,
         `30yr` = (wy - 30L):(wy - 1L),
         snodas = max(wy - 30L, SNODAS_FIRST_WY):(wy - 1L),
         por    = first_wy:(wy - 1L),
         stop("Unknown period: ", period))
}

#' A period's reference years within a record (sm, from swe_matrix()).
normals_years <- function(sm, wy, period) {
  first <- water_year(sm$origin)
  years <- period_years(wy, period, first_wy = first)
  years[years >= first]
}

#' The same calendar day as d in each of the given water years (Feb 29 → Feb 28).
reference_dates <- function(d, years) {
  d <- lubridate::as_date(d)
  lubridate::`%m-%`(d, lubridate::years(water_year(d) - years))
}

#' A station x day SWE matrix for fast lookups by date.
#'
#' @param x triplet, date, wteq.
#' @param stations Row order (default: every triplet in x, sorted).
swe_matrix <- function(x, stations = sort(unique(x$triplet))) {
  origin <- min(x$date)
  n_day  <- as.integer(max(x$date) - origin) + 1L
  m <- matrix(NA_real_, length(stations), n_day)
  i <- match(x$triplet, stations)
  ok <- !is.na(i)
  m[cbind(i[ok], as.integer(x$date[ok] - origin) + 1L)] <- x$wteq[ok]
  list(m = m, stations = stations, origin = origin)
}

#' SWE on the given dates: n_station x length(dates), NA outside the record.
swe_at <- function(sm, dates) {
  j <- as.integer(lubridate::as_date(dates) - sm$origin) + 1L
  j[j < 1L | j > ncol(sm$m)] <- NA_integer_
  sm$m[, j, drop = FALSE]
}

#' A date's reference record: n_station x n_years, columns named by year.
reference_record <- function(sm, d, years) {
  h <- swe_at(sm, reference_dates(d, years))
  colnames(h) <- years
  h
}

# First and last reference years with a value, per station.
record_span <- function(h) {
  years <- as.integer(colnames(h))
  ok <- !is.na(h)
  any_ok <- rowSums(ok) > 0
  first <- ifelse(any_ok, years[max.col(ok, ties.method = "first")], NA_integer_)
  last  <- ifelse(any_ok, years[max.col(ok, ties.method = "last")],  NA_integer_)
  list(first = as.integer(first), last = as.integer(last))
}

#' Normals for every station and date of water year wy in one period.
#'
#' @param sm swe_matrix() of the record before wy.
#' @return list(normals = one row per flavor x date x station, coef and
#'   diagnostics of the ZIG-smooth fit, years).
calc_station_normals <- function(sm, wy, period, cores = 1L) {
  dates <- normals_dates(wy)
  years <- normals_years(sm, wy, period)
  q_probs <- unname(SNODAS_QUANTILES)
  q_names <- names(SNODAS_QUANTILES)
  message("  ", period, ": WY", min(years), "–", max(years), ", ", length(sm$stations), " stations")

  per_date <- function(d, h, flavor, params = NULL, mean = NULL, quants = NULL) {
    span <- record_span(h)
    tibble::tibble(flavor = flavor, date = d, triplet = sm$stations,
                   n_valid = as.integer(rowSums(!is.na(h))),
                   ref_first_wy = span$first, ref_last_wy = span$last,
                   mean = mean,
                   zig_shape  = if (is.null(params)) NA_real_ else params[, 1],
                   zig_scale  = if (is.null(params)) NA_real_ else params[, 2],
                   zig_p_zero = if (is.null(params)) NA_real_ else params[, 3]) |>
      dplyr::bind_cols(tibble::as_tibble(quants))
  }

  # ── ECDF and ZIG, day by day ───────────────────────────────────────────────
  daily <- lapply(dates, \(d) {
    h  <- reference_record(sm, d, years)
    es <- ecdf_stats(h)
    zp <- zig_fit(h)
    zq <- zig_q(zp, q_probs, h)
    colnames(zq) <- q_names
    dplyr::bind_rows(
      per_date(d, h, "ecdf", mean = es$mean, quants = es$quantiles),
      per_date(d, h, "zig",  params = zp, mean = zig_mean(zp, h), quants = zq)
    )
  })

  # ── ZIG-smooth: the daily ZIG statistics, smoothed over the year ───────────
  # Feb 29 is left out of the fit and evaluated between Feb 28 and Mar 1, as in
  # spline_fit_dates() in mco-snodas.
  fit_dates <- dates[!(lubridate::month(dates) == 2 & lubridate::day(dates) == 29)]
  vars  <- c(n = "n", z = "z", l1 = "l1", lcv = "lcv")
  stats <- lapply(vars, \(v) matrix(NA_real_, length(sm$stations), length(fit_dates)))
  for (j in seq_along(fit_dates)) {
    ss <- zig_spline_suffstats(reference_record(sm, fit_dates[j], years))
    for (v in vars) stats[[v]][, j] <- ss[, v]
  }
  fit <- zig_spline_fit_parallel(zig_spline_chunk_stats(stats, cores),
                                 zig_spline_basis(at = normals_cycle_day(fit_dates)), cores)
  X <- zig_spline_basis(at = normals_cycle_day(dates))$X

  # The fit has no minimum record, so a station with a year or two would get
  # a smooth normal. The day's ECDF and ZIG rule applies instead: fewer than
  # min(10, years in the period) valid years and the day has no normal. (Every
  # SNODAS pixel has a full record, so mco-snodas never meets this.)
  min_valid <- min(10L, length(years))
  smooth <- lapply(seq_along(dates), \(j) {
    d <- dates[j]
    h <- reference_record(sm, d, years)
    p <- zig_spline_params(fit$coef, X[j, , drop = FALSE], fit$status)
    params <- cbind(p$shape[, 1], p$scale[, 1], p$p_zero[, 1])
    params[rowSums(!is.na(h)) < min_valid, ] <- NA_real_
    quants <- zig_q(params, q_probs, h)
    colnames(quants) <- q_names
    per_date(d, h, "zig_smooth", params = params, mean = zig_mean(params, h), quants = quants)
  })

  normals <- dplyr::bind_rows(daily, smooth) |>
    dplyr::mutate(flavor = factor(flavor, levels = SNOTEL_FLAVORS)) |>
    dplyr::arrange(flavor, date, triplet) |>
    dplyr::mutate(flavor = as.character(flavor))

  k <- ZIG_SMOOTH_K
  coef <- fit$coef
  colnames(coef) <- c(sprintf("nu_%02d", 1:k), sprintf("l1_%02d", 1:k), sprintf("lcv_%02d", 1:k))
  list(
    normals = normals,
    coef = dplyr::bind_cols(tibble::tibble(triplet = sm$stations), tibble::as_tibble(coef)),
    diagnostics = tibble::tibble(
      triplet = sm$stations, status = as.integer(fit$status), iter = as.integer(fit$iter),
      lambda_nu = ZIG_SMOOTH_LAMBDA[["nu"]], lambda_l1 = ZIG_SMOOTH_LAMBDA[["l1"]],
      lambda_lcv = ZIG_SMOOTH_LAMBDA[["lcv"]],
      edf_nu = fit$edf[, 1], edf_l1 = fit$edf[, 2], edf_lcv = fit$edf[, 3]),
    years = years
  )
}

#' Percentiles of observed SWE against frozen normals, for one period.
#'
#' @param sm      swe_matrix() of the frozen reference record.
#' @param obs     triplet, date, wteq for the water year (any stations).
#' @param normals The period's normals table (calc_station_normals()$normals).
#' @param years   The period's reference years.
#' @return flavor, date, triplet, swe, swe_ptile (0-100, to 0.01) and
#'   swe_standardized (z, from the unrounded percentile), for every observed
#'   station and date.
calc_station_percentiles <- function(sm, obs, normals, years) {
  obs <- dplyr::filter(obs, triplet %in% sm$stations)
  if (!nrow(obs)) return(NULL)
  params_of <- \(x) as.matrix(x[, c("zig_shape", "zig_scale", "zig_p_zero")])
  by_date <- split(normals, normals$date)

  purrr::map(sort(unique(obs$date)), \(d) {
    o  <- obs[obs$date == d, ]
    nd <- by_date[[format(d)]]
    if (is.null(nd)) return(NULL)
    i  <- match(o$triplet, sm$stations)
    h  <- reference_record(sm, d, years)[i, , drop = FALSE]
    purrr::map(SNOTEL_FLAVORS, \(fl) {
      nf <- nd[nd$flavor == fl, ]
      nf <- nf[match(o$triplet, nf$triplet), ]
      p  <- if (fl == "ecdf") ecdf_p(h, o$wteq) else zig_p(params_of(nf), o$wteq, h)
      tibble::tibble(flavor = fl, date = d, triplet = o$triplet, swe = o$wteq,
                     swe_ptile = round(p * 100, 2), swe_standardized = qnorm_grid(p * 100) / 100)
    }) |> purrr::list_rbind()
  }) |>
    purrr::list_rbind() |>
    dplyr::mutate(flavor = factor(flavor, levels = SNOTEL_FLAVORS)) |>
    dplyr::arrange(flavor, date, triplet) |>
    dplyr::mutate(flavor = as.character(flavor))
}
