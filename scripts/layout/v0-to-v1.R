#!/usr/bin/env Rscript
# Map a bucket listing from layout_version 0 to layout_version 1: the list of
# server-side copies (src, dst) that move history into v1 names
# (docs/bucket-layout.md section 13; v1 contract section 12).
#
# Usage:
#   Rscript scripts/layout/v0-to-v1.R --listing FILE --wy WY [options]
#
#   --listing FILE  `aws s3 ls --recursive s3://<bucket>/` output (or one key
#                   per line). Read in chunks, so a listing of millions of keys
#                   is never in memory at once.
#   --wy WY         The current water year: rules with `when: current` copy
#                   only keys of this water year today.
#   --scope S       today (default) or all: all also maps `later` keys.
#   --v0 FILE       Default config/layout.yml.
#   --v1 FILE       Default config/layout-v1.yml.
#   --rules FILE    Default scripts/layout/v0-to-v1.yml.
#   --out PREFIX    Writes PREFIX.tsv (src<TAB>dst), PREFIX.skipped.tsv
#                   (src<TAB>reason) and PREFIX.summary.tsv (counts per v0
#                   artifact). Default v0-to-v1.
#   --chunk N       Keys per chunk (default 500000).
#
# Every key must map or be skipped with a reason. The rules file holds one
# entry per v0 artifact ID:
#   <id>: {to: <v1 id> or [<v1 id>, ...], vars: {<variable>: <value>, ...},
#          when: all | current | later}
#   <id>: {to: [{id: <v1 id>, vars: {...}}, ...], vars: {...}, when: ...}
#         (one v0 key to several v1 keys with different variables, e.g. one
#         per role; a target's vars add to and override the rule's)
#   <id>: {skip: "<reason>"}
# A v1 key is filled from the v0 key's variables: wy, day and compact_date
# from date (or date from compact_date), period from role and wy (section 5),
# flavor by its canonical name, and other variables through the v0 layout's
# `values` map back to their canonical spelling; `vars` adds or overrides. A
# prefix artifact (cache/) keeps the part of the key under it.
#
# Exits 1 if a key matches no v0 artifact, has no rule, maps to a key that does
# not classify as the intended v1 artifact, or if two sources share a
# destination. Kept byte-identical in mco-snotel and mco-snodas.

suppressPackageStartupMessages(library(yaml))

args <- commandArgs(trailingOnly = TRUE)
opt <- list(listing = NULL, wy = NULL, scope = "today", v0 = "config/layout.yml",
            v1 = "config/layout-v1.yml", rules = "scripts/layout/v0-to-v1.yml",
            out = "v0-to-v1", chunk = 500000L)
i <- 1L
while (i <= length(args)) {
  k <- sub("^--", "", args[i])
  if (!k %in% names(opt) || i == length(args)) stop("Unknown or incomplete option: ", args[i])
  opt[[k]] <- args[i + 1L]; i <- i + 2L
}
if (is.null(opt$listing) || is.null(opt$wy)) stop("--listing and --wy are required")
if (!opt$scope %in% c("today", "all")) stop("--scope is today or all")
opt$chunk <- as.integer(opt$chunk); opt$wy <- as.integer(opt$wy)

this <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])
Sys.unsetenv(c("LAYOUT_PREFIX"))
source(file.path(dirname(normalizePath(this)), "..", "..", "R", "layout.R"))
L0 <- layout_load(opt$v0)
L1 <- layout_load(opt$v1)
rules <- yaml::read_yaml(opt$rules)

bad <- setdiff(names(rules), L0$artifacts$id)
if (length(bad)) stop("Rules for unknown v0 artifacts: ", paste(bad, collapse = ", "))
miss <- setdiff(L0$artifacts$id, names(rules))
if (length(miss)) stop("No rule for v0 artifacts: ", paste(miss, collapse = ", "))
# Targets of a rule: a list of list(id, vars).
targets <- function(r) lapply(if (is.list(r$to)) r$to else as.list(r$to), \(t) {
  if (is.list(t)) list(id = t$id, vars = utils::modifyList(r$vars %||% list(), t$vars %||% list()))
  else list(id = t, vars = r$vars %||% list())
})
for (id in names(rules)) {
  r <- rules[[id]]
  if (is.null(r$skip)) {
    if (is.null(r$to)) stop(id, ": a rule needs `to` or `skip`")
    to_ids <- vapply(targets(r), \(t) as.character(t$id %||% NA), "")
    if (!all(to_ids %in% L1$artifacts$id)) stop(id, ": unknown v1 artifact ", paste(to_ids, collapse = ", "))
    if (!(r$when %||% "all") %in% c("all", "current", "later")) stop(id, ": when is all, current or later")
  }
}

# Parse keys of one v0 artifact into a data frame of its variables.
parse_keys <- function(keys, id) {
  t <- L0$artifacts$template[L0$artifacts$id == id]
  rx <- .layout_regex(t, L0, id)
  m <- regmatches(keys, regexec(rx$regex, keys, perl = TRUE))
  m <- do.call(rbind, m)
  vars <- rx$vars
  if (grepl("/$", t)) vars <- c(vars, "file")
  out <- as.data.frame(m[, -1, drop = FALSE][, seq_along(vars), drop = FALSE], stringsAsFactors = FALSE)
  names(out) <- vars
  out
}

# The canonical spelling of variable v's published values in layout L.
canonical <- function(v, x, L) {
  map <- if (v == "flavor") L$flavors else L$values[[v]]
  if (is.null(map) || !length(map)) return(x)
  inv <- stats::setNames(names(map), unname(map))
  ifelse(x %in% names(inv), inv[x], x)
}

# Fill the variables a v1 template needs, and the key.
v1_keys <- function(v, to, extra) {
  for (n in names(extra)) v[[n]] <- rep(as.character(extra[[n]]), nrow(v))
  if (!is.null(v$compact_date) && is.null(v$date))
    v$date <- format(as.Date(v$compact_date, "%Y%m%d"))
  if (!is.null(v$date)) {
    d <- as.Date(v$date)
    v$compact_date <- format(d, "%Y%m%d")
    v$day <- format(d, "%m-%d")
    y <- as.integer(format(d, "%Y")); mo <- as.integer(format(d, "%m"))
    if (is.null(extra$wy)) v$wy <- as.character(if (L1$year_type == "wy") ifelse(mo >= 10L, y + 1L, y) else y)
  }
  for (n in setdiff(names(v), c("file", names(extra)))) v[[n]] <- canonical(n, v[[n]], L0)
  if (!is.null(v$flavor)) v$flavor <- unname(L1$flavors[v$flavor])
  t <- L1$artifacts$template[L1$artifacts$id == to]
  need <- .layout_vars(t)
  if ("period" %in% need && is.null(v$period)) {
    if (is.null(v$role) || is.null(v$wy)) stop(to, " needs {period}: give role and wy")
    rw  <- unique(paste(v$role, v$wy, sep = "\t"))
    per <- vapply(strsplit(rw, "\t", fixed = TRUE), \(x) layout_period(x[1], x[2], L1)$period %||% NA_character_, "")
    v$period <- unname(per[match(paste(v$role, v$wy, sep = "\t"), rw)])
  }
  lack <- setdiff(need, names(v))
  if (length(lack)) stop(to, " needs ", paste0("{", lack, "}", collapse = ", "))
  parts <- regmatches(t, gregexpr("\\{[a-z_]+\\}", t), invert = NA)[[1]]
  cols <- lapply(parts, \(p) if (grepl("^\\{[a-z_]+\\}$", p)) v[[gsub("[{}]", "", p)]] else rep(p, nrow(v)))
  key <- do.call(paste0, cols)
  if (grepl("/$", t)) key <- paste0(key, v$file)
  key[is.na(v$period %||% rep("", nrow(v)))] <- NA_character_
  key
}

files <- paste0(opt$out, c(".tsv", ".skipped.tsv", ".summary.tsv"))
for (f in files[1:2]) if (file.exists(f)) unlink(f)
con <- file(opt$listing, "r")
all_dst <- character()
counts <- list()
problems <- character()
count <- function(id, what, n) {
  if (n == 0) return()
  k <- paste(id, what, sep = "\t"); counts[[k]] <<- (counts[[k]] %||% 0) + n
}
n_total <- 0
repeat {
  lines <- readLines(con, n = opt$chunk)
  if (!length(lines)) break
  # `aws s3 ls --recursive`: date, time, size, key (keys may hold spaces).
  keys <- ifelse(grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} +[0-9]+ ", lines),
                 sub("^[0-9-]+ [0-9:]+ +[0-9]+ ", "", lines), lines)
  keys <- keys[nzchar(keys) & !grepl("/$", keys)]
  n_total <- n_total + length(keys)
  ids <- layout_classify(keys, L0)
  none <- is.na(ids) | ids == "<several>"
  if (any(none)) {
    problems <- c(problems, paste0("unclassified (", ids[none], "): ", utils::head(keys[none], 5)))
    count("<unclassified>", "error", sum(none))
  }
  copies <- list(); skips <- list()
  for (id in unique(ids[!none])) {
    k <- keys[!none & ids == id]
    r <- rules[[id]]
    if (!is.null(r$skip)) {
      skips[[length(skips) + 1L]] <- data.frame(src = k, reason = r$skip)
      count(id, "skipped", length(k)); next
    }
    v <- parse_keys(k, id)
    when <- r$when %||% "all"
    for (tg in targets(r)) {
      to <- tg$id
      dst <- v1_keys(v, to, tg$vars)
      wy <- if (!is.null(v$wy)) as.integer(v$wy) else if (!is.null(v$date)) {
        d <- as.Date(v$date); y <- as.integer(format(d, "%Y")); ifelse(as.integer(format(d, "%m")) >= 10L, y + 1L, y)
      } else rep(NA_integer_, length(k))
      later <- when == "later" | (when == "current" & !is.na(wy) & wy != opt$wy)
      if (opt$scope == "all") later[] <- FALSE
      noper <- is.na(dst)
      take <- !later & !noper
      if (any(noper)) {
        skips[[length(skips) + 1L]] <- data.frame(src = k[noper], reason = paste0("no ", to, " period for this water year"))
        count(id, "skipped", sum(noper))
      }
      if (any(later & !noper)) {
        skips[[length(skips) + 1L]] <- data.frame(src = k[later & !noper],
                                                  reason = paste0("later: ", to, " of an earlier water year"))
        count(id, "later", sum(later & !noper))
      }
      if (any(take)) {
        chk <- layout_classify(dst[take], L1)
        wrong <- chk != to | is.na(chk)
        if (any(wrong)) {
          problems <- c(problems, paste0(id, " -> ", to, ": ", utils::head(dst[take][wrong], 3), " classifies as ",
                                         utils::head(chk[wrong], 3)))
          count(id, "error", sum(wrong))
        }
        copies[[length(copies) + 1L]] <- data.frame(src = k[take], dst = dst[take])
        count(id, paste0("copied to ", to), sum(take))
      }
    }
  }
  cp <- do.call(rbind, copies); sk <- do.call(rbind, skips)
  if (!is.null(cp)) {
    utils::write.table(cp, files[1], sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE, append = TRUE)
    all_dst <- c(all_dst, cp$dst)
  }
  if (!is.null(sk))
    utils::write.table(sk, files[2], sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE, append = TRUE)
  message(format(n_total, big.mark = ","), " keys read")
}
close(con)

dup <- duplicated(all_dst)
if (any(dup)) problems <- c(problems, paste0(sum(dup), " destination(s) shared by two sources, e.g. ",
                                             utils::head(all_dst[dup], 3)))
summary <- data.frame(v0_artifact = sub("\t.*", "", names(counts)), outcome = sub("^[^\t]*\t", "", names(counts)),
                      keys = unlist(counts), row.names = NULL)
summary <- summary[order(summary$v0_artifact, summary$outcome), ]
utils::write.table(summary, files[3], sep = "\t", quote = FALSE, row.names = FALSE)
print(summary, row.names = FALSE)
message(format(n_total, big.mark = ","), " keys: ", format(length(all_dst), big.mark = ","), " copies, ",
        format(sum(summary$keys[summary$outcome %in% c("skipped", "later")]), big.mark = ","), " skipped")
if (length(problems)) {
  message("PROBLEMS:\n  ", paste(utils::head(problems, 50), collapse = "\n  "))
  quit(status = 1)
}
