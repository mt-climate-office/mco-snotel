#!/usr/bin/env Rscript
# Hindcast of the SWE outlook (R/outlook.R), for calibrating its persistence
# shape alpha and its spread factor beta (scripts/outlook-calibrate.R).
#
# Out of sample: for each test water year Y, the normals (one period, built
# with calc_station_normals()) and the persistence lengths come only from the
# record before Y. Outlooks are issued on the 1st and 15th of every month and
# scored 7-120 days on, from the smoothed normals (OUTLOOK_FLAVOR), plus the
# normals alone ("climatology") as the baseline. Two modes:
#   alpha  every alpha on a grid (aX.X), beta from config/outlook_spread.csv
#   beta   alpha from config/outlook_alpha.csv, every beta on a grid (bX.XX)
#
# Each row: method, flavor, triplet, wy, issue (MM-DD), lead, obs, s0 and z0
# (SWE and z on the issue date), crps (from the 5th-95th percentiles in steps
# of 5) and pit (the outcome's place in the forecast distribution; a zero
# outcome is placed at random within the forecast's chance of no snow).
#
# Usage (from the repo root):
#   Rscript scripts/outlook-hindcast.R ARCHIVE STATIONS OUT_DIR PERIOD [N_STATIONS] [CORES] [MODE]
#     ARCHIVE   local copy of archive/snotel.parquet
#     STATIONS  local copy of stations/stations.parquet
#     PERIOD    30yr, snodas or por
#     MODE      alpha (default) or beta
# Writes OUT_DIR/hindcast_{PERIOD}.parquet (alpha) or hindcast_beta_{PERIOD}.parquet.
# About 10 minutes per period for 120 stations on 8 cores.

suppressPackageStartupMessages(library(magrittr))
for (f in c("utils", "zig_spline_normals", "normals", "outlook")) source(file.path("R", paste0(f, ".R")))
for (f in c("ecdf", "zig", "zig_spline", "qnorm_grid")) Rcpp::sourceCpp(file.path("src", paste0(f, ".cpp")))
source("R/archive.R")

args <- commandArgs(TRUE)
if (length(args) < 4) stop("Usage: outlook-hindcast.R ARCHIVE STATIONS OUT_DIR PERIOD [N_STATIONS] [CORES]")
ARCHIVE <- args[1]; STATIONS <- args[2]; OUT <- args[3]; PERIOD <- args[4]
N_ST  <- if (length(args) >= 5) as.integer(args[5]) else 120L
CORES <- if (length(args) >= 6) as.integer(args[6]) else 8L
MODE  <- if (length(args) >= 7) args[7] else "alpha"
stopifnot(PERIOD %in% SNOTEL_PERIODS, MODE %in% c("alpha", "beta"))

ALPHAS   <- seq(0.3, 2.4, by = 0.1)
BETAS    <- seq(0, 0.8, by = 0.05)
LEADS    <- c(7, 14, 30, 60, 90, 120)
ISSUE_MD <- sprintf("%02d-%02d", rep(c(10:12, 1:9), each = 2), rep(c(1, 15), 12))
PROBS    <- seq(0.05, 0.95, by = 0.05)
set.seed(20261031)

# Active stations with records from WY1987 or earlier, sampled across states.
st <- arrow::read_parquet(STATIONS) %>% dplyr::filter(active, begin_date <= as.Date("1986-10-01"))
pick <- st %>% dplyr::group_by(state) %>%
  dplyr::slice_sample(n = ceiling(N_ST / dplyr::n_distinct(st$state))) %>% dplyr::ungroup()
stations <- sort(head(pick$triplet[sample(nrow(pick))], N_ST))
rec <- archive_swe(ARCHIVE) %>% dplyr::filter(triplet %in% stations)
last_wy <- water_year(max(rec$date)) - (format(max(rec$date), "%m-%d") != "09-30")
TEST_YEARS <- (last_wy - 10L):last_wy
message(length(stations), " stations, ", PERIOD, ", test years WY", min(TEST_YEARS), "-", max(TEST_YEARS))

# CRPS from quantiles (twice the mean pinball loss), one value per row; q is
# n x length(PROBS), y length n.
crps_q <- function(q, y) 2 * rowMeans(((y < q) - matrix(PROBS, length(y), length(PROBS), byrow = TRUE)) * (q - y))

run_year <- function(Y) {
  t0 <- Sys.time()
  sm  <- swe_matrix(dplyr::filter(rec, date < lubridate::make_date(Y - 1L, 10, 1)), stations)
  res <- suppressMessages(calc_station_normals(sm, Y, PERIOD))
  years <- res$years; dates <- normals_dates(Y); L <- length(dates)
  oc <- outlook_correlations(sm, res$normals, years)
  cr <- oc$cors[[OUTLOOK_FLAVOR]]
  # One forecast setting per grid point: its alpha on each date, its lengths, its beta.
  grid <- if (MODE == "alpha")
    lapply(ALPHAS, \(a) list(label = sprintf("a%.1f", a), alpha = rep(a, L), len = outlook_fit_lengths(cr, a),
                             beta = outlook_spread_beta(PERIOD)))
  else {
    a <- outlook_alpha(PERIOD, dates); len <- outlook_fit_lengths(cr, a)
    lapply(BETAS, \(b) list(label = sprintf("b%.2f", b), alpha = a, len = len, beta = b))
  }
  act <- dplyr::filter(rec, date >= dates[1], date <= dates[L])
  y_of <- function(d) act$wteq[act$date == d][match(sm$stations, act$triplet[act$date == d])]
  by_date <- split(res$normals, res$normals$date)
  rows_for <- \(d, fl) { nf <- by_date[[format(d)]]; nf <- nf[nf$flavor == fl, ]; nf[match(sm$stations, nf$triplet), ] }

  out <- list()
  for (md in ISSUE_MD) {
    d0 <- as.Date(sprintf("%d-%s", if (md >= "10") Y - 1L else Y, md)); i0 <- match(d0, dates)
    if (is.na(i0)) next
    s0 <- y_of(d0); h0 <- reference_record(sm, d0, years)
    for (h in LEADS) {
      if (i0 + h > L) next
      dt <- dates[i0 + h]; y <- y_of(dt); ht <- reference_record(sm, dt, years)
      ok <- !is.na(s0) & !is.na(y)
      if (!any(ok)) next
      fl <- OUTLOOK_FLAVOR
      snow <- !(s0 %in% 0)   # the zero-chance floor applies to stations with snow (as calc_station_outlook)
      n0 <- rows_for(d0, fl); nt <- rows_for(dt, fl)
      z0 <- pmin(pmax(stats::qnorm(outlook_cdf(fl, n0, h0, s0, snow)), -OUTLOOK_Z_MAX), OUTLOOK_Z_MAX)
      p0 <- outlook_p_zero(fl, nt, ht, snow)
      anchor <- outlook_anchor(fl, n0, h0, z0, s0, snow)
      cdf_y <- outlook_cdf(fl, nt, ht, y, snow)
      good <- ok & !is.na(z0) & !is.na(cdf_y) & !is.na(p0)
      if (!any(good)) next
      add <- function(method, q, pit) out[[length(out) + 1L]] <<- tibble::tibble(
        method = method, flavor = fl, triplet = sm$stations[good], wy = Y, issue = md, lead = h,
        obs = y[good], s0 = s0[good], z0 = z0[good], crps = crps_q(q[good, , drop = FALSE], y[good]), pit = pit[good])
      rnd <- stats::runif(length(y))
      add("climatology", outlook_quantiles(fl, nt, ht, matrix(PROBS, length(y), length(PROBS), byrow = TRUE), snow),
          ifelse(y > 0, cdf_y, rnd * p0))
      for (g in grid) {
        rho <- exp(-(h / g$len[, i0])^g$alpha[i0])
        sg  <- sqrt(pmax(1e-12, 1 - rho^2)) * outlook_spread_k(z0, rho, g$beta)
        u   <- stats::pnorm(rho * z0 + outer(sg, stats::qnorm(PROBS)))
        q   <- outlook_quantiles(fl, nt, ht, u, snow) * anchor^rho
        # pit on the anchored scale: the outcome divided by the anchor factor.
        ya  <- y / anchor^rho
        pit <- ifelse(ya > 0, stats::pnorm((stats::qnorm(outlook_cdf(fl, nt, ht, ya, snow)) - rho * z0) / sg),
                      rnd * ifelse(p0 > 0, stats::pnorm((stats::qnorm(p0) - rho * z0) / sg), 0))
        add(g$label, q, pit)
      }
    }
  }
  message(PERIOD, " WY", Y, ": ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
  dplyr::bind_rows(out)
}

scores <- parallel::mclapply(TEST_YEARS, run_year, mc.cores = CORES, mc.preschedule = FALSE)
bad <- vapply(scores, \(x) inherits(x, "try-error"), TRUE)
if (any(bad)) stop("WY", TEST_YEARS[which(bad)[1]], " failed: ", conditionMessage(attr(scores[[which(bad)[1]]], "condition")))
fs::dir_create(OUT)
path <- file.path(OUT, paste0(if (MODE == "beta") "hindcast_beta_" else "hindcast_", PERIOD, ".parquet"))
arrow::write_parquet(dplyr::bind_rows(scores), path, compression = "zstd")
message("Wrote ", path)
