#!/usr/bin/env Rscript
# The layout resolver (R/layout.R) for shell scripts.
#
#   Rscript R/layout_cli.R key <artifact> [k=v ...] [file=<name>]   one key
#   Rscript R/layout_cli.R uri <artifact> [k=v ...]                  s3://bucket/key
#   Rscript R/layout_cli.R prefix [<artifact> [k=v ...]]             a folder, with "/"
#   Rscript R/layout_cli.R keys <artifact> [k=v1,v2 ...]             every combination
#   Rscript R/layout_cli.R match <key> ...                           artifact and variables
#   Rscript R/layout_cli.R bucket
#   Rscript R/layout_cli.R period <role> <wy>                        e.g. wy2004-2026
#   Rscript R/layout_cli.R roles [<wy>]
#   Rscript R/layout_cli.R artifacts                                  tab-separated table
#   Rscript R/layout_cli.R validate [<layout.yml>]
#
# e.g. Rscript R/layout_cli.R key plot_index date=2026-11-01
#
# The layout file is LAYOUT_CONFIG, else config/layout.yml in this repository.
# LAYOUT_BUCKET / S3_BUCKET and LAYOUT_PREFIX apply as in R/layout.R. Exits 1
# with the reason on stderr if a key cannot be made.
#
# Kept byte-identical in mco-snotel and mco-snodas. setup_pipeline() sources
# every R/*.R, so this file does nothing unless run as a script.

if (sys.nframe() == 0L) local({
  this <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
  here <- dirname(normalizePath(this))
  source(file.path(here, "layout.R"))
  if (!nzchar(Sys.getenv("LAYOUT_CONFIG")))
    Sys.setenv(LAYOUT_CONFIG = file.path(dirname(here), "config", "layout.yml"))

  args <- commandArgs(trailingOnly = TRUE)
  usage <- function() {
    lines <- readLines(this)
    cat(sub("^# ?", "", lines[2:(which(lines == "")[1] - 1L)]), sep = "\n", file = stderr())
    quit(status = 2)
  }
  if (!length(args)) usage()
  cmd <- args[1]; rest <- args[-1]

  # k=v pairs; v may be a comma-separated list for `keys`.
  kv <- function(x, split = FALSE) {
    bad <- !grepl("^[a-z_]+=", x)
    if (any(bad)) stop("Expected k=v, got: ", paste(x[bad], collapse = " "))
    vals <- sub("^[a-z_]+=", "", x)
    vals <- if (split) strsplit(vals, ",", fixed = TRUE) else as.list(vals)
    stats::setNames(vals, sub("=.*$", "", x))
  }

  out <- tryCatch(switch(cmd,
    key    = { v <- kv(rest[-1]); do.call(layout_key, c(list(rest[1]), v)) },
    uri    = { v <- kv(rest[-1]); do.call(layout_uri, c(list(rest[1]), v)) },
    prefix = if (length(rest)) do.call(layout_prefix, c(list(rest[1]), kv(rest[-1]))) else layout_prefix(),
    keys   = do.call(layout_keys, c(list(rest[1]), kv(rest[-1], split = TRUE))),
    match  = vapply(rest, \(k) {
      m <- layout_match(k)
      if (is.null(m)) paste0(k, "\t-") else
        paste0(k, "\t", m$artifact, "\t", paste0(names(m$vars), "=", unlist(m$vars), collapse = " "))
    }, ""),
    bucket = layout_bucket(),
    period = { p <- layout_period(rest[1], rest[2]); if (is.null(p)) stop("No period for ", rest[1], " in ", rest[2]); p$period },
    roles  = layout_roles(if (length(rest)) rest[1]),
    artifacts = {
      a <- layout_artifacts()
      c(paste(names(a), collapse = "\t"), apply(a, 1, paste, collapse = "\t"))
    },
    validate = {
      l <- layout_load(if (length(rest)) rest[1] else layout_config_path())
      paste0("ok: ", l$source, " (layout_version ", l$layout_version, ", ", nrow(l$artifacts), " artifacts)")
    },
    usage()),
    error = function(e) { message("layout_cli: ", conditionMessage(e)); quit(status = 1) })
  writeLines(as.character(out))
})
