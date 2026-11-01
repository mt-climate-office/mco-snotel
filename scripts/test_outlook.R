#!/usr/bin/env Rscript
# Checks for the SWE outlook (R/outlook.R) on synthetic normals with known
# gamma parameters, so they need no data or AWS.
#
#   1. With no persistence left (rho ~ 0), the outlook's quantiles are the
#      target date's normal quantiles.
#   2. With full persistence (rho ~ 1), the median is today's SWE.
#   3. Quantiles never decrease with probability; p_snow_free is in [0, 1].
#   4. More snow today never gives a lower outlook (a bare station starts at
#      zero and has the highest chance of staying bare).
#   5. A station far above its normals starts at today's SWE (the anchor).
#   6. Leap years: an outlook issued in WY2028 covers Feb 29.
#   7. beta widens the range for a station below normal and fades with rho.
#
# Usage: Rscript scripts/test_outlook.R

suppressPackageStartupMessages(library(magrittr))
for (f in c("utils", "zig_spline_normals", "normals", "outlook")) source(file.path("R", paste0(f, ".R")))
for (f in c("ecdf", "zig", "zig_spline", "qnorm_grid")) Rcpp::sourceCpp(file.path("src", paste0(f, ".cpp")))
set.seed(1)

ok <- function(label, cond) {
  cat(sprintf("  %-72s %s\n", label, if (isTRUE(cond)) "[PASS]" else "[FAIL]"))
  if (!isTRUE(cond)) FAILED <<- TRUE
}
FAILED <- FALSE

# Synthetic stations: 30 reference years, gamma SWE all winter.
make_case <- function(wy, length_days, alpha = 1.3, shape = 4, scale = 5, p_zero = 0.01, stations = c("1:XX:SNTL", "2:XX:SNTL")) {
  years <- (wy - 30L):(wy - 1L)
  days  <- seq(lubridate::make_date(min(years) - 1L, 10, 1), lubridate::make_date(max(years), 9, 30), by = "day")
  rec   <- tidyr::crossing(triplet = stations, date = days) %>% dplyr::mutate(wteq = stats::rgamma(dplyr::n(), shape, scale = scale))
  sm    <- swe_matrix(rec, stations)
  dates <- normals_dates(wy)
  normals <- tidyr::crossing(date = dates, triplet = stations) %>%
    dplyr::mutate(flavor = OUTLOOK_FLAVOR, n_valid = 30L, zig_shape = shape, zig_scale = scale, zig_p_zero = p_zero,
                  outlook_length = length_days, outlook_alpha = alpha)
  list(sm = sm, normals = normals, years = years)
}
probs <- unname(SNODAS_QUANTILES)
q_cols <- names(SNODAS_QUANTILES)

cat("Outlook\n")
# 1. No persistence: quantiles equal the normals (inner probabilities; 0 and 1 are read at z = +-4).
k <- make_case(2027L, length_days = 0.01)
o <- calc_station_outlook(k$sm, k$normals, k$years, tibble::tibble(triplet = "1:XX:SNTL", wteq = 2), as.Date("2026-12-01"))
row <- o[o$date == as.Date("2027-01-15"), ]
inner <- 2:18
# p_zero 0.01 is below half a reference year (0.5 / 30), so a station with snow uses 0.
ref <- zig_q(cbind(4, 5, 0), probs[inner], matrix(0, 1, 1))[1, ]
ok("rho ~ 0: quantiles = the normals' (to 0.1 in)", max(abs(unlist(row[q_cols[inner]]) - ref)) <= 0.051)

# 2. Full persistence: median stays at today's SWE.
k <- make_case(2027L, length_days = 1e6)
o <- calc_station_outlook(k$sm, k$normals, k$years, tibble::tibble(triplet = "1:XX:SNTL", wteq = 25), as.Date("2026-12-01"))
ok("rho ~ 1: median = today's SWE (to 0.1 in)", all(abs(o$q0500 - 25) <= 0.051))

# 3. Monotone quantiles, p_snow_free in [0, 1].
k <- make_case(2027L, length_days = 60)
obs <- tibble::tibble(triplet = c("1:XX:SNTL", "2:XX:SNTL"), wteq = c(0, 30))
o <- calc_station_outlook(k$sm, k$normals, k$years, obs, as.Date("2027-01-10"))
m <- as.matrix(o[q_cols])
ok("quantiles never decrease with probability", all(apply(m, 1, \(r) all(diff(r) >= -1e-9))))
ok("p_snow_free in [0, 1]", all(o$p_snow_free >= 0 & o$p_snow_free <= 1))

# 4. More snow today never lowers the outlook; a bare station starts at zero.
swe <- c(0, 0.1, 1, 5, 20, 40)
k <- make_case(2027L, length_days = 60, p_zero = 0.001)   # below half a year: floored for snowy stations
st <- paste0(seq_along(swe), ":XX:SNTL")
k2 <- make_case(2027L, length_days = 60, p_zero = 0.001, stations = st)
o <- calc_station_outlook(k2$sm, k2$normals, k2$years, tibble::tibble(triplet = st, wteq = swe), as.Date("2027-01-10"))
first <- o[o$date == as.Date("2027-01-11"), ][match(st, o$triplet[o$date == as.Date("2027-01-11")]), ]
ok("next day's median rises with today's SWE", all(diff(first$q0500) >= -1e-9))
ok("next day's p_snow_free falls with today's SWE", all(diff(first$p_snow_free) <= 1e-9))
ok("a bare station's next-day median is 0", first$q0500[1] == 0)

# 5. Far above the normals: the range starts at today's SWE.
k <- make_case(2027L, length_days = 60)
o <- calc_station_outlook(k$sm, k$normals, k$years, tibble::tibble(triplet = "1:XX:SNTL", wteq = 200), as.Date("2027-01-10"))
ok("record-high station: next day's median within 10% of today's", abs(o$q0500[1] / 200 - 1) < 0.1)

# 6. Leap year.
k <- make_case(2028L, length_days = 60)
o <- calc_station_outlook(k$sm, k$normals, k$years, tibble::tibble(triplet = "1:XX:SNTL", wteq = 10), as.Date("2028-02-01"))
ok("WY2028 outlook includes Feb 29", as.Date("2028-02-29") %in% o$date)
ok("issued Sep 30: no outlook", is.null(calc_station_outlook(k$sm, k$normals, k$years,
                                                             tibble::tibble(triplet = "1:XX:SNTL", wteq = 10), as.Date("2028-09-30"))))

# 7. beta widens a low start and fades with rho.
k <- make_case(2027L, length_days = 60)
low <- tibble::tibble(triplet = "1:XX:SNTL", wteq = 3)
w <- \(b, d) { o <- calc_station_outlook(k$sm, k$normals, k$years, low, as.Date("2027-01-10"), beta = b); r <- o[o$date == d, ]; r$q0900 - r$q0100 }
ok("beta > 0 widens a low start's range at 14 days", w(0.3, as.Date("2027-01-24")) > w(0, as.Date("2027-01-24")))
ok("beta's effect fades by 200 days", abs(w(0.3, as.Date("2027-07-28")) - w(0, as.Date("2027-07-28"))) <= 0.25)

cat(if (FAILED) "\nSOME TESTS FAILED\n" else "\nALL TESTS PASS\n")
quit(status = if (FAILED) 1L else 0L)
