# Station SWE normals: the mco-snodas zonal method applied to each station's
# own daily SWE record. A station is one series, as a watershed is in
# calc_zonal_normals(means = …), so the three flavors are fitted exactly as
# there. The methods are the normals package's (pinned in the Dockerfile),
# called with the arguments that reproduce mco-snotel's results before it
# (normals docs/API.md, sections 5 and 6.3):
#   ecdf        zero-inflated type-7 ECDF (empirical)
#   zig         zero-inflated gamma by L-moments (fitted)
#   zig_smooth  the daily ZIG's statistics smoothed over the water year with
#               cyclic P-splines (smoothed)
# The package names flavors and parameters by the spec (empirical, shape, …);
# normals_legacy() and calc_station_percentiles() map them to the published
# names here, at the edge.
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
# (snotel_min_valid()).
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

#' A period's reference years within a record (sm, from swe_record()).
normals_years <- function(sm, wy, period) {
  first <- normals::year_of(sm$origin, "wy")
  years <- period_years(wy, period, first_wy = first)
  years[years >= first]
}

#' The record as a normals::record_matrix(), stations as rows, sorted in C
#' (radix) order so they match the tables' order (dplyr::arrange() sorts
#' strings in C order).
#'
#' @param x triplet, date, wteq; one row per station and date.
swe_record <- function(x) {
  normals::record_matrix(x, "triplet", "date", "wteq",
                         subjects = sort(unique(x$triplet), method = "radix"))
}

# The normals package behind the tables, for provenance.json: its version and
# the commit it was installed from.
normals_version <- function() {
  d <- utils::packageDescription("normals")
  paste0(d$Version, if (!is.null(d$RemoteSha)) paste0(" (", d$RemoteSha, ")"))
}

# The minimum record for a normal: min(10, years in the period), counting
# every year of the period within the archive (normals docs/API.md, D3).
snotel_min_valid <- function(years) normals::min_valid_years(length(years), cap = 10L)

# Today's method choices, as normals arguments (normals docs/API.md, section 5):
# fitted and smoothed rows without a gamma fall back to the ECDF (D1), and the
# smoothed flavor is masked where the record is too short (D2).
SNOTEL_FALLBACK <- c(fitted = "empirical", smoothed = "empirical")

#' Normals for every station and date of water year wy in one period.
#'
#' @param sm swe_record() of the record before wy.
#' @return list(normals = one row per flavor x date x station, coef and
#'   diagnostics of the ZIG-smooth fit, years).
calc_station_normals <- function(sm, wy, period, cores = 1L) {
  years <- normals_years(sm, wy, period)
  message("  ", period, ": WY", min(years), "–", max(years), ", ", length(sm$subjects), " stations")

  subjects <- tibble::tibble(triplet = sm$subjects)
  res <- normals::normals_table(
    ref           = \(d) normals::reference_record(sm, d, years, "wy"),
    dates         = normals::year_dates(wy, "wy"),
    subjects      = subjects,
    family        = normals::family_zig(),
    year_type     = "wy",
    min_valid     = snotel_min_valid(years),
    fallback      = SNOTEL_FALLBACK,
    smoothed_mask = "min_valid",
    cores         = cores
  )
  side <- normals::smooth_tables(res$smooth, subjects)
  list(normals = normals_legacy(res$normals), coef = side$coef,
       diagnostics = side$diagnostics, years = years)
}

# The published (layout v0) names: flavors ecdf / zig / zig_smooth, parameters
# zig_shape / zig_scale / zig_p_zero; day, distribution and fit_status dropped.
normals_legacy <- function(x) {
  x$flavor <- normals::flavor_legacy(x$flavor, "legacy")
  dplyr::select(x, flavor, date, triplet, n_valid, ref_first_wy, ref_last_wy, mean,
                zig_shape = shape, zig_scale = scale, zig_p_zero = p_zero,
                dplyr::all_of(names(normals::NORMALS_QUANTILES)))
}

#' Percentiles of observed SWE against frozen normals, for one period.
#'
#' @param sm      swe_record() of the frozen reference record.
#' @param obs     triplet, date, wteq for the water year (any stations).
#' @param normals The period's normals table (calc_station_normals()$normals).
#' @param years   The period's reference years.
#' @return flavor, date, triplet, swe, swe_ptile (0-100, to 0.01) and
#'   swe_standardized (z, from the unrounded percentile), for every observed
#'   station and date; NULL when there are none.
calc_station_percentiles <- function(sm, obs, normals, years) {
  spec <- normals
  spec$flavor <- normals::flavor_legacy(spec$flavor, "spec")
  spec <- dplyr::rename(spec, shape = zig_shape, scale = zig_scale, p_zero = zig_p_zero)
  pc <- normals::percentiles_table(
    normals      = spec,
    ref          = \(d) normals::reference_record(sm, d, years, "wy"),
    subjects     = tibble::tibble(triplet = sm$subjects),
    obs          = dplyr::select(obs, triplet, date, value = wteq),
    family       = normals::family_zig(),
    min_valid    = snotel_min_valid(years),
    fallback     = SNOTEL_FALLBACK,
    ptile_digits = 2L
  )
  if (!nrow(pc)) return(NULL)
  pc$flavor <- normals::flavor_legacy(pc$flavor, "legacy")
  dplyr::select(pc, flavor, date, triplet, swe = value, swe_ptile = ptile,
                swe_standardized = standardized)
}
