# Vendored from mco-snodas@62fe19a R/utils.R (from SNODAS_QUANTILES on; the
# SNODAS product registry is left out). Do not edit here: change it upstream,
# then copy it back (see README, "Vendored code").

# Quantile probabilities for all SWE normals. Names are
# sprintf("q%04d", round(p * 1000)), which sort naturally (0.025 → "q0025",
# 1.0 → "q1000"). unname() gives the probabilities, names() the column names.
SNODAS_QUANTILES <- local({
  p <- c(0.0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5,
         0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1.0)
  setNames(p, sprintf("q%04d", round(p * 1000)))
})

# Make "Helvetica" available to the plots. macOS has it; on Linux (Docker),
# Nimbus Sans from fonts-urw-base35 is registered under that name.
register_snodas_fonts <- function() {
  if (any(systemfonts::system_fonts()$family == "Helvetica")) {
    return(invisible(NULL))
  }

  nimbus <- systemfonts::system_fonts() %>%
    dplyr::filter(family == "Nimbus Sans")

  if (nrow(nimbus) == 0L) {
    warning(
      "Helvetica not found and Nimbus Sans not available; ",
      "font rendering may differ from macOS. ",
      "Install fonts-urw-base35 to fix this."
    )
    return(invisible(NULL))
  }

  get_path <- function(style) {
    p <- nimbus$path[nimbus$style == style]
    if (length(p) == 0L) nimbus$path[[1L]] else p[[1L]]
  }

  systemfonts::register_font(
    name       = "Helvetica",
    plain      = get_path("Regular"),
    bold       = get_path("Bold"),
    italic     = get_path("Oblique"),
    bolditalic = get_path("Bold Oblique")
  )

  invisible(NULL)
}

# All dates from the start of the water year (Oct 1) through date.
water_year_dates <- function(date = Sys.Date()) {
  date <- lubridate::as_date(date)
  seq(water_year_start(date), date, by = "day")
}

# Water year of a date: Oct 1 – Sep 30, named for the year it ends in
# (2027 starts 2026-10-01), as USGS and NRCS SNOTEL use. SNODAS begins
# 2003-09-30, so WY2004 is the first complete year.
water_year <- function(date) {
  date <- lubridate::as_date(date)
  lubridate::year(date) + as.integer(lubridate::month(date) >= 10)
}

# First day (Oct 1) of the water year containing date.
water_year_start <- function(date) {
  lubridate::make_date(water_year(date) - 1L, 10, 1)
}

# Every normals date in water year wy: Oct 1 of wy - 1 through Sep 30 of wy.
normals_dates <- function(wy) {
  seq(lubridate::make_date(wy - 1L, 10, 1), lubridate::make_date(wy, 9, 30), by = "day")
}

# Position of each date on the 365-day annual cycle used by the ZIG-smooth
# normals (Oct 1 = 1, Sep 30 = 365). Feb 29 falls halfway between Feb 28 and
# Mar 1 (151.5), so leap and non-leap water years share one cycle.
normals_cycle_day <- function(date) {
  date  <- lubridate::as_date(date)
  start <- water_year_start(date)
  pos   <- as.numeric(date - start) + 1
  feb29 <- lubridate::make_date(water_year(date), 2, 29)   # NA in non-leap years
  leap  <- !is.na(feb29)
  pos[leap & date >  feb29[leap]] <- pos[leap & date > feb29[leap]] - 1
  pos[leap & date == feb29[leap]] <- pos[leap & date == feb29[leap]] - 0.5
  pos
}

# Write a JSON sidecar listing the reference dates behind a date's normals.
# Callers write one per flavor as {date}_{flavor}_provenance.json in the
# flavor's output directory.
write_provenance <- function(path, normals_date, flavor, reference_dates) {
  prov <- list(
    normals_date      = format(normals_date),
    flavor            = flavor,
    computed_at       = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    n_reference_years = length(reference_dates),
    reference_dates   = format(sort(reference_dates))
  )
  writeLines(jsonlite::toJSON(prov, auto_unbox = TRUE, pretty = TRUE), path)
}
