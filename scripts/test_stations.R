#!/usr/bin/env Rscript
# Station checks for the normals (R/normals.R) on live AWDB data.
#
#   1. ECDF quantiles equal quantile(type = 7) of the positive reference
#      values, zero-inflated, for every station and date.
#   2. ZIG percentiles equal p0 + (1 - p0) * pgamma(swe) from the stored
#      parameters, and gamlss.dist::pZAGA where it is installed.
#   3. Percentiles are in [0, 100]; standardized anomalies in [-4, 4].
#   4. Every period's reference years are as documented.
#
# Usage: Rscript scripts/test_stations.R [triplet ...]
#        (default: Stuart Mountain MT, Garver Creek MT, Old Independence Mine AK)

suppressPackageStartupMessages(library(magrittr))
for (f in c("normals", "awdb")) source(file.path("R", paste0(f, ".R")))

triplets <- commandArgs(TRUE)
if (!length(triplets)) triplets <- c("901:MT:SNTL", "918:MT:SNTL", "1315:AK:SNTL")
wy <- normals::year_of(Sys.Date(), "wy")
wy_start <- normals::year_start(wy, "wy")

x <- awdb_data(triplets, "1900-01-01", Sys.Date(), elements = "WTEQ") %>%
  dplyr::transmute(triplet, date, wteq = dplyr::if_else(wteq < 0, NA_real_, wteq)) %>%
  dplyr::filter(!is.na(wteq))
sm  <- swe_record(dplyr::filter(x, date < wy_start))
obs <- dplyr::filter(x, date >= wy_start)

ok <- function(label, cond) {
  cat(sprintf("  %-70s %s\n", label, if (isTRUE(cond)) "[PASS]" else "[FAIL]"))
  if (!isTRUE(cond)) FAILED <<- TRUE
}
FAILED <- FALSE

# 4. Reference years
ok("30yr is the 30 years before the water year",
   identical(period_years(2027L, "30yr"), 1997:2026))
ok("snodas starts at WY2004 until W - 30 passes it",
   identical(period_years(2027L, "snodas"), 2004:2026) &&
     identical(period_years(2040L, "snodas"), 2010:2039))
ok("por runs from the record's first year",
   identical(period_years(2027L, "por", first_wy = 1980L), 1980:2026))
ok("reference dates roll Feb 29 back to Feb 28",
   identical(normals::reference_dates(as.Date("2028-02-29"), 2027L, "wy"), as.Date("2027-02-28")))

for (period in SNOTEL_PERIODS) {
  cat("\n", period, "\n", sep = "")
  res   <- calc_station_normals(sm, wy, period)
  years <- res$years
  n     <- res$normals

  # 1. ECDF vs type-7 quantiles
  probs <- c(q0100 = 0.1, q0500 = 0.5, q0900 = 0.9)
  diffs <- purrr::map_dbl(sample(normals::year_dates(wy, "wy"), 40), \(d) {
    h <- normals::reference_record(sm, d, years, "wy")
    e <- n[n$flavor == "ecdf" & n$date == d, ]
    max(purrr::map_dbl(seq_along(sm$subjects), \(i) {
      v <- h[i, !is.na(h[i, ])]
      if (length(v) < min(10L, length(years))) return(0)
      p0 <- mean(v == 0); pos <- v[v > 0]
      # p < p0 is 0; p = p0 is the smallest positive value (the normals
      # package's empirical family).
      ref <- vapply(probs, \(p) { pa <- (p - p0) / (1 - p0)
        if (pa < 0) 0 else if (length(pos) == 0) NA else unname(stats::quantile(pos, min(pa, 1), type = 7)) }, 0)
      got <- unname(unlist(e[e$triplet == sm$subjects[i], names(probs)]))
      max(abs(ref - got), na.rm = TRUE)
    }))
  })
  ok("ECDF quantiles = quantile(type = 7), zero-inflated (40 dates)", max(diffs) < 1e-10)

  # 2 and 3. Percentiles
  pc <- calc_station_percentiles(sm, obs, n, years)
  if (is.null(pc) || !nrow(pc)) { cat("  (no observations this water year)\n"); next }
  z <- dplyr::inner_join(dplyr::filter(pc, flavor == "zig", swe > 0),
                         dplyr::filter(n, flavor == "zig"), by = c("flavor", "date", "triplet")) %>%
    dplyr::filter(!is.na(zig_shape))
  if (nrow(z)) {
    direct <- 100 * (z$zig_p_zero + (1 - z$zig_p_zero) * stats::pgamma(z$swe, shape = z$zig_shape, scale = z$zig_scale))
    # swe_ptile is stored to 0.01, so it matches the exact CDF to within 0.005.
    ok("ZIG percentiles = p0 + (1 - p0) pgamma(swe), to 0.01", max(abs(round(direct, 2) - z$swe_ptile)) < 1e-8)
    if (requireNamespace("gamlss.dist", quietly = TRUE)) {
      zaga <- 100 * gamlss.dist::pZAGA(z$swe, mu = z$zig_shape * z$zig_scale,
                                       sigma = 1 / sqrt(z$zig_shape), nu = z$zig_p_zero)
      ok("ZIG percentiles = gamlss.dist::pZAGA, to 0.01", max(abs(zaga - z$swe_ptile)) <= 0.005 + 1e-8)
    }
  }
  ok("percentiles in [0, 100]", all(pc$swe_ptile >= 0 & pc$swe_ptile <= 100, na.rm = TRUE))
  ok("standardized anomalies in [-4, 4]", all(abs(pc$swe_standardized) <= 4, na.rm = TRUE))
}

cat(if (FAILED) "\nSOME TESTS FAILED\n" else "\nALL TESTS PASS\n")
quit(status = if (FAILED) 1L else 0L)
