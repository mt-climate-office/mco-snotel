#!/usr/bin/env bash
# Fail if pipeline code holds a bucket path (docs/bucket-layout.md, section 12:
# "No hard-coded paths"). Keys come from the layout resolver (R/layout.R,
# config/layout.yml) and nowhere else.
#
# Usage: scripts/check-no-paths.sh        (from anywhere; needs R and yaml)
#
# Scans the string literals (not comments) of *.R and scripts/**/*.sh. A
# literal is flagged when it
#   - names a bucket: s3://<name>...;
#   - is a path ("/" in it) with a level the layout spells out literally,
#     e.g. "plots/", "normals/reference", "by_station/x";
#   - is a file name of the layout on its own, e.g. "normals.parquet" or
#     "index.json", or (in R) a top-level folder such as "plots" passed to
#     file.path(), paste() or paste0().
# The words come from config/layout.yml, so the check follows the layout.
#
# Not scanned: R/layout.R (the resolver), config/, and
#   scripts/test_layout.R        the resolver's tests: today's keys, by design
#   scripts/parity/              shared with mco-snodas; seed.sh copies both
#                                buckets' inputs by key (docs/path-inventory.md)
#   scripts/keyset/              the key-set harness: it runs code from before
#                                the resolver too, so names its seed files itself
# A line ending in the comment `# local path` is skipped: for local files
# that happen to share a name with a bucket path.
#
# No CI job runs it yet (the only workflow builds the image on main); run it
# before a PR that touches R/ or scripts/.
set -euo pipefail
cd "$(dirname "$0")/.."

exec Rscript --vanilla - <<'EOF'
source("R/layout.R")
tpl <- layout_artifacts()$template
levels <- unique(unlist(strsplit(tpl, "/", fixed = TRUE)))
literal <- levels[nzchar(levels) & !grepl("{", levels, fixed = TRUE)]
top <- unique(sub("/.*$", "", tpl[grepl("^[^{]+/", tpl)]))
files_named <- literal[grepl(".", literal, fixed = TRUE)]

files <- c(Sys.glob("*.R"), Sys.glob("R/*.R"),
           list.files("scripts", pattern = "\\.(R|sh)$", recursive = TRUE, full.names = TRUE))
files <- files[!files %in% c("R/layout.R", "scripts/test_layout.R") & !grepl("^scripts/(parity|keyset)/", files)]

flagged <- function(s, joined) {
  if (grepl("s3://[A-Za-z0-9]", s)) return(TRUE)
  if (s %in% files_named || (joined && s %in% top)) return(TRUE)
  grepl("/", s, fixed = TRUE) && any(strsplit(s, "/", fixed = TRUE)[[1]] %in% literal)
}

# String literals, their lines, and (R only) whether they are an argument of
# file.path(), paste() or paste0(): R's parser for R; for shell, quoted
# strings and words after stripping comments.
strings <- function(f) {
  lines <- readLines(f, warn = FALSE)
  if (grepl("\\.R$", f)) {
    pd <- utils::getParseData(parse(f, keep.source = TRUE))
    # A call's function name sits two levels below the call (SYMBOL_FUNCTION_CALL
    # in an expr); an argument's string, two levels below too (STR_CONST in an expr).
    call_of <- \(id) pd$parent[match(pd$parent[match(id, pd$id)], pd$id)]
    fun <- pd[pd$token == "SYMBOL_FUNCTION_CALL", ]
    fun_by_call <- stats::setNames(fun$text, call_of(fun$id))
    str <- pd[pd$token == "STR_CONST", ]
    joined <- fun_by_call[as.character(call_of(str$id))] %in% c("file.path", "paste", "paste0")
    data.frame(line = str$line1, s = vapply(str$text, \(t) eval(str2lang(t)), ""), joined = joined,
               stringsAsFactors = FALSE)
  } else {
    code <- sub("(^|[[:space:]])#.*$", "", lines)
    out <- lapply(seq_along(code), \(i) {
      m <- regmatches(code[i], gregexpr("\"[^\"]*\"|'[^']*'|[^[:space:]\"';|&()<>]+", code[i]))[[1]]
      if (length(m)) data.frame(line = i, s = gsub("^[\"']|[\"']$", "", m), joined = FALSE, stringsAsFactors = FALSE)
    })
    do.call(rbind, c(out, list(data.frame(line = integer(), s = character(), joined = logical()))))
  }
}

bad <- character()
for (f in files) {
  lines <- readLines(f, warn = FALSE)
  x <- strings(f)
  x <- x[!grepl("#[[:space:]]*local path[[:space:]]*$", lines[x$line]), , drop = FALSE]
  hit <- x[mapply(flagged, x$s, x$joined), , drop = FALSE]
  if (nrow(hit)) bad <- c(bad, sprintf("%s:%d: \"%s\"", f, hit$line, hit$s))
}
if (length(bad)) {
  cat("Bucket paths outside the layout resolver (use layout_key() / R/layout_cli.R):\n",
      paste0("  ", bad, "\n"), sep = "")
  quit(status = 1)
}
cat("ok: no bucket paths in", length(files), "files\n")
EOF
