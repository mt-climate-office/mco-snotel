#!/usr/bin/env Rscript
# Tests for the layout resolver (R/layout.R) and the layout files.
#
#   Rscript scripts/test_layout.R [--snotel-listing FILE] [--snodas-listing FILE]
#
# 1. layout_version 0 resolves every key in docs/path-inventory.md exactly as
#    today's code builds it: the code's own expressions (copied below with
#    their file:line) are evaluated over many values and compared, and real
#    keys from the buckets (listed 2026-11-01) round-trip through
#    layout_key() and layout_match().
# 2. Roles resolve to the reference years the code uses today.
# 3. The section 7 sketches of layout_version 1 (scripts/layout/) resolve
#    the section 10 examples, and v0 and v1 do not overlap.
# 4. Errors, the bucket and prefix overrides, and the CLI.
#
# With a listing (`aws s3 ls --recursive s3://mco-snotel/ > FILE`, read-only),
# every key in the bucket must belong to exactly one v0 artifact.
#
# Run from the repository root. mco-snodas's v0 file is config/layout-snodas.yml
# here until step 2B moves it; there it is config/layout.yml.

suppressPackageStartupMessages(library(lubridate))
source("R/layout.R")

args <- commandArgs(trailingOnly = TRUE)
opt <- function(name) { i <- match(name, args); if (!is.na(i)) args[i + 1L] }
snodas_file <- if (file.exists("config/layout-snodas.yml")) "config/layout-snodas.yml" else NULL
here_is_snodas <- file.exists("mco-snodas.R")
snotel_file <- if (here_is_snodas) NULL else "config/layout.yml"
if (here_is_snodas) snodas_file <- "config/layout.yml"

n_ok <- 0L; fails <- character()
check <- function(label, got, want) {
  if (identical(got, want)) n_ok <<- n_ok + 1L
  else fails <<- c(fails, sprintf("%s\n      got:  %s\n      want: %s", label,
                                  paste(format(got), collapse = " "), paste(format(want), collapse = " ")))
}
check_error <- function(label, expr, pattern) {
  msg <- tryCatch({ force(expr); "<no error>" }, error = conditionMessage)
  check(label, grepl(pattern, msg), TRUE)
  if (!grepl(pattern, msg)) message("  (", label, ": ", msg, ")")
}
for (v in c("LAYOUT_BUCKET", "S3_BUCKET", "LAYOUT_PREFIX", "LAYOUT_CONFIG")) Sys.unsetenv(v)

# A key and its round trip: layout_key(id, vars) == key, and layout_match(key)
# finds id with those variables.
roundtrip <- function(L, key, id, ...) {
  check(paste("key", id, key), layout_key(id, ..., layout = L), key)
  m <- layout_match(key, L)
  check(paste("match", key), m$artifact, id)
}
water_year <- function(d) { d <- as_date(d); year(d) + (month(d) >= 10) }


# ── mco-snotel, layout_version 0 ──────────────────────────────────────────────

if (!is.null(snotel_file)) {
  message("mco-snotel v0: ", snotel_file)
  L <- layout_load(snotel_file)

  # Today's builders, copied from the code (main f39fe56; outlook_key from
  # branch outlook). Constants: R/pipeline_setup.R:16-21.
  S3_KEY_STATIONS <- "stations/stations.parquet"; S3_KEY_ARCHIVE <- "archive/snotel.parquet"
  S3_KEY_STATE <- "cache/state.parquet"; S3_PREFIX_NORMALS <- "normals"
  S3_PREFIX_PLOTS <- "plots"; S3_PREFIX_LATEST <- "latest"
  normals_prefix <- function(period, wy) file.path(S3_PREFIX_NORMALS, period, paste0("wy", wy))           # stages.R:20
  reference_key  <- function(wy) file.path(S3_PREFIX_NORMALS, "reference", paste0("wy", wy, ".parquet"))  # stages.R:21
  observed_key   <- function(period, wy) file.path(S3_PREFIX_NORMALS, period, "observed", paste0("wy", wy, ".parquet"))  # stages.R:22
  outlook_key    <- function(period, date) file.path(S3_PREFIX_NORMALS, period, "outlook", paste0("wy", water_year(date)),
                                                     paste0(format(lubridate::as_date(date)), ".parquet"))  # outlook:stages.R:23

  check("subjects", layout_key("subjects", layout = L), S3_KEY_STATIONS)
  check("raw", layout_key("raw", layout = L), S3_KEY_ARCHIVE)
  check("cache state", layout_key("cache", file = "state.parquet", layout = L), S3_KEY_STATE)
  check("latest_subjects", layout_key("latest_subjects", layout = L),
        file.path(S3_PREFIX_LATEST, "stations.parquet"))                                                  # stages.R:309
  check("latest_manifest", layout_key("latest_manifest", layout = L), file.path(S3_PREFIX_LATEST, "manifest.json"))  # :339

  roles <- c("30yr", "snodas", "por")
  for (wy in 2025:2028) {
    check(paste("reference", wy), layout_key("reference", wy = wy, layout = L), reference_key(wy))
    for (p in roles) {
      out <- normals_prefix(p, wy)
      check(paste("normals folder", p, wy), layout_prefix("normals_table", role = p, wy = wy, slash = FALSE, layout = L), out)
      for (f in list(c("normals_table", "normals.parquet"), c("provenance", "provenance.json"),          # :115, :145
                     c("normals_coef", "zig_smooth_coef.parquet"), c("normals_diagnostics", "zig_smooth_diagnostics.parquet"),  # :116-117
                     c("normals_basis", "zig_smooth_basis.csv"), c("normals_model", "zig_smooth_model.json")))  # :124, :132
        check(paste(f[1], p, wy), layout_key(f[1], role = p, wy = wy, layout = L), file.path(out, f[2]))
      for (trip in c("901:MT:SNTL", "1000:OR:SNTL", "2170:AK:SNTL"))
        check(paste("by_station", p, wy, trip),
              layout_key("normals_by_subject", role = p, wy = wy, subject = gsub(":", "_", trip, fixed = TRUE), layout = L),
              file.path(out, "by_station", paste0(gsub(":", "_", trip, fixed = TRUE), ".parquet")))     # :120
      check(paste("percentiles", p, wy), layout_key("percentiles", role = p, wy = wy, layout = L), observed_key(p, wy))
      check(paste("latest percentiles", p), layout_key("latest_copy", artifact = "percentiles", role = p, layout = L),
            file.path(S3_PREFIX_LATEST, paste0("observed_", p, ".parquet")))                               # :311
      check(paste("latest outlook", p), layout_key("latest_copy", artifact = "outlook", role = p, layout = L),
            file.path(S3_PREFIX_LATEST, paste0("outlook_", p, ".parquet")))                                # outlook:stages.R:402
    }
  }
  for (d in as.list(as_date(c("2024-10-01", "2024-02-29", "2026-09-30", "2026-10-01", "2026-11-01")))) {
    out_root <- file.path(S3_PREFIX_PLOTS, format(d))                                                     # :208 (key part)
    check(paste("plots folder", d), layout_prefix("plot", date = d, slash = FALSE, layout = L), out_root)  # :290, :327
    check(paste("plot_index", d), layout_key("plot_index", date = d, layout = L), file.path(S3_PREFIX_PLOTS, format(d), "index.json"))  # :273
    for (p in roles) {
      check(paste("outlook", p, d), layout_key("outlook", role = p, date = d, layout = L), outlook_key(p, d))
      for (fl in c("ecdf", "zig", "zig_smooth")) {
        canon <- c(ecdf = "empirical", zig = "fitted", zig_smooth = "smoothed")[[fl]]
        want <- file.path(out_root, p, fl, "swe", "usdm", paste0("901_MT_SNTL", ".png"))                  # :248
        check(paste("plot", p, fl, d), layout_key("plot", date = d, role = p, flavor = canon, type = "swe",
                                                 subject = "901_MT_SNTL", layout = L), want)
        check(paste("plot (published flavor)", p, fl, d), layout_key("plot", date = d, role = p, flavor = fl, type = "swe",
                                                                     subject = "901_MT_SNTL", layout = L), want)
      }
    }
  }
  for (dir in c("", "archive/", "cache/", "latest/", "normals/", "plots/", "stations/"))
    check(paste("readme", dir), layout_key("readme", dir = dir, layout = L), paste0(dir, "README.md"))    # publish-bucket-readmes.sh:7

  # Real keys in s3://mco-snotel (aws s3 ls, 2026-11-01).
  roundtrip(L, "stations/stations.parquet", "subjects")
  roundtrip(L, "archive/snotel.parquet", "raw")
  roundtrip(L, "cache/state.parquet", "cache", file = "state.parquet")
  roundtrip(L, "normals/reference/wy2025.parquet", "reference", wy = 2025)
  roundtrip(L, "normals/snodas/wy2027/normals.parquet", "normals_table", role = "snodas", wy = 2027)
  roundtrip(L, "normals/por/wy2026/provenance.json", "provenance", role = "por", wy = 2026)
  roundtrip(L, "normals/30yr/wy2025/zig_smooth_coef.parquet", "normals_coef", role = "30yr", wy = 2025)
  roundtrip(L, "normals/snodas/wy2027/zig_smooth_diagnostics.parquet", "normals_diagnostics", role = "snodas", wy = 2027)
  roundtrip(L, "normals/snodas/wy2027/zig_smooth_basis.csv", "normals_basis", role = "snodas", wy = 2027)
  roundtrip(L, "normals/snodas/wy2027/zig_smooth_model.json", "normals_model", role = "snodas", wy = 2027)
  roundtrip(L, "normals/snodas/wy2027/by_station/1000_OR_SNTL.parquet", "normals_by_subject",
            role = "snodas", wy = 2027, subject = "1000_OR_SNTL")
  roundtrip(L, "normals/snodas/observed/wy2027.parquet", "percentiles", role = "snodas", wy = 2027)
  roundtrip(L, "plots/2026-10-31/snodas/zig_smooth/swe/usdm/1000_OR_SNTL.png", "plot",
            date = "2026-10-31", role = "snodas", flavor = "smoothed", type = "swe", subject = "1000_OR_SNTL")
  roundtrip(L, "plots/2026-10-31/index.json", "plot_index", date = "2026-10-31")
  roundtrip(L, "latest/stations.parquet", "latest_subjects")
  roundtrip(L, "latest/observed_snodas.parquet", "latest_copy", artifact = "percentiles", role = "snodas")
  roundtrip(L, "latest/manifest.json", "latest_manifest")
  roundtrip(L, "latest/README.md", "readme", dir = "latest/")
  roundtrip(L, "README.md", "readme", dir = "")
  m <- layout_match("plots/2026-10-31/snodas/zig_smooth/swe/usdm/1000_OR_SNTL.png", L)
  check("match vars", m$vars, list(date = "2026-10-31", role = "snodas", flavor = "zig_smooth", type = "swe",
                                   subject = "1000_OR_SNTL"))

  # Roles: R/normals.R period_years() and normals_years().
  e <- new.env(); sys.source("R/normals.R", envir = e, toplevel.env = e)
  for (wy in c(2000:2060)) for (p in roles) for (first in c(1930L, 1980L, 2010L)) {
    old <- e$period_years(wy, p, first_wy = first)
    # first > last: `:` counts down in today's code (e.g. 2010:2002 for por);
    # there are no reference years, and the resolver says so.
    old <- if (length(old) > 1 && old[1] > old[length(old)]) integer() else old[old >= first]
    check(paste("role years", p, wy, first), layout_role_years(p, wy, first_wy = first, layout = L), old)
  }
  check("snodas period 2027", layout_period("snodas", 2027, L)$period, "wy2004-2026")
  check("30yr period 2027", layout_period("30yr", 2027, L)$period, "wy1997-2026")
  check("por period 2027", layout_period("por", 2027, L)$period, "wypor-2026")
  check("roles 2027", layout_roles(2027, L), c("30yr", "snodas", "por"))
  check("flavors", layout_flavors(L), c("ecdf", "zig", "zig_smooth"))

  lst <- opt("--snotel-listing")
  if (!is.null(lst)) {
    keys <- utils::read.table(lst, colClasses = "character")$V4
    cls <- layout_classify(keys, L)
    message("  listing: ", length(keys), " keys; by artifact:")
    print(sort(table(cls, useNA = "ifany"), decreasing = TRUE))
    check("every snotel key in one artifact", sum(is.na(cls) | cls == "<several>"), 0L)
    if (any(is.na(cls))) message("  unmatched, e.g. ", paste(utils::head(keys[is.na(cls)], 5), collapse = " "))
  }
}


# ── mco-snodas, layout_version 0 ──────────────────────────────────────────────

if (!is.null(snodas_file)) {
  message("mco-snodas v0: ", snodas_file)
  S <- layout_load(snodas_file)

  # Today's builders, copied from mco-snodas main 9b45d74. Constants:
  # R/pipeline_setup.R:20-29, R/animate.R:14.
  S3_PREFIX_RAW <- "raw"; S3_PREFIX_COGS <- "cogs"; S3_PREFIX_NORMALS_GRIDDED <- "normals/gridded"
  S3_PREFIX_NORMALS_ZONAL_WBD <- "normals/zonal/wbd"; S3_PREFIX_NORMALS_BY_ZONE <- "normals/zonal/wbd/by_zone"
  S3_PREFIX_NORMALS_BUILD <- "normals/build"; S3_PREFIX_LATEST <- "latest"; S3_KEY_MANIFEST <- "manifest.parquet"
  S3_PREFIX_ANIMATIONS <- "animations"
  snodas_cog_filename <- function(date, short_name) paste0("snodas_", short_name, "_", format(date, "%Y%m%d"), ".tif")  # snodas_raw.R:180-182
  snodas_cog_key <- function(date, short_name) file.path(S3_PREFIX_COGS, format(date), snodas_cog_filename(date, short_name))  # :185-187
  tar_name <- function(d) paste0("SNODAS_", format(d, "%Y"), format(d, "%m"), format(d, "%d"), ".tar")  # snodas_raw.R:14
  normals_build_prefix <- function(wy) file.path(S3_PREFIX_NORMALS_BUILD, paste0("wy", wy))     # normals_annual.R:34
  strip_date <- function(k) sub("_\\d{8}(?=\\.)", "", sub("^\\d{4}-\\d{2}-\\d{2}_", "", basename(k)), perl = TRUE)  # stages.R:781-783
  vars <- c("precip_solid", "precip_solid_qc", "swe", "snow_depth", "snowpack_temp",
            "blowing_snow_sublim", "snow_melt", "snowpack_sublim")                                  # R/utils.R:18-28
  canon <- c(ecdf = "empirical", zig = "fitted", zig_smooth = "smoothed")

  check("raw_manifest", layout_key("raw_manifest", layout = S), S3_KEY_MANIFEST)
  for (k in c("dates_state.parquet", "normals_state.parquet", "data/snodas_mask.tif", "data/wbd_huc8.tif.aux.xml",
              "data/fgb/huc8.fgb", "plot_axes/wy2027_hypsomeswe.parquet"))
    check(paste("cache", k), layout_key("cache", file = k, layout = S), paste0("cache/", k))         # pipeline_setup.R:28-29, wbd.R, stages.R:507
  check("subjects", layout_key("subjects", layout = S), "cache/data/wbd_zones.parquet")               # wbd.R:253
  check("build current", layout_prefix("normals_build_current", slash = FALSE, layout = S),
        file.path(S3_PREFIX_NORMALS_BUILD, "current"))                                                 # normals_annual.R:160
  check("build current days", layout_key("normals_build_current", file = "days.json", layout = S),
        "normals/build/current/days.json")                                                             # normals-annual.tf:146
  for (wy in 2026:2028) {
    check(paste("build", wy), layout_prefix("normals_build", wy = wy, slash = FALSE, layout = S), normals_build_prefix(wy))
    check(paste("build suffstats", wy),
          layout_key("normals_build", wy = wy, file = sprintf("suffstats/rows_%04d/%s.parquet", 65L, "2026-10-01"), layout = S),
          file.path(normals_build_prefix(wy), "suffstats", sprintf("rows_%04d", 65L), "2026-10-01.parquet"))  # normals_annual.R:181-192
    mdir <- file.path(S3_PREFIX_NORMALS_GRIDDED, "zig_smooth", paste0("wy", wy))                       # normals_annual.R:434, stages.R:511
    for (f in list(c("normals_grid_coef", "zig_smooth_coef.tif"), c("normals_grid_diagnostics", "zig_smooth_diagnostics.tif"),
                   c("normals_grid_basis", "zig_smooth_basis.csv"), c("normals_grid_model", "zig_smooth_model.json"),
                   c("normals_grid_build", "build.json")))
      check(paste(f[1], wy), layout_key(f[1], wy = wy, layout = S), file.path(mdir, f[2]))
    for (ty in c("swe", "hypsomeswe")) for (z in c("10", "1001", "100100", "01010002"))
      check(paste("by_zone", wy, ty, z), layout_key("normals_by_subject", wy = wy, subject = z, type = ty, layout = S),
            file.path(S3_PREFIX_NORMALS_BY_ZONE, paste0("wy", wy), paste0(z, "_", ty, ".parquet")))    # normals_annual.R:348, :419
    check(paste("observed", wy), layout_key("percentiles", wy = wy, type = "swe", layout = S),
          file.path(S3_PREFIX_NORMALS_ZONAL_WBD, "observed", paste0("wy", wy, "_swe.parquet")))         # stages.R:432
    for (fl in names(canon)) {
      check(paste("animation", wy, fl), layout_key("animation", wy = wy, flavor = canon[[fl]], type = "hypsomeswe",
                                                   subject = "01010002", layout = S),
            file.path(S3_PREFIX_ANIMATIONS, paste0("wy", wy), fl, "hypsomeswe", "usdm", "01010002.mp4"))  # animate.R:183-186
      check(paste("animation_index", wy, fl), layout_key("animation_index", wy = wy, flavor = fl, layout = S),
            paste0(S3_PREFIX_ANIMATIONS, "/wy", wy, "/", fl, "/index.json"))                            # animate.R:212-214
    }
  }
  for (d in as.list(as_date(c("2003-09-30", "2024-02-29", "2026-10-01", "2026-11-01")))) {
    check(paste("raw_tar", d), layout_key("raw_tar", date = d, layout = S), file.path(S3_PREFIX_RAW, tar_name(d)))  # stages.R:116
    for (v in vars) check(paste("raw_cog", d, v), layout_key("raw_cog", date = d, var = v, layout = S), snodas_cog_key(d, v))
    check(paste("latest_raw", d), layout_key("latest_raw", var = "swe", layout = S),
          paste0(S3_PREFIX_LATEST, "/cogs/", strip_date(snodas_cog_key(d, "swe"))))                    # stages.R:802
    check(paste("plot_index", d), layout_key("plot_index", date = d, layout = S),
          paste0(paste0("plots/", format(d)), "/index.json"))                                           # stages.R:825, :750
    check(paste("plots folder", d), layout_prefix("plot", date = d, slash = FALSE, layout = S),
          paste0("plots/", format(d)))                                                                  # stages.R:748
    gridded <- \(flavor, file) file.path(S3_PREFIX_NORMALS_GRIDDED, flavor, d, paste0(d, file))        # stages.R:360
    for (fl in names(canon)) {
      stats <- c("mean", "quantiles", "median", if (fl != "ecdf") "params")
      for (st in stats) {
        k <- gridded(fl, paste0("_", fl, "_", st, ".tif"))                                             # calc_snodas_normals.R:95-124
        check(paste("normals_grid", d, fl, st), layout_key("normals_grid", date = d, flavor = canon[[fl]], stat = st, layout = S), k)
        check(paste("latest_grid", fl, st), layout_key("latest_grid", flavor = fl, stat = st, layout = S),
              paste0(S3_PREFIX_LATEST, "/cogs/", strip_date(k)))                                         # stages.R:805-811
      }
      for (st in c("ptile", "standardized")) {
        k <- gridded(fl, paste0("_", fl, "_swe_", st, ".tif"))                                         # calc_snodas_normals.R:175-207
        check(paste("percentile_grid", d, fl, st), layout_key("percentile_grid", date = d, flavor = fl, stat = st, layout = S), k)
        check(paste("latest_percentile_grid", fl, st), layout_key("latest_percentile_grid", flavor = fl, stat = st, layout = S),
              paste0(S3_PREFIX_LATEST, "/cogs/", strip_date(k)))
      }
      k <- gridded(fl, paste0("_", fl, "_provenance.json"))                                            # stages.R:361
      check(paste("provenance_grid", d, fl), layout_key("provenance_grid", date = d, flavor = fl, layout = S), k)
      check(paste("latest_grid_provenance", fl), layout_key("latest_grid_provenance", flavor = fl, layout = S),
            paste0(S3_PREFIX_LATEST, "/cogs/", strip_date(k)))
      zdir <- file.path(S3_PREFIX_NORMALS_ZONAL_WBD, fl, d)                                            # calc_zonal_normals.R:48-51
      for (ty in c("swe", "hypsomeswe")) {
        k <- file.path(zdir, paste0(d, "_", fl, "_", ty, "_normals.parquet"))                           # calc_zonal_normals.R:55-60, stages.R:437
        check(paste("normals_table_day", d, fl, ty), layout_key("normals_table_day", date = d, flavor = fl, type = ty, layout = S), k)
        check(paste("latest_normals_table_day", fl, ty), layout_key("latest_normals_table_day", flavor = fl, type = ty, layout = S),
              paste0(S3_PREFIX_LATEST, "/zonal/", strip_date(k)))                                        # stages.R:814-820
        for (h in c("01010002", "10"))
          check(paste("plot", d, fl, ty, h), layout_key("plot", date = d, flavor = fl, type = ty, subject = h, layout = S),
                file.path(file.path("plots", format(d)), fl, ty, "usdm", paste0(h, ".png")))            # stages.R:677, :703
      }
      k <- file.path(zdir, paste0(d, "_", fl, "_provenance.json"))                                     # calc_zonal_normals.R:343-345
      check(paste("provenance_day", d, fl), layout_key("provenance_day", date = d, flavor = fl, layout = S), k)
      check(paste("latest_provenance_day", fl), layout_key("latest_provenance_day", flavor = fl, layout = S),
            paste0(S3_PREFIX_LATEST, "/zonal/", strip_date(k)))
    }
    for (ty in c("swe", "hypsomeswe")) {
      k <- file.path(S3_PREFIX_NORMALS_ZONAL_WBD, "raw", d, paste0(d, "_raw_", ty, "_means.parquet"))  # calc_zonal_normals.R:53-54
      check(paste("means_day", d, ty), layout_key("means_day", date = d, type = ty, layout = S), k)
      check(paste("latest_means_day", ty), layout_key("latest_means_day", type = ty, layout = S),
            paste0(S3_PREFIX_LATEST, "/zonal/", strip_date(k)))
    }
  }
  check("latest_manifest", layout_key("latest_manifest", layout = S), paste0(S3_PREFIX_LATEST, "/manifest.json"))  # stages.R:835

  # Real keys in s3://mco-snodas (aws s3 ls, 2026-11-01).
  roundtrip(S, "raw/SNODAS_20261031.tar", "raw_tar", date = "2026-10-31")
  roundtrip(S, "cogs/2026-10-31/snodas_swe_20261031.tif", "raw_cog", date = "2026-10-31", var = "swe")
  roundtrip(S, "manifest.parquet", "raw_manifest")
  roundtrip(S, "normals/gridded/zig_smooth/2026-10-31/2026-10-31_zig_smooth_quantiles.tif", "normals_grid",
            date = "2026-10-31", flavor = "smoothed", stat = "quantiles")
  roundtrip(S, "normals/gridded/ecdf/2026-10-31/2026-10-31_ecdf_swe_ptile.tif", "percentile_grid",
            date = "2026-10-31", flavor = "empirical", stat = "ptile")
  roundtrip(S, "normals/gridded/zig/2026-10-31/2026-10-31_zig_provenance.json", "provenance_grid",
            date = "2026-10-31", flavor = "fitted")
  roundtrip(S, "normals/gridded/zig_smooth/wy2027/build.json", "normals_grid_build", wy = 2027)
  roundtrip(S, "normals/gridded/zig_smooth/wy2027/zig_smooth_coef.tif", "normals_grid_coef", wy = 2027)
  roundtrip(S, "normals/zonal/wbd/zig_smooth/2026-10-31/2026-10-31_zig_smooth_hypsomeswe_normals.parquet",
            "normals_table_day", date = "2026-10-31", flavor = "smoothed", type = "hypsomeswe")
  roundtrip(S, "normals/zonal/wbd/ecdf/2026-10-31/2026-10-31_ecdf_provenance.json", "provenance_day",
            date = "2026-10-31", flavor = "empirical")
  roundtrip(S, "normals/zonal/wbd/raw/2026-10-31/2026-10-31_raw_swe_means.parquet", "means_day",
            date = "2026-10-31", type = "swe")
  roundtrip(S, "normals/zonal/wbd/by_zone/wy2027/01010002_hypsomeswe.parquet", "normals_by_subject",
            wy = 2027, subject = "01010002", type = "hypsomeswe")
  roundtrip(S, "normals/zonal/wbd/observed/wy2027_swe.parquet", "percentiles", wy = 2027, type = "swe")
  roundtrip(S, "plots/2026-10-31/zig_smooth/hypsomeswe/usdm/01010002.png", "plot",
            date = "2026-10-31", flavor = "smoothed", type = "hypsomeswe", subject = "01010002")
  roundtrip(S, "plots/2026-10-31/index.json", "plot_index", date = "2026-10-31")
  roundtrip(S, "latest/cogs/snodas_swe.tif", "latest_raw", var = "swe")
  roundtrip(S, "latest/cogs/zig_smooth_quantiles.tif", "latest_grid", flavor = "smoothed", stat = "quantiles")
  roundtrip(S, "latest/cogs/zig_swe_standardized.tif", "latest_percentile_grid", flavor = "fitted", stat = "standardized")
  roundtrip(S, "latest/cogs/ecdf_provenance.json", "latest_grid_provenance", flavor = "empirical")
  roundtrip(S, "latest/zonal/zig_swe_normals.parquet", "latest_normals_table_day", flavor = "fitted", type = "swe")
  roundtrip(S, "latest/zonal/raw_hypsomeswe_means.parquet", "latest_means_day", type = "hypsomeswe")
  roundtrip(S, "latest/manifest.json", "latest_manifest")
  roundtrip(S, "cache/data/wbd_zones.parquet", "subjects")
  roundtrip(S, "cache/dates_state.parquet", "cache", file = "dates_state.parquet")
  roundtrip(S, "normals/build/current/days.json", "normals_build_current", file = "days.json")
  roundtrip(S, "animations/sy2026/zig_smooth/hypsomeswe/usdm/01010002.mp4", "animation_sy",
            wy = 2026, flavor = "smoothed", type = "hypsomeswe", subject = "01010002")
  roundtrip(S, "animations/sy2026/ecdf/index.json", "animation_index_sy", wy = 2026, flavor = "ecdf")
  roundtrip(S, "raw/tar/SNODAS_20260318.tar", "raw_tar_legacy", date = "2026-03-18")
  roundtrip(S, "raw/tar.manifest.parquet", "raw_tar_manifest_legacy")

  # Roles: the reference dates of the yearly build (normals_annual.R:125-128,
  # pipeline_sync.R:231-234): d minus 0..30 years, from 2003-09-30, before
  # d's water year. The role matches every day but Sep 30, whose record
  # reaches back to 2003-09-30 (WY2003): a day-level detail of the normals
  # method, not of the layout (docs/path-inventory.md).
  ref_wys <- function(d) {
    r <- d %m-% years(0:30); r <- r[r >= as_date("2003-09-30")]
    sort(unique(water_year(r[r < as_date(paste0(water_year(d) - 1L, "-10-01"))])))
  }
  for (wy in 2005:2045) for (md in c("10-01", "01-15", "02-29", "09-29", "09-30")) {
    y <- if (md >= "10-01") wy - 1L else wy
    d <- suppressWarnings(as_date(sprintf("%d-%s", y, md))); if (is.na(d)) next   # Feb 29, non-leap
    want <- ref_wys(d)
    if (md == "09-30" && wy <= 2033) want <- setdiff(want, 2003L)
    check(paste("snodas role years", d), layout_role_years("snodas", wy, layout = S), as.integer(want))
  }

  lst <- opt("--snodas-listing")
  if (!is.null(lst)) {
    keys <- utils::read.table(lst, colClasses = "character", fill = TRUE)$V4
    cls <- layout_classify(keys, S)
    message("  listing: ", length(keys), " keys; by artifact:")
    print(sort(table(cls, useNA = "ifany"), decreasing = TRUE))
    check("every snodas key in one artifact", sum(is.na(cls) | cls == "<several>"), 0L)
    if (any(is.na(cls))) message("  unmatched, e.g. ", paste(utils::head(keys[is.na(cls)], 10), collapse = " "))
  }
}


# ── layout_version 1 sketches (section 10 examples) ───────────────────────────

if (file.exists("scripts/layout/v1-snotel.yml")) {
  message("v1 sketches: scripts/layout/")
  T1 <- layout_load("scripts/layout/v1-snotel.yml")          # strict validation passes
  D1 <- layout_load("scripts/layout/v1-snodas.yml", validate = FALSE)

  # Spec problems the strict check finds in section 7's mco-snodas half; this
  # test fails when the spec is fixed, so the fixture and this list move together.
  check("v1 snodas known problems", sort(sub(":.*", "", layout_validate(D1, stop_on_error = FALSE))),
        sort(c("latest_grid", "normals_grid", "percentile_grid", "raw_tar")))
  check("v1 shared IDs", layout_check_shared(T1, D1),
        "subjects: file types differ (stations.parquet vs zonal/zones.fgb)")

  d <- "2027-02-01"; s <- "901_MT_SNTL"
  check("v1 roles 2027", vapply(layout_roles(2027, T1), \(r) layout_period(r, 2027, T1)$period, ""),
        c(snodas = "wy2004-2026", `30yr` = "wy1997-2026", noaa = "wy1991-2020", por = "wypor-2026"))
  roundtrip(T1, "stations.parquet", "subjects")
  roundtrip(T1, "raw/snotel_wy2027.parquet", "raw", wy = 2027)
  roundtrip(T1, "normals/wy2004-2026/normals_wy2004-2026.parquet", "normals_table", role = "snodas", wy = 2027)
  roundtrip(T1, "normals/wy2004-2026/reference_wy2004-2026.parquet", "reference", role = "snodas", wy = 2027)
  roundtrip(T1, "normals/wy2004-2026/provenance_wy2004-2026.json", "provenance", role = "snodas", wy = 2027)
  roundtrip(T1, "normals/wy2004-2026/by_station/901_MT_SNTL_wy2004-2026.parquet", "normals_by_subject",
            role = "snodas", wy = 2027, subject = s)
  for (r in c("30yr", "noaa", "por"))
    check(paste("v1 folder", r), layout_prefix("normals_table", role = r, wy = 2027, layout = T1),
          c(`30yr` = "normals/wy1997-2026/", noaa = "normals/wy1991-2020/", por = "normals/wypor-2026/")[[r]])
  roundtrip(T1, "daily/percentiles/wy2004-2026/percentiles_wy2004-2026_wy2027.parquet", "percentiles", role = "snodas", wy = 2027)
  roundtrip(T1, "daily/outlook/wy2004-2026/outlook_wy2004-2026_2027-02-01.parquet", "outlook", role = "snodas", date = d)
  roundtrip(T1, "daily/plots/wy2004-2026/2027-02-01/index_wy2004-2026_2027-02-01.json", "plot_index", role = "snodas", date = d)
  roundtrip(T1, "daily/plots/wy2004-2026/2027-02-01/smoothed/901_MT_SNTL_swe_wy2004-2026_smoothed_2027-02-01.png", "plot",
            role = "snodas", date = d, flavor = "smoothed", type = "swe", subject = s)
  # The same call as v0 (published flavor zig_smooth) gives the v1 name.
  check("v1 flavor mapping", layout_key("plot", role = "snodas", date = d, flavor = "zig_smooth", type = "swe",
                                        subject = s, layout = T1), layout_key("plot", role = "snodas", date = d,
                                        flavor = "smoothed", type = "swe", subject = s, layout = T1))
  roundtrip(T1, "daily/latest/manifest.json", "latest_manifest")
  for (r in c("snodas", "30yr", "noaa", "por"))
    roundtrip(T1, paste0("daily/latest/percentiles_", r, ".parquet"), "latest_copy", artifact = "percentiles", role = r)
  roundtrip(T1, "daily/latest/outlook_snodas.parquet", "latest_copy", artifact = "outlook", role = "snodas")

  roundtrip(D1, "raw/tar/SNODAS_20270201.tar", "raw_tar", date = d)
  roundtrip(D1, "raw/cog/2027-02-01/snodas_swe_2027-02-01.tif", "raw_cog", date = d, var = "swe")
  roundtrip(D1, "gridded/normals/wy2004-2026/smoothed/smoothed_wy2004-2026_02-01_quantiles.tif", "normals_grid",
            role = "snodas", date = d, flavor = "smoothed", stat = "quantiles")
  roundtrip(D1, "gridded/daily/percentiles/wy2004-2026/2027-02-01/smoothed_wy2004-2026_2027-02-01_ptile.tif",
            "percentile_grid", role = "snodas", date = d, flavor = "smoothed", stat = "ptile")
  roundtrip(D1, "gridded/daily/latest/manifest.json", "latest_manifest_grid")
  roundtrip(D1, "zonal/zones.fgb", "subjects")
  for (ty in c("swe", "hypsomeswe"))
    roundtrip(D1, paste0("zonal/normals/wy2004-2026/normals_", ty, "_wy2004-2026.parquet"), "normals_table",
              role = "snodas", wy = 2027, type = ty)
  roundtrip(D1, "zonal/normals/wy2004-2026/reference_swe_wy2004-2026.parquet", "reference", role = "snodas", wy = 2027, type = "swe")
  roundtrip(D1, "zonal/normals/wy2004-2026/provenance_wy2004-2026.json", "provenance", role = "snodas", wy = 2027)
  roundtrip(D1, "zonal/normals/wy2004-2026/by_zone/01010002_swe_wy2004-2026.parquet", "normals_by_subject",
            role = "snodas", wy = 2027, subject = "01010002", type = "swe")
  roundtrip(D1, "zonal/daily/means/means_swe_wy2027.parquet", "means", wy = 2027, type = "swe")
  roundtrip(D1, "zonal/daily/percentiles/wy2004-2026/percentiles_swe_wy2004-2026_wy2027.parquet", "percentiles",
            role = "snodas", wy = 2027, type = "swe")
  roundtrip(D1, "zonal/daily/plots/wy2004-2026/2027-02-01/smoothed/01010002_swe_wy2004-2026_smoothed_2027-02-01.png", "plot",
            role = "snodas", date = d, flavor = "smoothed", type = "swe", subject = "01010002")
  roundtrip(D1, "zonal/daily/latest/manifest.json", "latest_manifest")
  roundtrip(D1, "zonal/animations/wy2004-2026/wy2027/smoothed/01010002_hypsomeswe_wy2004-2026_smoothed_wy2027.mp4",
            "animation", role = "snodas", wy = 2027, flavor = "smoothed", type = "hypsomeswe", subject = "01010002")
  check("v1 snodas noaa absent 2041", is.null(layout_period("noaa", 2041, D1)), TRUE)
  check("v1 snodas noaa from 2042", layout_period("noaa", 2042, D1)$period, "wy2011-2040")
  check("v1 30yr = snodas in 2035", layout_period("30yr", 2035, D1)$period, layout_period("snodas", 2035, D1)$period)

  # v0 and v1 must not collide. cache/v1/ sits inside v0's cache/ prefix,
  # which v0 never writes under (plan step 3.0). In mco-snodas, one leftover
  # object (raw/tar/SNODAS_20260318.tar, raw_tar_legacy) already has a v1
  # raw_tar key; the history copy (step 3E) must expect it.
  ov_want <- list(snotel = "cache cache",
                  snodas = c("raw_tar_legacy raw_tar", "raw_tar raw_tar_legacy", "cache cache"))
  for (pair in list(list("snotel", snotel_file, T1), list("snodas", snodas_file, D1))) {
    if (is.null(pair[[2]])) next
    ov <- layout_overlaps(layout_load(pair[[2]]), pair[[3]])
    check(paste("v0/v1 overlaps", pair[[1]]), paste(ov$artifact, ov$other), ov_want[[pair[[1]]]])
  }
}


# ── Errors, overrides, CLI ────────────────────────────────────────────────────

L <- layout_load(snotel_file %||% snodas_file)
check_error("unknown artifact", layout_key("nope", layout = L), "No artifact 'nope'")
check_error("missing variable", layout_key("plot_index", layout = L), "needs \\{date\\}")
check_error("bad date", layout_key("plot_index", date = "2026-13-01", layout = L), "Not a date")
check_error("bad flavor", layout_key("plot", date = "2026-11-01", role = "snodas", flavor = "gamma", type = "swe",
                                     subject = "x", layout = L), "flavor")
check_error("subject with ':'", layout_key("plot", date = "2026-11-01", role = "snodas", flavor = "ecdf", type = "swe",
                                           subject = "901:MT:SNTL", layout = L), "subject")
check_error("prefix needs file", layout_key("cache", layout = L), "is a prefix")
check_error("no climbing out", layout_key("cache", file = "../x", layout = L), "Not a relative file")
check_error("unknown role", layout_period("decade", 2027, L), "Unknown role")
bad <- L; bad$layout_version <- 1
check("strict v1 rejects v0 names", length(layout_validate(bad, stop_on_error = FALSE)) > 0, TRUE)

Sys.setenv(S3_BUCKET = "mco-x-test")
check("S3_BUCKET alias", layout_bucket(L), "mco-x-test")
Sys.setenv(LAYOUT_BUCKET = "mco-y-test")
check("LAYOUT_BUCKET wins", layout_bucket(L), "mco-y-test")
base <- layout_key("latest_manifest", layout = L)
Sys.setenv(LAYOUT_PREFIX = "/shadow/run1/")
check("LAYOUT_PREFIX", layout_key("latest_manifest", layout = L), paste0("shadow/run1/", base))
Sys.setenv(LAYOUT_PREFIX = "shadow/run1")
check("uri", layout_uri("latest_manifest", layout = L), paste0("s3://mco-y-test/shadow/run1/", base))
check("match under prefix", layout_match(layout_key("latest_manifest", layout = L), L)$artifact, "latest_manifest")
check("root", layout_prefix(layout = L), "shadow/run1/")
for (v in c("LAYOUT_BUCKET", "S3_BUCKET", "LAYOUT_PREFIX")) Sys.unsetenv(v)
check("configured bucket", layout_bucket(L), L$bucket)

cli <- function(...) suppressWarnings(system2("Rscript", c("R/layout_cli.R", ...), stdout = TRUE, stderr = FALSE))
check("cli key", cli("key", "plot_index", "date=2026-11-01"), layout_key("plot_index", date = "2026-11-01", layout = L))
check("cli fails on a bad date", attr(cli("key", "plot_index", "date=x"), "status"), 1L)
check("cli cache file", cli("key", "cache", "file=state.parquet"), "cache/state.parquet")


message(sprintf("\n%d passed, %d failed", n_ok, length(fails)))
if (length(fails)) {
  message(paste0("FAIL ", utils::head(fails, 40), collapse = "\n"))
  quit(status = 1)
}
