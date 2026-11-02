#!/usr/bin/env Rscript
# Tests of scripts/layout/v0-to-v1.R on small fixture layouts (no bucket):
# roles mixed in one chunk, one key to several keys with their own variables,
# skips, later keys, and the failures it must report.
#
#   Rscript scripts/layout/test-v0-to-v1.R
#
# Kept byte-identical in mco-snotel and mco-snodas.

this <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
tool <- file.path(dirname(normalizePath(this)), "v0-to-v1.R")
dir <- tempfile("v0-to-v1-test-"); dir.create(dir)
w <- function(name, ...) { f <- file.path(dir, name); writeLines(c(...), f); f }

v0 <- w("v0.yml",
  "layout_version: 0", "bucket: test", "year_type: wy",
  "roles:", "  snodas: {rule: rolling, length: 30, earliest: 2004}", "  30yr: {rule: rolling, length: 30}",
  "flavors: {empirical: ecdf, fitted: zig, smoothed: zig_smooth}",
  "values:", "  stat: {swe_ptile: ptile}",
  "artifacts:",
  "  table: {template: \"normals/{role}/wy{wy}/table.parquet\", cache: long}",
  "  reference: \"normals/reference/wy{wy}.parquet\"",
  "  grid: {template: \"grid/{flavor}/{date}/{date}_{flavor}_{stat}.tif\", cache: long}",
  "  old: {template: \"old/{date}.txt\", cache: long}",
  "  cache: \"cache/\"")
v1 <- w("v1.yml",
  "layout_version: 1", "bucket: test", "year_type: wy",
  "roles:", "  snodas: {rule: rolling, length: 30, earliest: 2004}", "  30yr: {rule: rolling, length: 30}",
  "flavors: [empirical, fitted, smoothed]",
  "artifacts:",
  "  normals_table: \"normals/{period}/normals_{period}.parquet\"",
  "  reference: \"normals/{period}/reference_{period}.parquet\"",
  "  normals_grid: \"grid/{period}/{flavor}/{period}_{flavor}_{day}_{stat}.tif\"",
  "  cache: \"cache/v1/\"")
rules <- w("rules.yml",
  "table: {to: normals_table, when: all}",
  "reference: {to: [{id: reference, vars: {role: snodas}}, {id: reference, vars: {role: 30yr}}], when: current}",
  "grid: {to: normals_grid, vars: {role: snodas}, when: current}",
  "old: {skip: \"legacy\"}",
  "cache: {to: cache, when: all}")
listing <- w("listing.txt",
  "2026-11-01 10:00:00       10 normals/snodas/wy2027/table.parquet",
  "2026-11-01 10:00:00       10 normals/30yr/wy2027/table.parquet",
  "2026-11-01 10:00:00       10 normals/snodas/wy2026/table.parquet",
  "2026-11-01 10:00:00       10 normals/30yr/wy2026/table.parquet",
  "2026-11-01 10:00:00       10 normals/reference/wy2027.parquet",
  "2026-11-01 10:00:00       10 normals/reference/wy2026.parquet",
  "2026-11-01 10:00:00       10 grid/zig_smooth/2026-11-01/2026-11-01_zig_smooth_ptile.tif",
  "2026-11-01 10:00:00       10 grid/ecdf/2025-11-01/2025-11-01_ecdf_mean.tif",
  "2026-11-01 10:00:00       10 old/2026-01-01.txt",
  "2026-11-01 10:00:00       10 cache/state with space.parquet")

run <- function(..., listing_file = listing) {
  out <- file.path(dir, "out")
  unlink(paste0(out, c(".tsv", ".skipped.tsv", ".summary.tsv")))
  st <- suppressWarnings(system2("Rscript", c(tool, "--listing", listing_file, "--v0", v0, "--v1", v1,
                                              "--rules", rules, "--out", out, ...), stdout = TRUE, stderr = TRUE))
  read <- \(f) if (file.exists(f) && file.size(f) > 0)
    utils::read.delim(f, header = FALSE, col.names = c("a", "b"), stringsAsFactors = FALSE, quote = "")
  list(status = attr(st, "status") %||% 0L, log = st,
       copies = read(paste0(out, ".tsv")), skipped = read(paste0(out, ".skipped.tsv")))
}
`%||%` <- function(a, b) if (is.null(a)) b else a
fails <- 0L
check <- function(what, ok) {
  ok <- isTRUE(all(ok)); cat(if (ok) "ok  " else "FAIL", what, "\n")
  if (!ok) fails <<- fails + 1L
}

r <- run("--wy", "2027", "--chunk", "4"); if (r$status != 0) cat(r$log, sep = "\n")
cp <- stats::setNames(r$copies$b, r$copies$a)
check("exit 0", r$status == 0)
# Mixed roles in one chunk: each row gets its own role's period.
check("snodas wy2027", cp["normals/snodas/wy2027/table.parquet"] == "normals/wy2004-2026/normals_wy2004-2026.parquet")
check("30yr wy2027", cp["normals/30yr/wy2027/table.parquet"] == "normals/wy1997-2026/normals_wy1997-2026.parquet")
check("snodas wy2026", cp["normals/snodas/wy2026/table.parquet"] == "normals/wy2004-2025/normals_wy2004-2025.parquet")
check("30yr wy2026", cp["normals/30yr/wy2026/table.parquet"] == "normals/wy1996-2025/normals_wy1996-2025.parquet")
# One key to several keys with their own variables.
ref <- r$copies$b[r$copies$a == "normals/reference/wy2027.parquet"]
check("reference to each role", setequal(ref, c("normals/wy2004-2026/reference_wy2004-2026.parquet",
                                               "normals/wy1997-2026/reference_wy1997-2026.parquet")))
# Flavor and value renames, day from date.
check("grid", cp["grid/zig_smooth/2026-11-01/2026-11-01_zig_smooth_ptile.tif"] ==
        "grid/wy2004-2026/smoothed/wy2004-2026_smoothed_11-01_swe_ptile.tif")
check("cache file with a space", cp["cache/state with space.parquet"] == "cache/v1/state with space.parquet")
sk <- stats::setNames(r$skipped$b, r$skipped$a)
check("skip", sk["old/2026-01-01.txt"] == "legacy")
check("later: earlier water year", grepl("^later", sk["grid/ecdf/2025-11-01/2025-11-01_ecdf_mean.tif"]) &&
        grepl("^later", sk["normals/reference/wy2026.parquet"]))
check("every key copied or skipped", length(unique(c(r$copies$a, r$skipped$a))) == 10L)

r <- run("--wy", "2027", "--scope", "all")
check("--scope all maps later keys", r$status == 0 && nrow(r$copies) == 11L && nrow(r$skipped) == 1L)

dup <- w("dup.txt", readLines(listing), "2026-11-01 10:00:00       10 normals/snodas/wy2027/table.parquet")
r <- run("--wy", "2027", listing_file = dup)
check("shared destination fails", r$status != 0 && any(grepl("shared by two sources", r$log)))
unk <- w("unk.txt", "2026-11-01 10:00:00       10 nowhere/x.txt")
r <- run("--wy", "2027", listing_file = unk)
check("unclassified key fails", r$status != 0 && any(grepl("unclassified", r$log)))

if (!fails) unlink(dir, recursive = TRUE)
if (fails) { cat(fails, "failure(s)\n"); quit(status = 1) }
cat("all passed\n")
