#!/usr/bin/env Rscript
# Compare two trees of pipeline outputs object by object: a reference (e.g.
# production) and a candidate (e.g. a shadow run in the test bucket).
#
# Usage:
#   scripts/parity/diff.R --ref <tree> --cand <tree> [options]
#
# A tree is s3://bucket/prefix, a local directory, or a single object or file.
# Keys are compared relative to each tree's root.
#
# Options:
#   --keys FILE           Compare only these keys (one per line, relative to
#                         the roots; # comments and blank lines ignored).
#   --newer-than TIME     Fail candidate objects last modified before TIME
#                         (UTC, e.g. 2026-11-01T19:00:00Z): outputs the run
#                         should have rewritten but did not (see seed.sh).
#   --ignore-json-key K   Also ignore JSON key K (repeatable). Always ignored:
#                         updated, built_at, normals_version, pipeline.
#   --profile NAME        AWS CLI profile for s3:// trees (default: AWS_PROFILE).
#   --out FILE            Also write the table as TSV.
#   --cores N             Compare N objects at a time (default 1).
#
# Rules, by extension:
#   .tif   CRS, transform (origin, pixel size, dimensions), data type, nodata,
#          band count, band names and descriptions, overview count equal.
#          Integer pixels identical; floating-point pixels within 1e-6
#          relative (|a - b| <= 1e-6 * max(|a|, |b|)); nodata in the same
#          places. Reports the number of differing pixels and the largest error.
#   .parquet  Schema and row count equal; every non-floating column (keys,
#          integers, strings, dates) identical row by row, so row order and
#          keys must match; floating columns within 1e-9 relative, or exact
#          when the reference column is rounded (to at most 6 decimals).
#   .json  Parsed and compared with the ignored keys removed at every level.
#   .png   Decoded to RGBA; every value identical.
#   other  Byte-identical.
# Missing keys (in the reference only) and extra keys (in the candidate only)
# fail. Byte-identical objects are reported as such. Exit status is 0 only if
# every object passes.
#
# Needs terra, arrow, jsonlite and png (all in the pipeline images), and the
# AWS CLI for s3:// trees. Kept byte-identical in mco-snodas and mco-snotel
# (check-identical.sh).

suppressPackageStartupMessages({
  library(terra)
  library(arrow)
  library(jsonlite)
  library(png)
})

TIF_TOL     <- 1e-6
PARQUET_TOL <- 1e-9
JSON_IGNORE <- c("updated", "built_at", "normals_version", "pipeline")

# ── Arguments ─────────────────────────────────────────────────────────────────

usage <- function(status = 2) {
  lines <- readLines(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1]))
  cat(sub("^# ?", "", lines[2:(which(lines == "")[1] - 1)]), sep = "\n")
  quit(status = status)
}

parse_args <- function(a) {
  opt <- list(ref = NULL, cand = NULL, keys = NULL, newer_than = NULL, ignore = character(),
              profile = NULL, out = NULL, cores = 1L)
  i <- 1L
  val <- function() { if (i + 1L > length(a)) usage(); a[[i + 1L]] }
  while (i <= length(a)) {
    switch(a[[i]],
      "--ref"             = { opt$ref        <- val(); i <- i + 1L },
      "--cand"            = { opt$cand       <- val(); i <- i + 1L },
      "--keys"            = { opt$keys       <- val(); i <- i + 1L },
      "--newer-than"      = { opt$newer_than <- val(); i <- i + 1L },
      "--ignore-json-key" = { opt$ignore     <- c(opt$ignore, val()); i <- i + 1L },
      "--profile"         = { opt$profile    <- val(); i <- i + 1L },
      "--out"             = { opt$out        <- val(); i <- i + 1L },
      "--cores"           = { opt$cores      <- as.integer(val()); i <- i + 1L },
      "-h" = , "--help"   = usage(0),
      { message("Unknown argument: ", a[[i]]); usage() })
    i <- i + 1L
  }
  if (is.null(opt$ref) || is.null(opt$cand)) usage()
  opt
}

opt <- parse_args(commandArgs(TRUE))
if (!is.null(opt$profile)) Sys.setenv(AWS_PROFILE = opt$profile)
JSON_IGNORE <- unique(c(JSON_IGNORE, opt$ignore))
newer_than <- if (!is.null(opt$newer_than)) {
  t <- as.POSIXct(opt$newer_than, tz = "UTC", tryFormats = c("%Y-%m-%dT%H:%M:%OSZ", "%Y-%m-%dT%H:%M:%OS", "%Y-%m-%d %H:%M:%OS"))
  if (is.na(t)) stop("Cannot parse --newer-than ", opt$newer_than)
  t
}

# ── Trees ─────────────────────────────────────────────────────────────────────

aws <- function(args) {
  out <- suppressWarnings(system2("aws", shQuote(c(args, "--output", "json")), stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status"))) stop("aws ", paste(args, collapse = " "), " failed")
  out
}

# A tree: its keys (relative to the root), their last-modified times, and a
# function that returns a local path for a key (downloading S3 objects).
open_tree <- function(spec, cache) {
  if (startsWith(spec, "s3://")) {
    bucket <- sub("^s3://([^/]+).*$", "\\1", spec)
    prefix <- sub("^s3://[^/]+/?", "", spec)
    list_keys <- function(p) {
      j <- paste(aws(c("s3api", "list-objects-v2", "--bucket", bucket, "--prefix", p)), collapse = "\n")
      x <- if (nzchar(j)) jsonlite::fromJSON(j)$Contents
      if (is.null(x) || !length(x)) return(data.frame(Key = character(), LastModified = character()))
      x[!endsWith(x$Key, "/"), c("Key", "LastModified")]
    }
    objs <- list_keys(prefix)
    single <- nzchar(prefix) && !endsWith(prefix, "/") && nrow(objs) == 1L && objs$Key == prefix
    if (!single) {
      if (nzchar(prefix) && !endsWith(prefix, "/")) prefix <- paste0(prefix, "/")
      objs <- objs[startsWith(objs$Key, prefix), ]
    }
    root <- if (single) dirname(prefix) else sub("/$", "", prefix)
    rel  <- if (single) basename(prefix) else substring(objs$Key, nchar(prefix) + 1L)
    dir  <- file.path(cache, gsub("[^A-Za-z0-9._-]", "_", spec))
    list(
      spec = spec, keys = rel, single = single,
      mtime = stats::setNames(as.POSIXct(objs$LastModified, tz = "UTC", format = "%Y-%m-%dT%H:%M:%OS"), rel),
      # Download every wanted key: one sync for many keys, cp for a few.
      fetch_all = function(keys) {
        if (length(keys) > 20 && !single) {
          inc <- if (length(keys) < length(rel)) as.vector(rbind("--include", keys))
          system2("aws", shQuote(c("s3", "sync", paste0("s3://", bucket, "/", prefix), dir,
                                   if (length(inc)) c("--exclude", "*", inc), "--only-show-errors")))
        } else for (k in keys) {
          src <- if (single) spec else paste0("s3://", bucket, "/", prefix, k)
          system2("aws", shQuote(c("s3", "cp", src, file.path(dir, k), "--only-show-errors")))
        }
      },
      path = function(k) file.path(dir, k))
  } else {
    if (!file.exists(spec)) stop("No such file or directory: ", spec)
    single <- !dir.exists(spec)
    rel  <- if (single) basename(spec) else list.files(spec, recursive = TRUE, all.files = TRUE)
    rel  <- rel[basename(rel) != ".DS_Store"]
    base <- if (single) dirname(spec) else spec
    list(spec = spec, keys = rel, single = single,
         mtime = stats::setNames(as.POSIXct(file.mtime(file.path(base, rel)), tz = "UTC"), rel),
         fetch_all = function(keys) invisible(NULL),
         path = function(k) file.path(base, k))
  }
}

# ── Comparators: each returns list(ok, detail) ────────────────────────────────

fmt <- function(x) formatC(x, digits = 3, format = "g")

# GDAL's description of each band, and the georeferencing lines.
tif_info <- function(f) {
  d <- terra::describe(f)
  bands <- split(d, cumsum(grepl("^Band [0-9]+ ", d)))
  bands <- bands[vapply(bands, \(b) grepl("^Band [0-9]+ ", b[1]), logical(1))]
  band_info <- vapply(bands, \(b) {
    ov <- grep("^\\s*Overviews:", b, value = TRUE)
    paste(c(sub("^.*Type=([A-Za-z0-9]+).*$", "\\1", b[1]),
            trimws(grep("^\\s*(NoData Value|Description|Offset:)", b, value = TRUE)),
            paste("overviews:", if (length(ov)) length(strsplit(ov[1], ",")[[1]]) else 0L)),
          collapse = " | ")
  }, character(1))
  list(geo = grep("^(Size is|Origin =|Pixel Size =)", d, value = TRUE), bands = unname(band_info))
}

cmp_tif <- function(a, b) {
  ia <- tif_info(a); ib <- tif_info(b)
  ra <- terra::rast(a); rb <- terra::rast(b)
  bad <- character()
  if (!identical(terra::crs(ra), terra::crs(rb))) bad <- c(bad, "CRS differs")
  if (!identical(ia$geo, ib$geo) || !identical(as.vector(terra::ext(ra)), as.vector(terra::ext(rb))))
    bad <- c(bad, paste0("transform differs: ", paste(setdiff(c(ia$geo, ib$geo), intersect(ia$geo, ib$geo)), collapse = "; ")))
  if (terra::nlyr(ra) != terra::nlyr(rb)) bad <- c(bad, paste0("bands ", terra::nlyr(ra), " vs ", terra::nlyr(rb)))
  if (!identical(names(ra), names(rb))) bad <- c(bad, "band names differ")
  if (!identical(terra::datatype(ra), terra::datatype(rb)))
    bad <- c(bad, paste0("dtype ", paste(unique(terra::datatype(ra)), collapse = ","), " vs ",
                         paste(unique(terra::datatype(rb)), collapse = ",")))
  if (!identical(ia$bands, ib$bands)) {
    i <- which(ia$bands != ib$bands)[1]
    bad <- c(bad, if (length(ia$bands) == length(ib$bands) && !is.na(i))
      paste0("band ", i, " [", ia$bands[i], "] vs [", ib$bands[i], "]") else "band metadata differs")
  }
  if (length(bad)) return(list(ok = FALSE, detail = paste(bad, collapse = "; ")))

  is_int <- startsWith(terra::datatype(ra), "INT")
  n_diff <- 0; n_na <- 0; max_rel <- 0; max_abs <- 0
  terra::readStart(ra); terra::readStart(rb)
  on.exit({ terra::readStop(ra); terra::readStop(rb) }, add = TRUE)
  step <- max(1L, floor(4e6 / (terra::ncol(ra) * terra::nlyr(ra))))
  for (row in seq(1L, terra::nrow(ra), by = step)) {
    nr <- min(step, terra::nrow(ra) - row + 1L)
    va <- terra::readValues(ra, row, nr, mat = TRUE)
    vb <- terra::readValues(rb, row, nr, mat = TRUE)
    for (j in seq_len(ncol(va))) {
      x <- va[, j]; y <- vb[, j]
      na_x <- is.na(x); na_y <- is.na(y)
      n_na <- n_na + sum(na_x != na_y)
      both <- !na_x & !na_y
      x <- x[both]; y <- y[both]
      d <- abs(x - y)
      if (is_int[j]) {
        n_diff <- n_diff + sum(d != 0)
      } else {
        rel <- ifelse(d == 0, 0, d / pmax(abs(x), abs(y)))
        n_diff <- n_diff + sum(rel > TIF_TOL)
        if (length(rel)) max_rel <- max(max_rel, rel)
      }
      if (length(d)) max_abs <- max(max_abs, d)
    }
  }
  kind <- if (all(is_int)) "integer" else if (any(is_int)) "mixed" else "float"
  ok <- n_diff == 0 && n_na == 0
  list(ok = ok, detail = paste0(
    kind, " ", terra::nlyr(ra), " band(s), ", terra::ncol(ra), "x", terra::nrow(ra),
    if (n_na) paste0("; nodata differs at ", n_na, " px") else "",
    if (n_diff) paste0("; ", n_diff, " px differ") else "",
    if (max_abs > 0) paste0("; max abs ", fmt(max_abs), if (kind != "integer") paste0(", max rel ", fmt(max_rel))) else ""))
}

is_float_type <- function(t) t$ToString() %in% c("double", "float", "halffloat")

# Decimal places (0-6) the values are rounded to, or NA if none.
rounded_to <- function(x) {
  x <- x[is.finite(x)]
  if (!length(x)) return(0L)
  for (k in 0:6) {
    s <- x * 10^k
    if (all(abs(s - round(s)) <= 1e-9 * pmax(1, abs(s)))) return(k)
  }
  NA_integer_
}

cmp_parquet <- function(a, b) {
  ta <- arrow::read_parquet(a, as_data_frame = FALSE)
  tb <- arrow::read_parquet(b, as_data_frame = FALSE)
  if (!ta$schema$Equals(tb$schema)) {
    fa <- vapply(ta$schema$fields, \(f) f$ToString(), ""); fb <- vapply(tb$schema$fields, \(f) f$ToString(), "")
    return(list(ok = FALSE, detail = paste0("schema differs: ref only [", paste(setdiff(fa, fb), collapse = ", "),
                                            "] cand only [", paste(setdiff(fb, fa), collapse = ", "), "]",
                                            if (setequal(fa, fb)) " (column order)" else "")))
  }
  if (ta$num_rows != tb$num_rows)
    return(list(ok = FALSE, detail = paste0("rows ", ta$num_rows, " vs ", tb$num_rows)))
  bad <- character(); notes <- character()
  for (nm in names(ta)) {
    type <- ta$schema$GetFieldByName(nm)$type
    x <- as.vector(ta[[nm]]); y <- as.vector(tb[[nm]])
    if (is_float_type(type)) {
      na_x <- is.na(x); na_y <- is.na(y)
      k <- rounded_to(x)
      both <- !na_x & !na_y
      d <- abs(x[both] - y[both])
      rel <- ifelse(d == 0, 0, d / pmax(abs(x[both]), abs(y[both])))
      n <- sum(na_x != na_y) + if (is.na(k)) sum(rel > PARQUET_TOL) else sum(d != 0)
      if (n) bad <- c(bad, paste0(nm, ": ", n, " value(s) differ",
                                  if (!is.na(k)) paste0(" (rounded to ", k, " dp: exact)") else "",
                                  if (length(d) && max(d) > 0) paste0(", max rel ", fmt(max(rel))) else ""))
      else if (length(d) && max(d) > 0) notes <- c(notes, paste0(nm, " max rel ", fmt(max(rel))))
    } else {
      if (is.factor(x)) x <- as.character(x)
      if (is.factor(y)) y <- as.character(y)
      if (!identical(x, y)) {
        same <- if (is.atomic(x)) (x == y) | (is.na(x) & is.na(y)) else mapply(identical, x, y)
        same[is.na(same)] <- FALSE
        i <- which(!same)[1]
        bad <- c(bad, paste0(nm, ": ", sum(!same), " row(s) differ, first at row ", i))
      }
    }
  }
  list(ok = !length(bad), detail = paste0(ta$num_rows, " rows x ", ta$num_columns, " cols",
                                          if (length(bad)) paste0("; ", paste(bad, collapse = "; ")) else "",
                                          if (length(notes)) paste0("; within tolerance: ", paste(notes, collapse = ", ")) else ""))
}

strip_json <- function(x) {
  if (!is.list(x)) return(x)
  if (!is.null(names(x))) x <- x[!names(x) %in% JSON_IGNORE]
  lapply(x, strip_json)
}

# Path of the first difference between two parsed JSON values.
json_first_diff <- function(x, y, path = "") {
  if (identical(x, y)) return(NULL)
  if (is.list(x) && is.list(y) && identical(names(x), names(y)) && length(x) == length(y)) {
    keys <- if (is.null(names(x))) seq_along(x) else names(x)
    for (i in seq_along(x)) {
      r <- json_first_diff(x[[i]], y[[i]], paste0(path, "/", keys[i]))
      if (!is.null(r)) return(r)
    }
  }
  if (nchar(path)) path else "/"
}

cmp_json <- function(a, b) {
  x <- strip_json(jsonlite::read_json(a, simplifyVector = FALSE))
  y <- strip_json(jsonlite::read_json(b, simplifyVector = FALSE))
  if (identical(x, y)) list(ok = TRUE, detail = paste0("ignoring ", paste(JSON_IGNORE, collapse = ", ")))
  else list(ok = FALSE, detail = paste0("differs at ", json_first_diff(x, y)))
}

rgba <- function(f) {
  p <- png::readPNG(f)
  if (length(dim(p)) == 2L) dim(p) <- c(dim(p), 1L)
  h <- dim(p)[1]; w <- dim(p)[2]; ch <- dim(p)[3]
  one <- array(1, c(h, w, 1L))
  switch(ch,
    array(c(p, p, p, one), c(h, w, 4L)),
    array(c(p[, , 1], p[, , 1], p[, , 1], p[, , 2]), c(h, w, 4L)),
    array(c(p, one), c(h, w, 4L)),
    p)
}

cmp_png <- function(a, b) {
  x <- rgba(a); y <- rgba(b)
  if (!identical(dim(x), dim(y)))
    return(list(ok = FALSE, detail = paste0("size ", paste(dim(x)[2:1], collapse = "x"), " vs ", paste(dim(y)[2:1], collapse = "x"))))
  n <- sum(apply(x != y, c(1, 2), any))
  list(ok = n == 0, detail = paste0(dim(x)[2], "x", dim(x)[1], " RGBA", if (n) paste0("; ", n, " px differ") else ""))
}

cmp_bytes <- function(a, b) list(ok = FALSE, detail = "bytes differ")

compare_one <- function(key, pa, pb) {
  ext <- tolower(tools::file_ext(key))
  kind <- switch(ext, tif = , tiff = "cog", parquet = "parquet", json = "json", png = "png", "bytes")
  if (!file.exists(pa) || !file.exists(pb))
    return(data.frame(key = key, kind = kind, status = "FAIL", bytes = "",
                      detail = paste("could not read", if (!file.exists(pa)) "reference" else "candidate")))
  same_bytes <- unname(tools::md5sum(pa) == tools::md5sum(pb))
  # The rules decide; identical bytes are reported as a bonus.
  r <- if (same_bytes && kind == "bytes") list(ok = TRUE, detail = "")
       else tryCatch(switch(kind, cog = cmp_tif(pa, pb), parquet = cmp_parquet(pa, pb),
                            json = cmp_json(pa, pb), png = cmp_png(pa, pb), bytes = cmp_bytes(pa, pb)),
                     error = \(e) list(ok = FALSE, detail = paste("error:", conditionMessage(e))))
  data.frame(key = key, kind = kind, status = if (r$ok) "PASS" else "FAIL",
             bytes = if (same_bytes) "identical" else "differ", detail = r$detail)
}

# ── Main ──────────────────────────────────────────────────────────────────────

cache <- tempfile("parity-")
dir.create(cache)

ref  <- open_tree(opt$ref, cache)
cand <- open_tree(opt$cand, cache)

# One object against another: compare them whatever their names.
if (ref$single && cand$single && length(ref$keys) && length(cand$keys)) {
  k <- ref$keys
  cand <- local({ t <- cand; ck <- t$keys
    t$keys <- k; t$mtime <- stats::setNames(t$mtime, k)
    f <- t$fetch_all; p <- t$path
    t$fetch_all <- function(x) f(ck); t$path <- function(x) p(ck)
    t })
}

missing <- character()
ref_keys <- ref$keys; cand_keys <- cand$keys
if (!is.null(opt$keys)) {
  wanted <- trimws(readLines(opt$keys))
  wanted <- wanted[nzchar(wanted) & !startsWith(wanted, "#")]
  ref_keys  <- intersect(ref_keys, wanted)
  cand_keys <- intersect(cand_keys, wanted)
  missing   <- setdiff(wanted, union(ref_keys, cand_keys))
}

both <- intersect(ref_keys, cand_keys)
message("Comparing ", length(both), " object(s): ", opt$ref, " vs ", opt$cand)
ref$fetch_all(both)
cand$fetch_all(both)

rows <- parallel::mclapply(both, \(k) tryCatch(compare_one(k, ref$path(k), cand$path(k)),
                                               error = \(e) data.frame(key = k, kind = "", status = "FAIL", bytes = "",
                                                                       detail = paste("error:", conditionMessage(e)))),
                           mc.cores = max(1L, opt$cores), mc.preschedule = FALSE)
res <- do.call(rbind, c(list(data.frame(key = character(), kind = character(), status = character(),
                                        bytes = character(), detail = character())), rows))

if (!is.null(newer_than) && nrow(res)) {
  stale <- res$key[cand$mtime[res$key] < newer_than]
  i <- res$key %in% stale
  res$status[i] <- "FAIL"
  res$detail[i] <- paste0(res$detail[i], ifelse(nzchar(res$detail[i]), "; ", ""),
                          "not rewritten since ", format(newer_than, "%Y-%m-%dT%H:%M:%SZ"))
}

extra <- function(keys, status, detail)
  if (length(keys)) data.frame(key = keys, kind = "", status = status, bytes = "", detail = detail)
res <- rbind(res,
             extra(setdiff(ref_keys, cand_keys), "MISSING", "in the reference only"),
             extra(setdiff(cand_keys, ref_keys), "EXTRA", "in the candidate only"),
             extra(missing, "MISSING", "listed in --keys, in neither tree"))
res <- res[order(res$status == "PASS", res$key), ]

if (!is.null(opt$out)) utils::write.table(res, opt$out, sep = "\t", quote = FALSE, row.names = FALSE)

old <- options(width = 10000)
print(res, row.names = FALSE, right = FALSE)
options(old)
counts <- table(factor(res$status, c("PASS", "FAIL", "MISSING", "EXTRA")))
cat(sprintf("\n%d object(s): %s; %d byte-identical\n", nrow(res),
            paste(names(counts), counts, sep = " ", collapse = ", "), sum(res$bytes == "identical")))
pass <- nrow(res) > 0 && all(res$status == "PASS")
cat(if (pass) "PARITY: PASS\n" else "PARITY: FAIL\n")
unlink(cache, recursive = TRUE)
quit(status = if (pass) 0L else 1L)
