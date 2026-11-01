# SWE outlook: the likely range of SWE for the rest of the water year, read
# from the smoothed normals (zig_smooth, OUTLOOK_FLAVOR) of each period. One
# outlook per station and period; every flavor's plot shows it.
#
# Today's SWE is placed in the smoothed distribution for today (its percentile,
# as in normals/{period}/observed/), and that percentile is carried forward on
# the standard-normal scale, fading toward normal:
#
#   z0     = qnorm(F_today(swe))                         clamped to [-4, 4]
#   rho(h) = exp(-(h / l)^alpha)                         h days ahead
#   q_p    = Q_target(pnorm(rho z0 + qnorm(p) sqrt(1 - rho^2)))
#
# where F and Q are the smoothed distribution function and quantile function
# (the vendored zig_p / zig_q, ECDF fallback included), so the outlook keeps
# the normals' shape and melts out with them. The helpers below take a flavor,
# so a hindcast can try the others.
#
#   l      the persistence length, fitted per station and issue date in the
#          annual build from the reference years' own z series
#          (outlook_lengths()), and stored on the zig_smooth rows of the
#          normals as outlook_length.
#   alpha  the persistence shape: 1 widens fast from the start, 2 starts
#          narrow and fans out later. Calibrated by period and day of the year
#          from a hindcast (config/outlook_alpha.csv), and stored with
#          outlook_length as outlook_alpha.
#
# A fitted chance of no snow below half a reference year (0.5 / n_valid) is
# taken as zero: the smoothed fit never reaches exactly zero, and a record-low
# station would otherwise be placed on that sliver and read as bare.
#
# Today's SWE can lie beyond what the distribution represents: above the
# reference years' maximum (ecdf) or past z = +-4. The quantiles are then scaled
# by (swe / Q_today(pnorm(z0)))^rho, so the range starts at today's SWE and
# relaxes to the normals as rho fades (outlook_anchor()). Within the
# distribution the ratio is about 1.

OUTLOOK_FLAVOR     <- "zig_smooth"
OUTLOOK_ALPHA_FILE <- "config/outlook_alpha.csv"
OUTLOOK_FIT_LAGS   <- c(3, 7, 14, 21, 30, 45, 60, 90, 120)   # days, for fitting l
OUTLOOK_POOL_DAYS  <- 15L    # issue dates pooled either side when fitting l
OUTLOOK_MIN_PAIRS  <- 8L     # reference years needed for a lag correlation
OUTLOOK_Z_MAX      <- 4      # |z| clamp, as swe_standardized
OUTLOOK_L_GRID     <- exp(seq(log(2), log(3000), length.out = 400))

#' The calibrated alpha table (period, flavor, day 1-365, alpha), read once.
outlook_alpha_table <- local({
  tab <- NULL
  function(path = OUTLOOK_ALPHA_FILE) {
    if (is.null(tab)) tab <<- utils::read.csv(path, comment.char = "#", stringsAsFactors = FALSE)
    tab
  }
})

#' alpha for a period on the given dates (Feb 29 between Feb 28 and Mar 1, as
#' normals_cycle_day()).
outlook_alpha <- function(period, dates, flavor = OUTLOOK_FLAVOR, table = outlook_alpha_table()) {
  x <- table[table$period == period & table$flavor == flavor, ]
  if (!nrow(x)) stop("No outlook alpha for ", period, " / ", flavor, " in ", OUTLOOK_ALPHA_FILE)
  x <- x[order(x$day), ]
  stats::approx(x$day, x$alpha, xout = normals_cycle_day(dates), rule = 2)$y
}

# ZIG parameters for one flavor's normals rows on one date, with a chance of no
# snow below half a reference year taken as zero.
outlook_params <- function(nf) {
  p0 <- nf$zig_p_zero
  p0[!is.na(p0) & p0 < 0.5 / pmax(1L, nf$n_valid)] <- 0
  cbind(nf$zig_shape, nf$zig_scale, p0)
}

# Percentiles (0-1) of x under one flavor, one date: nf the normals rows and h
# the reference record (n_station x n_years), in the same station order.
outlook_cdf <- function(flavor, nf, h, x) {
  if (flavor == "ecdf") ecdf_p(h, x) else zig_p(outlook_params(nf), x, h)
}

# Chance of exactly no snow under one flavor, one date.
outlook_p_zero <- function(flavor, nf, h) {
  emp <- rowSums(h == 0, na.rm = TRUE) / pmax(1L, rowSums(!is.na(h)))
  if (flavor == "ecdf") return(emp)
  p0 <- outlook_params(nf)[, 3]
  ifelse(is.na(nf$zig_shape) | is.na(nf$zig_scale), emp, p0)
}

# Quantiles under one flavor, one date, at station-specific probabilities u
# (n_station x n_probs). Parametric rows are vectorised; ECDF rows (and the
# ZIG's ECDF fallback) go through the vendored code one station at a time.
outlook_quantiles <- function(flavor, nf, h, u) {
  out <- matrix(NA_real_, nrow(u), ncol(u))
  par <- if (flavor == "ecdf") rep(FALSE, nrow(u)) else !is.na(nf$zig_shape) & !is.na(nf$zig_scale)
  if (any(par)) {
    p <- outlook_params(nf)[par, , drop = FALSE]
    adj <- (u[par, , drop = FALSE] - p[, 3]) / (1 - p[, 3])
    q <- stats::qgamma(pmin(pmax(adj, 0), 1), shape = p[, 1], scale = p[, 2])
    out[par, ] <- ifelse(adj <= 0, 0, q)
  }
  for (i in which(!par)) {
    if (all(is.na(h[i, ]))) next
    out[i, ] <- if (flavor == "ecdf") ecdf_q(h[i, , drop = FALSE], u[i, ])[1, ]
                else zig_q(outlook_params(nf[i, ]), u[i, ], h[i, , drop = FALSE])[1, ]
  }
  out
}

# Ratio of today's SWE to the flavor's quantile at today's (clamped)
# percentile: about 1 within the distribution, above 1 when today's SWE is
# above what it holds, below 1 when below. Kept on the side of today's anomaly
# (a quantile that underflows at z = -4 must not scale a low station up) and
# within [0.1, 10]; 1 where either is zero or missing.
outlook_anchor <- function(flavor, nf, h, z0, swe) {
  q0 <- outlook_quantiles(flavor, nf, h, matrix(stats::pnorm(z0), ncol = 1))[, 1]
  r  <- swe / q0
  r  <- ifelse(is.finite(r) & r > 0 & !is.na(z0), r, 1)
  r  <- ifelse(z0 > 0, pmax(r, 1), pmin(r, 1))
  pmin(pmax(r, 0.1), 10)
}

# Row-wise correlation of two n_station x n_years matrices over the years both
# have, NA with fewer than OUTLOOK_MIN_PAIRS years or no spread.
outlook_rowcor <- function(a, b) {
  ok <- !is.na(a) & !is.na(b); a[!ok] <- NA; b[!ok] <- NA
  n  <- rowSums(ok)
  da <- a - rowMeans(a, na.rm = TRUE); db <- b - rowMeans(b, na.rm = TRUE)
  sa <- sqrt(rowSums(da^2, na.rm = TRUE)); sb <- sqrt(rowSums(db^2, na.rm = TRUE))
  r  <- rowSums(da * db, na.rm = TRUE) / (sa * sb)
  r[n < OUTLOOK_MIN_PAIRS | sa < 1e-6 | sb < 1e-6] <- NA
  r
}

#' Lag correlations of the reference years' z, per flavor (by default only
#' OUTLOOK_FLAVOR).
#'
#' Each reference year's SWE is placed in the flavor's distribution for its
#' date (z, clamped to +-4), and z's correlation across years between each date
#' and OUTLOOK_FIT_LAGS days later is taken per station.
#'
#' @param sm      swe_matrix() of the frozen reference record.
#' @param normals The period's normals (calc_station_normals()$normals).
#' @param years   The period's reference years.
#' @return list(dates, stations, cors = list by flavor of n_station x n_dates x
#'   n_lags arrays).
outlook_correlations <- function(sm, normals, years, flavors = OUTLOOK_FLAVOR) {
  dates <- sort(unique(normals$date)); L <- length(dates)
  hs <- lapply(dates, \(d) reference_record(sm, d, years))
  by_date <- split(normals, normals$date)
  cors <- purrr::map(stats::setNames(flavors, flavors), \(fl) {
    Z <- lapply(seq_len(L), \(t) {
      nf <- by_date[[format(dates[t])]]; nf <- nf[nf$flavor == fl, ]; nf <- nf[match(sm$stations, nf$triplet), ]
      h  <- hs[[t]]
      z  <- vapply(seq_len(ncol(h)), \(y) stats::qnorm(outlook_cdf(fl, nf, h, h[, y])), numeric(nrow(h)))
      z  <- matrix(z, nrow(h)); z[is.na(h)] <- NA
      pmin(pmax(z, -OUTLOOK_Z_MAX), OUTLOOK_Z_MAX)
    })
    cr <- array(NA_real_, c(length(sm$stations), L, length(OUTLOOK_FIT_LAGS)))
    for (k in seq_along(OUTLOOK_FIT_LAGS)) for (t in seq_len(L - OUTLOOK_FIT_LAGS[k]))
      cr[, t, k] <- outlook_rowcor(Z[[t]], Z[[t + OUTLOOK_FIT_LAGS[k]]])
    cr
  })
  list(dates = dates, stations = sm$stations, cors = cors)
}

#' Persistence lengths l (days) from outlook_correlations() for one flavor:
#' the correlations, pooled over issue dates within OUTLOOK_POOL_DAYS, fitted
#' by exp(-(h / l)^alpha) by least squares on a grid of l. Dates with too
#' little data take the station's median length.
#'
#' @param cr    One flavor's n_station x n_dates x n_lags correlations.
#' @param alpha One alpha per date (or a single value).
#' @return n_station x n_dates matrix.
outlook_fit_lengths <- function(cr, alpha) {
  L <- dim(cr)[2]; alpha <- rep_len(alpha, L)
  len <- matrix(NA_real_, dim(cr)[1], L)
  for (t in seq_len(L)) {
    w <- max(1L, t - OUTLOOK_POOL_DAYS):min(L, t + OUTLOOK_POOL_DAYS)
    r <- rowMeans(aperm(cr[, w, , drop = FALSE], c(1, 3, 2)), na.rm = TRUE, dims = 2)   # n_station x lags
    r[!is.finite(r)] <- NA
    kern <- exp(-outer(OUTLOOK_L_GRID, OUTLOOK_FIT_LAGS, \(l, h) (h / l)^alpha[t]))     # grid x lags
    sse <- matrix(0, nrow(r), length(OUTLOOK_L_GRID))
    for (k in seq_along(OUTLOOK_FIT_LAGS)) {
      d <- outer(r[, k], kern[, k], `-`)^2
      d[is.na(d)] <- 0
      sse <- sse + d
    }
    fit <- OUTLOOK_L_GRID[max.col(-sse, ties.method = "first")]
    fit[rowSums(!is.na(r)) < 3] <- NA
    len[, t] <- fit
  }
  med <- apply(len, 1, stats::median, na.rm = TRUE)
  len[is.na(len)] <- med[row(len)[is.na(len)]]
  len
}

#' Persistence lengths and shapes for every station and date of one period's
#' smoothed normals, with alpha from config/outlook_alpha.csv.
#'
#' @return flavor (OUTLOOK_FLAVOR), date, triplet, outlook_length (days),
#'   outlook_alpha.
outlook_lengths <- function(sm, normals, years, period) {
  oc <- outlook_correlations(sm, normals, years)
  L  <- length(oc$dates); n <- length(oc$stations)
  alpha <- outlook_alpha(period, oc$dates)
  len   <- outlook_fit_lengths(oc$cors[[OUTLOOK_FLAVOR]], alpha)
  tibble::tibble(flavor = OUTLOOK_FLAVOR, date = rep(oc$dates, each = n), triplet = rep(oc$stations, L),
                 outlook_length = round(as.vector(len), 2), outlook_alpha = rep(round(alpha, 3), each = n))
}

#' The outlook from one issue date to the end of its water year, one period,
#' from the smoothed normals.
#'
#' @param sm      swe_matrix() of the frozen reference record.
#' @param normals The period's normals, with outlook_length and outlook_alpha
#'   on the OUTLOOK_FLAVOR rows.
#' @param years   The period's reference years.
#' @param obs     triplet and wteq on the issue date (stations without a value
#'   are left out).
#' @param issue   The issue date.
#' @return date, triplet, q0000 ... q1000 (the normals' 19 quantile
#'   probabilities; 0 and 1 are read at z = -4 and 4) and p_snow_free (the
#'   chance of no snow on that date), for every date after the issue date
#'   through Sep 30. NULL if the normals have no outlook columns.
calc_station_outlook <- function(sm, normals, years, obs, issue) {
  if (!all(c("outlook_length", "outlook_alpha") %in% names(normals))) return(NULL)
  issue <- lubridate::as_date(issue)
  obs   <- obs[!is.na(obs$wteq) & obs$triplet %in% sm$stations, ]
  if (!nrow(obs)) return(NULL)
  i <- match(obs$triplet, sm$stations)
  targets <- normals_dates(water_year(issue)); targets <- targets[targets > issue]
  if (!length(targets)) return(NULL)
  by_date <- split(normals, normals$date)
  zq <- stats::qnorm(pmin(pmax(unname(SNODAS_QUANTILES), stats::pnorm(-OUTLOOK_Z_MAX)), stats::pnorm(OUTLOOK_Z_MAX)))
  fl <- OUTLOOK_FLAVOR
  rows_for <- \(d) { nf <- by_date[[format(d)]]; nf <- nf[nf$flavor == fl, ]; nf[match(obs$triplet, nf$triplet), ] }

  n0 <- rows_for(issue)
  h0 <- reference_record(sm, issue, years)[i, , drop = FALSE]
  z0 <- pmin(pmax(stats::qnorm(outlook_cdf(fl, n0, h0, obs$wteq)), -OUTLOOK_Z_MAX), OUTLOOK_Z_MAX)
  anchor <- outlook_anchor(fl, n0, h0, z0, obs$wteq)
  purrr::map(targets, \(d) {
    nt  <- rows_for(d)
    ht  <- reference_record(sm, d, years)[i, , drop = FALSE]
    rho <- exp(-(as.numeric(d - issue) / n0$outlook_length)^n0$outlook_alpha)
    sg  <- sqrt(pmax(1e-12, 1 - rho^2))
    u   <- stats::pnorm(rho * z0 + outer(sg, zq))
    q   <- round(outlook_quantiles(fl, nt, ht, u) * anchor^rho, 1)
    colnames(q) <- names(SNODAS_QUANTILES)
    p0  <- outlook_p_zero(fl, nt, ht)
    psf <- ifelse(p0 > 0, stats::pnorm((stats::qnorm(p0) - rho * z0) / sg), 0)
    tibble::tibble(date = d, triplet = obs$triplet, tibble::as_tibble(q),
                   p_snow_free = round(psf, 3))[!is.na(z0) & !is.na(n0$outlook_length), ]
  }) |>
    purrr::list_rbind() |>
    dplyr::arrange(triplet, date)
}
