#!/usr/bin/env Rscript
# Key-set harness: run a pipeline entry script against a stubbed S3 (a local
# directory) and log every object it reads, writes or deletes. Run it on two
# checkouts (e.g. origin/main and a branch) from the same seed and compare the
# logs (scripts/keyset/compare.sh) and the buckets (scripts/parity/diff.R).
#
#   Rscript scripts/keyset/harness.R <code> <seed> <run> <entry script>
#
#   code    the checkout to run (its R/, config/ and entry scripts)
#   seed    a bucket tree to start from (copied, read-only)
#   run     output: run/bucket (the bucket after the run), run/s3.log
#           (op, bucket, key, content type), and run/work (WORK_DIR) unless
#           HARNESS_WORK names another directory
#   entry   mco-snotel.R, normals-annual.R or viz.R, with its usual
#           environment variables (SNOTEL_DATE, WATER_YEAR, PERIODS, ...)
#
# Stubs, installed after the entry script's setup_pipeline():
#   - paws.storage::s3(): get, head, put, copy, delete and list on run/bucket;
#   - aws_s3(): `aws s3 sync <dir> s3://bucket/prefix` with --exclude and
#     --include filters, as the CLI applies them (last match wins);
#   - awdb_stations() and awdb_fetch_parts(): the seed's
#     stations/stations.parquet and archive/snotel.parquet (filtered to the
#     triplets and dates asked for), so no request leaves the machine;
#   - Sys.time() in the pipeline's own functions: HARNESS_TIME (default
#     2026-11-01T17:00:00Z), so two runs write the same timestamps.
# The seed paths are named by the harness, not the code under test, so the
# same harness runs code before and after the layout resolver.
#
# Any other AWS call fails: credentials and the endpoint are bogus.

# Everything is local, so the entry script's globals cannot clash with the
# harness's; only the stubs reach the global environment.
local({
  `%||%` <- function(a, b) if (is.null(a)) b else a
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 4) stop("Usage: harness.R <code> <seed> <run> <entry script>")
  code  <- normalizePath(args[1]); seed <- normalizePath(args[2])
  run   <- args[3]; entry <- args[4]
  seed_stations <- file.path(seed, "stations", "stations.parquet")
  seed_archive  <- file.path(seed, "archive", "snotel.parquet")

  dir.create(run, recursive = TRUE, showWarnings = FALSE)
  unlink(list.files(run, full.names = TRUE, all.files = TRUE, no.. = TRUE), recursive = TRUE)
  run    <- normalizePath(run)
  bucket <- file.path(run, "bucket")
  dir.create(bucket)
  file.copy(list.files(seed, full.names = TRUE), bucket, recursive = TRUE, copy.date = TRUE)
  log_file <- file.path(run, "s3.log")
  file.create(log_file)

  Sys.setenv(WORK_DIR = Sys.getenv("HARNESS_WORK", unset = file.path(run, "work")), KEEP_LOCAL = "false",
             AWS_ACCESS_KEY_ID = "harness", AWS_SECRET_ACCESS_KEY = "harness", AWS_SESSION_TOKEN = "",
             AWS_PROFILE = "", AWS_CONFIG_FILE = "/dev/null", AWS_SHARED_CREDENTIALS_FILE = "/dev/null",
             AWS_ENDPOINT_URL = "http://127.0.0.1:9", AWS_EC2_METADATA_DISABLED = "true")
  BUCKET_NAME <- Sys.getenv("HARNESS_BUCKET", unset = "mco-snotel")

  s3_log <- function(op, bucket_name, key, type = "") {
    if (!identical(bucket_name, BUCKET_NAME)) stop("Bucket ", bucket_name, ", expected ", BUCKET_NAME)
    cat(op, "\t", bucket_name, "\t", key, "\t", type %||% "", "\n", sep = "", file = log_file, append = TRUE)
  }
  obj <- function(key) file.path(bucket, key)
  missing_key <- function(key) stop(structure(class = c("http_404", "error", "condition"),
                                              list(message = paste("NoSuchKey:", key), call = NULL)))

  fake_s3 <- function(...) list(
    get_object = function(Bucket, Key, ...) {
      s3_log("GET", Bucket, Key)
      if (!file.exists(obj(Key))) missing_key(Key)
      list(Body = readBin(obj(Key), "raw", n = file.info(obj(Key))$size))
    },
    head_object = function(Bucket, Key, ...) {
      s3_log("HEAD", Bucket, Key)
      if (!file.exists(obj(Key))) missing_key(Key)
      list(ContentLength = file.info(obj(Key))$size)
    },
    put_object = function(Bucket, Key, Body = raw(), ContentType = NULL, ...) {
      s3_log("PUT", Bucket, Key, ContentType)
      dir.create(dirname(obj(Key)), recursive = TRUE, showWarnings = FALSE)
      writeBin(Body, obj(Key))
      invisible(list())
    },
    copy_object = function(Bucket, CopySource, Key, ...) {
      src_bucket <- sub("/.*$", "", CopySource); src <- sub("^[^/]*/", "", CopySource)
      s3_log("COPY_FROM", src_bucket, src)
      s3_log("COPY_TO", Bucket, Key)
      if (!file.exists(obj(src))) missing_key(src)
      dir.create(dirname(obj(Key)), recursive = TRUE, showWarnings = FALSE)
      file.copy(obj(src), obj(Key), overwrite = TRUE)
      invisible(list())
    },
    delete_object = function(Bucket, Key, ...) {
      s3_log("DELETE", Bucket, Key)
      unlink(obj(Key))
      invisible(list())
    },
    list_objects_v2 = function(Bucket, Prefix = "", ...) {
      s3_log("LIST", Bucket, Prefix)
      keys <- list.files(bucket, recursive = TRUE, all.files = TRUE)
      keys <- sort(keys[startsWith(keys, Prefix)])
      list(Contents = lapply(keys, \(k) list(Key = k, Size = file.info(obj(k))$size)), IsTruncated = FALSE)
    }
  )
  utils::assignInNamespace("s3", fake_s3, "paws.storage")

  # `aws s3 sync` from a local directory up to the bucket. Arguments arrive as
  # the pipeline builds them, shQuote()d.
  unquote <- function(x) sub("^'(.*)'$", "\\1", x)
  glob_rx <- function(g) paste0("^", gsub("\\?", ".", gsub("\\*", ".*", gsub("([.+^$(){}|\\[\\]\\\\])", "\\\\\\1", g))), "$")
  fake_aws_s3 <- function(args) {
    args <- unquote(args)
    if (args[1] != "sync" || !grepl("^s3://", args[3]) || grepl("^s3://", args[2]))
      stop("harness: unsupported aws s3 call: ", paste(args, collapse = " "))
    src <- args[2]
    dest <- sub("^s3://", "", args[3])
    dest_bucket <- sub("/.*$", "", dest)
    prefix <- sub("/+$", "", sub("^[^/]*/?", "", dest))
    rest <- args[-(1:3)]
    filters <- list(); type <- NULL; i <- 1L
    while (i <= length(rest)) {
      a <- rest[i]
      if (a %in% c("--exclude", "--include")) { filters[[length(filters) + 1L]] <- c(a, rest[i + 1L]); i <- i + 2L }
      else if (a == "--content-type") { type <- rest[i + 1L]; i <- i + 2L }
      else stop("harness: unsupported aws s3 sync option ", a)
    }
    rel <- sort(list.files(src, recursive = TRUE, all.files = TRUE))
    keep <- vapply(rel, \(f) {
      inc <- TRUE
      for (fl in filters) if (grepl(glob_rx(fl[2]), f)) inc <- fl[1] == "--include"
      inc
    }, logical(1))
    for (f in rel[keep]) {
      key <- if (nzchar(prefix)) paste0(prefix, "/", f) else f
      s3_log("SYNC_PUT", dest_bucket, key, type %||% "<guessed>")
      dir.create(dirname(obj(key)), recursive = TRUE, showWarnings = FALSE)
      file.copy(file.path(src, f), obj(key), overwrite = TRUE)
    }
    invisible(0L)
  }

  fake_awdb_stations <- function() arrow::read_parquet(seed_stations)
  fake_awdb_fetch_parts <- function(triplets, begin, end, dir, ...) {
    fs::dir_create(dir)
    # begin is one date, or one per station (the full refetch).
    want <- data.frame(triplet = triplets, begin = lubridate::as_date(begin))
    end <- lubridate::as_date(end)
    x <- arrow::open_dataset(seed_archive) |>
      dplyr::filter(triplet %in% !!triplets, date <= !!end) |>
      dplyr::inner_join(arrow::arrow_table(want), by = "triplet") |>
      dplyr::filter(date >= begin) |>
      dplyr::select(-begin) |>
      dplyr::compute()
    file <- file.path(dir, "part-0001.parquet")
    arrow::write_parquet(x, file)
    message("  (harness) AWDB stub: ", x$num_rows, " rows for ", length(triplets), " station(s)")
    invisible(file)
  }

  FROZEN <- as.POSIXct(Sys.getenv("HARNESS_TIME", unset = "2026-11-01T17:00:00Z"), format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

  install_stubs <- function() {
    assign("aws_s3", fake_aws_s3, envir = globalenv())
    assign("awdb_stations", fake_awdb_stations, envir = globalenv())
    assign("awdb_fetch_parts", fake_awdb_fetch_parts, envir = globalenv())
    assign("Sys.time", function() FROZEN, envir = globalenv())
  }

  # The entry script sources R/pipeline_setup.R and calls setup_pipeline(),
  # which sources R/*.R; the stubs go in after that.
  assign("source", function(file, ...) {
    base::source(file, ...)
    if (identical(file, "R/pipeline_setup.R")) {
      real_setup <- get("setup_pipeline", envir = globalenv())
      assign("setup_pipeline", function() { real_setup(); install_stubs() }, envir = globalenv())
    }
    invisible(NULL)
  }, envir = globalenv())

  setwd(code)
  message("harness: ", entry, " in ", code, "; bucket ", bucket)
  status <- tryCatch({ base::source(entry, local = globalenv()); 0L },
                     error = \(e) { message("harness: ", entry, " failed: ", conditionMessage(e)); 1L })
  message("harness: ", length(readLines(log_file)), " S3 operations logged to ", log_file)
  quit(status = status)
})
