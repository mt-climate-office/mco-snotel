# Bucket layout resolver: turns an artifact ID and its variables into an S3
# key, from config/layout.yml (docs/bucket-layout.md, sections 3-7 and 12).
# Pipeline code names artifacts; only this file and config/ know paths.
#
# Kept byte-identical in mco-snotel and mco-snodas
# (scripts/check-layout-identical.sh). Only config/layout.yml differs.
#
# Sourcing this file only defines functions (pipeline_setup() sources every
# R/*.R): nothing is read until a function is called. Needs the yaml package.
#
#   layout_key("percentiles", role = "snodas", wy = 2027)
#   layout_key("plot", date = "2027-02-01", role = "snodas", flavor = "smoothed",
#              type = "swe", subject = "901_MT_SNTL")
#   layout_key("cache", file = "state.parquet")
#   layout_prefix("normals_table", role = "snodas", wy = 2027)   # its folder
#   layout_period("snodas", 2027)                                  # wy1997-2026
#
# Variables (section 3). Values are checked against their format. Derived
# when not given: wy, compact_date and day from date; period from role and wy
# (section 5). Variables a template does not use are ignored, so one call
# serves every layout version. Flavors may be given by their canonical name
# (empirical, fitted, smoothed), their internal name (ecdf, zig, zig_smooth)
# or the version's published name: v0 publishes ecdf, zig and zig_smooth, v1
# the canonical names.
#
# Environment: LAYOUT_CONFIG (default config/layout.yml), LAYOUT_BUCKET
# (S3_BUCKET is an alias; LAYOUT_BUCKET wins), LAYOUT_PREFIX (a key prefix
# for every artifact, e.g. for a local or migration run; default none).

# Formats of the section 3 variables. role, flavor, type and artifact are
# checked against the configured values instead.
.layout_formats <- c(
  year_type    = "(wy|cy)",
  period       = "(wy|cy)([0-9]{4}|por)-[0-9]{4}",
  role         = NA,
  flavor       = NA,
  subject      = "[A-Za-z0-9][A-Za-z0-9.-]*(_[A-Za-z0-9.-]+)*",
  type         = NA,
  date         = "[0-9]{4}-[0-9]{2}-[0-9]{2}",
  compact_date = "[0-9]{8}",
  wy           = "[0-9]{4}",
  day          = "[0-9]{2}-[0-9]{2}",
  stat         = "[a-z][a-z0-9]*(_[a-z0-9]+)*",
  var          = "[a-z][a-z0-9]*(_[a-z0-9]+)*",
  artifact     = NA
)

# File-name element order (section 4); role stands where period would.
.layout_order <- c(subject = 1, type = 2, period = 3, role = 3, flavor = 4,
                   date = 5, compact_date = 5, day = 5, wy = 5, stat = 6)

.layout_canonical_flavors <- c("empirical", "fitted", "smoothed")
# The pipelines' internal flavor names (section 2, rule 7), accepted by every
# layout version and mapped to its published names.
.layout_internal_flavors <- c(ecdf = "empirical", zig = "fitted", zig_smooth = "smoothed")

# Section 6: cache class and mutability by artifact ID, including the
# bucket-specific IDs of section 7. Other IDs must set `cache` themselves.
.layout_registry <- data.frame(
  id = c("subjects", "raw", "raw_tar", "raw_cog", "normals_table", "normals_by_subject",
         "normals_grid", "reference", "provenance", "provenance_grid", "means", "percentiles",
         "percentile_grid", "outlook", "plot", "plot_index", "animation", "latest_copy",
         "latest_grid", "latest_manifest", "latest_manifest_grid", "cache"),
  cache = c("short", "short", "long", "long", "long", "long",
            "long", "long", "long", "long", "short", "short",
            "long", "long", "long", "long", "short", "short",
            "short", "short", "short", "none"),
  mutability = c("rewritten", "rewritten", "frozen", "frozen", "frozen", "frozen",
                 "frozen", "frozen", "frozen", "frozen", "rewritten", "rewritten",
                 "frozen", "frozen", "frozen", "frozen", "rewritten", "rewritten",
                 "rewritten", "rewritten", "rewritten", "any"),
  stringsAsFactors = FALSE
)

.layout_cache <- new.env(parent = emptyenv())


# ── Loading and validation ────────────────────────────────────────────────────

layout_config_path <- function() {
  p <- Sys.getenv("LAYOUT_CONFIG", unset = "")
  if (nzchar(p)) p else file.path("config", "layout.yml")
}

#' The layout in use, loaded once per session (or again with reload = TRUE).
layout_config <- function(path = layout_config_path(), reload = FALSE) {
  path <- normalizePath(path, mustWork = FALSE)
  if (reload || !identical(.layout_cache$path, path)) {
    .layout_cache$layout <- layout_load(path)
    .layout_cache$path <- path
  }
  .layout_cache$layout
}

#' Read and validate a layout file. Validation is strict (section 12) from
#' layout_version 1; version 0 describes the old layout as it is.
layout_load <- function(path, validate = TRUE) {
  if (!requireNamespace("yaml", quietly = TRUE)) stop("The layout resolver needs the yaml package")
  if (!file.exists(path)) stop("No layout file at ", path)
  x <- yaml::read_yaml(path)
  layout <- .layout_normalise(x, source = path)
  if (validate) layout_validate(layout)
  layout
}

.layout_normalise <- function(x, source = "<layout>") {
  if (!is.list(x)) stop(source, ": not a YAML map")
  fl <- x$flavors
  flavors <- if (is.null(fl)) character()
             else if (is.null(names(fl))) stats::setNames(as.character(unlist(fl)), unlist(fl))
             else vapply(fl, as.character, "")
  arts <- x$artifacts %||% list()
  tab <- do.call(rbind, lapply(names(arts), \(id) {
    a <- arts[[id]]
    if (is.character(a)) a <- list(template = a)
    reg <- .layout_registry[.layout_registry$id == id, ]
    data.frame(id = id,
               template = as.character(a$template %||% NA_character_),
               cache = as.character(a$cache %||% (if (nrow(reg)) reg$cache else NA_character_)),
               mutability = as.character(a$mutability %||% (if (nrow(reg)) reg$mutability else NA_character_)),
               note = as.character(a$note %||% ""),
               stringsAsFactors = FALSE)
  }))
  formats <- Filter(Negate(is.null), lapply(arts, \(a) if (is.list(a) && !is.null(a$formats))
    vapply(a$formats, as.character, "")))
  if (is.null(tab)) tab <- data.frame(id = character(), template = character(), cache = character(),
                                      mutability = character(), note = character())
  structure(list(
    source         = source,
    layout_version = x$layout_version,
    bucket         = x$bucket,
    year_type      = x$year_type %||% "wy",
    roles          = x$roles %||% list(),
    flavors        = flavors,                 # canonical -> published
    types          = as.character(unlist(x$types)),
    values         = lapply(x$values %||% list(), \(m) vapply(m, as.character, "")),
    variables      = vapply(x$variables %||% list(), as.character, ""),
    artifacts      = tab,
    formats        = formats,                 # per artifact: variable -> format
    extra          = setdiff(names(x), c("layout_version", "bucket", "year_type", "roles", "flavors",
                                         "types", "values", "variables", "artifacts"))
  ), class = "mco_layout")
}

#' Check a layout against sections 3-7 (strictly from layout_version 1).
#' Stops with every problem listed, or returns the layout invisibly.
layout_validate <- function(layout, strict = isTRUE(layout$layout_version >= 1), stop_on_error = TRUE) {
  p <- character()
  add <- function(...) p <<- c(p, paste0(...))
  v <- layout$layout_version
  if (!(is.numeric(v) && length(v) == 1 && v %in% c(0, 1))) add("layout_version must be 0 or 1")
  if (!(is.character(layout$bucket) && length(layout$bucket) == 1 && nzchar(layout$bucket)))
    add("bucket must be a bucket name")
  if (!layout$year_type %in% c("wy", "cy")) add("year_type must be wy or cy")
  if (length(layout$extra)) add("unknown top-level keys: ", paste(layout$extra, collapse = ", "))

  for (r in names(layout$roles)) {
    x <- layout$roles[[r]]
    if (!grepl("^[a-z0-9]+$", r)) add("role ", r, ": names are lower-case letters and digits")
    rule <- x$rule %||% ""
    if (!rule %in% c("rolling", "fixed", "por")) { add("role ", r, ": unknown rule '", rule, "'"); next }
    if (rule == "rolling" && !(is.numeric(x$length) && x$length >= 1))
      add("role ", r, ": rolling needs a length")
    if (rule == "fixed") {
      ok <- is.list(x$periods) && length(x$periods) &&
        all(vapply(x$periods, \(y) is.numeric(y) && length(y) == 2 && y[1] <= y[2], logical(1)))
      if (!ok) add("role ", r, ": fixed needs periods: [[first, last], ...]")
    }
    unknown <- setdiff(names(x), c("rule", "length", "earliest", "periods", "publish_lag", "min_years"))
    if (length(unknown)) add("role ", r, ": unknown keys ", paste(unknown, collapse = ", "))
  }

  fl <- layout$flavors
  if (!all(names(fl) %in% .layout_canonical_flavors))
    add("flavors: canonical names are ", paste(.layout_canonical_flavors, collapse = ", "))
  if (anyDuplicated(fl)) add("flavors: published names must differ")

  if (strict) {
    if (!identical(unname(fl), .layout_canonical_flavors) || !identical(names(fl), .layout_canonical_flavors))
      add("flavors must be [empirical, fitted, smoothed] from layout_version 1")
    if (length(layout$values)) add("values: published-name maps are for layout_version 0 only")
    if (length(layout$variables)) add("variables: extra variables are for layout_version 0 only")
  }

  known <- c(names(.layout_formats), names(layout$variables))
  arts <- layout$artifacts
  if (anyDuplicated(arts$id)) add("artifacts: duplicate IDs")
  for (i in seq_len(nrow(arts))) {
    id <- arts$id[i]; t <- arts$template[i]
    if (is.na(t) || !nzchar(t)) { add(id, ": no template"); next }
    if (!grepl("^[a-z][a-z0-9_]*$", id)) add(id, ": artifact IDs are lower-case snake_case")
    if (!arts$cache[i] %in% c("short", "long", "none"))
      add(id, ": cache must be short, long or none (set it for IDs not in section 6)")
    if (grepl("^/|//|\\.\\./|^\\./", t)) add(id, ": template must be relative, without // or ..")
    if (lengths(regmatches(t, gregexpr("\\{", t))) != lengths(regmatches(t, gregexpr("\\}", t))))
      add(id, ": unbalanced braces")
    vars <- .layout_vars(t)
    bad <- setdiff(vars, known)
    if (length(bad)) add(id, ": unknown variable(s) ", paste0("{", bad, "}", collapse = ", "))
    if ("artifact" %in% vars) {
      ids <- c(arts$id, names(layout$values$artifact))
      if (!length(ids)) add(id, ": {artifact} needs artifact IDs")
    }
    if (strict) {
      lit <- gsub("\\{[^}]*\\}", "", t)
      if (grepl("[^a-z0-9_./-]", lit)) add(id, ": literal parts must be lower-case ASCII")
      fname <- basename(sub("/$", "", t))
      if (!grepl("/$", t)) {
        r <- .layout_order[intersect(.layout_vars(fname), names(.layout_order))]
        if (length(r) > 1 && any(diff(r) <= 0))
          add(id, ": file name elements out of order (", paste(names(r), collapse = ", "),
              "); section 4 order is subject, type, period, flavor, date|day|wy, stat")
      }
      for (lev in strsplit(t, "/", fixed = TRUE)[[1]]) {
        m <- regmatches(lev, regexec("^\\{([a-z_]+)\\}$", lev))[[1]]
        if (length(m) == 2 && length(.layout_value_set(layout, m[2])) == 1)
          add(id, ": path level {", m[2], "} has only one possible value")
      }
    }
  }
  dup <- arts$template[duplicated(arts$template)]
  if (length(dup)) add("artifacts share a template: ", paste(unique(dup), collapse = ", "))

  if (length(p) && stop_on_error)
    stop("Layout ", layout$source, " (layout_version ", format(v), "):\n  ", paste(p, collapse = "\n  "),
         call. = FALSE)
  invisible(if (stop_on_error) layout else p)
}

#' Section 12: artifact IDs two buckets share must mean the same thing. Checks
#' that they use the same variables (apart from type, which one bucket may
#' not need) and the same file extension. Returns the problems found.
layout_check_shared <- function(a, b) {
  p <- character()
  shared <- intersect(a$artifacts$id, b$artifacts$id)
  for (id in shared) {
    ta <- a$artifacts$template[a$artifacts$id == id]; tb <- b$artifacts$template[b$artifacts$id == id]
    va <- setdiff(.layout_vars(ta), "type"); vb <- setdiff(.layout_vars(tb), "type")
    if (!setequal(va, vb))
      p <- c(p, paste0(id, ": variables differ (", paste(sort(va), collapse = ","), " vs ",
                       paste(sort(vb), collapse = ","), ")"))
    ext <- \(t) if (grepl("/$", t)) "/" else if (grepl(".", basename(t), fixed = TRUE))
      sub("^[^.]*", "", basename(t)) else ""
    if (!identical(ext(ta), ext(tb))) p <- c(p, paste0(id, ": file types differ (", ta, " vs ", tb, ")"))
  }
  p
}


# ── Bucket, prefix and periods ────────────────────────────────────────────────

#' The bucket: LAYOUT_BUCKET, else S3_BUCKET, else the configured one.
layout_bucket <- function(layout = layout_config()) {
  for (v in c("LAYOUT_BUCKET", "S3_BUCKET")) {
    b <- Sys.getenv(v, unset = "")
    if (nzchar(b)) return(b)
  }
  layout$bucket
}

#' The key prefix every artifact sits under: LAYOUT_PREFIX, "" by default.
layout_root <- function() {
  p <- gsub("^/+|/+$", "", Sys.getenv("LAYOUT_PREFIX", unset = ""))
  if (nzchar(p)) paste0(p, "/") else ""
}

#' The roles configured, or those present in water year wy.
layout_roles <- function(wy = NULL, layout = layout_config()) {
  r <- names(layout$roles)
  if (is.null(wy)) return(r)
  r[vapply(r, \(x) !is.null(layout_period(x, wy, layout)), logical(1))]
}

#' The period a role resolves to for year W (section 5): a list of role,
#' period, first and last (first is NA for a period of record), or NULL when
#' the role is absent that year.
layout_period <- function(role, wy, layout = layout_config()) {
  r <- layout$roles[[role]]
  if (is.null(r)) stop("Unknown role '", role, "' (", paste(names(layout$roles), collapse = ", "), ")")
  W <- as.integer(wy); yt <- layout$year_type
  if (is.na(W)) stop("Not a year: ", wy)
  out <- function(first, last) {
    if (!is.na(first) && first > last) return(NULL)
    if (!is.na(first) && !is.null(r$min_years) && last - first + 1L < r$min_years) return(NULL)
    list(role = role, period = paste0(yt, if (is.na(first)) "por" else first, "-", last),
         first = as.integer(first), last = as.integer(last))
  }
  switch(r$rule,
    rolling = out(max(W - as.integer(r$length), if (is.null(r$earliest)) -.Machine$integer.max else as.integer(r$earliest)),
                  W - 1L),
    fixed = {
      lag <- as.integer(r$publish_lag %||% 0L)
      ok <- Filter(\(y) y[2] + lag < W, r$periods)
      if (!length(ok)) NULL
      else { y <- ok[[which.max(vapply(ok, `[`, 0, 2))]]; out(as.integer(y[1]), as.integer(y[2])) }
    },
    por = out(NA_integer_, W - 1L),
    stop("Unknown rule for role ", role))
}

#' A role's reference years for year wy, within a record starting first_wy
#' (needed for a period of record). integer(0) when the role is absent.
layout_role_years <- function(role, wy, first_wy = NULL, layout = layout_config()) {
  p <- layout_period(role, wy, layout)
  if (is.null(p)) return(integer())
  first <- if (is.na(p$first)) {
    if (is.null(first_wy)) stop("Role ", role, " is a period of record: give first_wy")
    as.integer(first_wy)
  } else p$first
  y <- if (first <= p$last) first:p$last else integer()
  if (!is.null(first_wy)) y <- y[y >= first_wy]
  y
}


# ── Vocabulary ────────────────────────────────────────────────────────────────

#' Published flavor names, in canonical order.
layout_flavors <- function(layout = layout_config()) unname(layout$flavors)

#' A flavor's published name in this layout, from its canonical, internal
#' (ecdf, zig, zig_smooth) or published name.
layout_flavor <- function(x, layout = layout_config()) {
  x <- as.character(x)
  pub <- unname(layout$flavors)
  internal <- !x %in% pub & x %in% names(.layout_internal_flavors)
  x[internal] <- .layout_internal_flavors[x[internal]]
  layout_value("flavor", x, layout)
}

#' A variable's value as this layout spells it (v0 keeps some old names).
layout_value <- function(var, x, layout = layout_config()) {
  x <- as.character(x)
  map <- if (var == "flavor") layout$flavors else layout$values[[var]]
  if (is.null(map) || !length(map)) return(x)
  ifelse(x %in% names(map), map[x], x)
}

# The values a variable may take, where the layout fixes them (else NULL).
.layout_value_set <- function(layout, var) {
  switch(var,
    role     = names(layout$roles),
    flavor   = unname(layout$flavors),
    type     = layout$types,
    artifact = unique(c(layout$artifacts$id, unname(layout$values$artifact))),
    {
      vals <- layout$values[[var]]
      if (length(vals) && is.na(.layout_formats[var] %||% NA)) unname(vals)
    })
}

.layout_pattern <- function(layout, var, id = NULL) {
  own <- if (!is.null(id)) layout$formats[[id]][var]
  if (length(own) && !is.na(own)) return(sub("^\\^", "", sub("\\$$", "", own)))
  set <- .layout_value_set(layout, var)
  if (!is.null(set) && var %in% c("role", "flavor", "type", "artifact"))
    return(paste0("(", paste(gsub("([.|()\\^{}+$*?\\[\\]\\\\])", "\\\\\\1", set), collapse = "|"), ")"))
  f <- if (var %in% names(layout$variables)) layout$variables[[var]] else .layout_formats[[var]]
  if (is.null(f) || is.na(f)) stop("No format for variable {", var, "}")
  sub("^\\^", "", sub("\\$$", "", f))
}

.layout_vars <- function(t) {
  m <- regmatches(t, gregexpr("\\{[a-z_]+\\}", t))[[1]]
  unique(gsub("[{}]", "", m))
}

`%||%` <- function(a, b) if (is.null(a)) b else a


# ── Keys ──────────────────────────────────────────────────────────────────────

.layout_artifact <- function(artifact, layout) {
  a <- layout$artifacts[layout$artifacts$id == artifact, ]
  if (!nrow(a)) stop("No artifact '", artifact, "' in layout_version ", layout$layout_version,
                     " (", layout$source, ")")
  a
}

#' Whether this layout has an artifact (e.g. latest_subjects is v0 only).
layout_has <- function(id, layout = layout_config()) id %in% layout$artifacts$id

#' The variables an artifact's template uses.
layout_vars <- function(id, layout = layout_config()) .layout_vars(.layout_artifact(id, layout)$template)

# Fill in derived variables and check every value a template needs.
.layout_values <- function(vars, need, layout, id = NULL) {
  vars <- vars[!vapply(vars, is.null, logical(1))]
  if (!is.null(vars$date)) {
    d <- vars$date
    d <- if (inherits(d, "Date")) d else as.Date(as.character(d), format = "%Y-%m-%d")
    if (length(d) != 1 || is.na(d)) stop("Not a date (YYYY-MM-DD): ", format(vars$date))
    y <- as.integer(format(d, "%Y")); m <- as.integer(format(d, "%m"))
    vars$date <- format(d, "%Y-%m-%d")
    vars$compact_date <- vars$compact_date %||% format(d, "%Y%m%d")
    vars$day <- vars$day %||% format(d, "%m-%d")
    vars$wy <- vars$wy %||% (if (layout$year_type == "wy" && m >= 10L) y + 1L else y)
  }
  if ("period" %in% need && is.null(vars$period) && !is.null(vars$role) && !is.null(vars$wy)) {
    p <- layout_period(vars$role, vars$wy, layout)
    if (is.null(p)) stop("Role ", vars$role, " has no period in ", layout$year_type, vars$wy)
    vars$period <- p$period
  }
  if (!is.null(vars$flavor)) vars$flavor <- layout_flavor(vars$flavor, layout)
  for (v in setdiff(names(layout$values), "flavor"))
    if (!is.null(vars[[v]])) vars[[v]] <- layout_value(v, vars[[v]], layout)
  out <- list()
  for (v in intersect(need, names(vars))) {
    x <- vars[[v]]
    if (length(x) != 1 || is.na(x)) stop("{", v, "} must be one value")
    x <- as.character(x)
    if (!grepl(paste0("^", .layout_pattern(layout, v, id), "$"), x))
      stop("{", v, "} = '", x, "' does not match its format")
    out[[v]] <- x
  }
  out
}

.layout_fill <- function(t, vals) {
  for (v in names(vals)) t <- gsub(paste0("{", v, "}"), vals[[v]], t, fixed = TRUE)
  t
}

#' The S3 key of artifact `id`. For a prefix artifact (template ending in "/",
#' such as cache), `file` names an object under it.
layout_key <- function(id, ..., file = NULL, layout = layout_config()) {
  a <- .layout_artifact(id, layout)
  need <- .layout_vars(a$template)
  vals <- .layout_values(list(...), need, layout, id)
  miss <- setdiff(need, names(vals))
  if (length(miss)) stop(id, " needs ", paste0("{", miss, "}", collapse = ", "), " (", a$template, ")")
  key <- .layout_fill(a$template, vals)
  if (grepl("/$", key)) {
    if (is.null(file)) stop(id, " is a prefix (", a$template, "): give `file`, or use layout_prefix()")
    if (!grepl("^[^/]", file) || grepl("(^|/)\\.\\.?(/|$)|//", file)) stop("Not a relative file name: ", file)
    key <- paste0(key, file)
  } else if (!is.null(file)) stop(id, " is not a prefix; `file` is for prefix artifacts")
  paste0(layout_root(), key)
}

#' The keys of an artifact for each combination of the variables given
#' (vectors are crossed), e.g. every role and flavor of a date's plots.
layout_keys <- function(id, ..., layout = layout_config()) {
  args <- list(...)
  args <- args[!vapply(args, is.null, logical(1))]
  grid <- expand.grid(lapply(args, \(x) if (inherits(x, "Date")) format(x) else x),
                      stringsAsFactors = FALSE, KEEP.OUT.ATTRS = FALSE)
  vapply(seq_len(nrow(grid)), \(i) do.call(layout_key, c(list(id), as.list(grid[i, , drop = FALSE]),
                                                        list(layout = layout))), "")
}

#' The s3:// URI of an artifact.
layout_uri <- function(id, ..., file = NULL, layout = layout_config())
  paste0("s3://", layout_bucket(layout), "/", layout_key(id, ..., file = file, layout = layout))

#' The folder of an artifact as far as the variables given determine it: the
#' template is filled up to its first unknown variable, then cut back to the
#' last "/". With no artifact, the prefix every key sits under (LAYOUT_PREFIX).
#' `slash = FALSE` drops the trailing "/".
layout_prefix <- function(id = NULL, ..., slash = TRUE, layout = layout_config()) {
  if (is.null(id)) {
    p <- layout_root()
  } else {
    a <- .layout_artifact(id, layout)
    t <- a$template
    vals <- .layout_values(list(...), .layout_vars(t), layout, id)
    t <- .layout_fill(t, vals)
    open <- regexpr("\\{", t)
    if (open > 0) t <- substr(t, 1, open - 1)
    p <- paste0(layout_root(), sub("[^/]*$", "", t))
  }
  if (!slash) sub("/$", "", p) else p
}

#' Which artifact a key belongs to, and its variables: a list(artifact, vars),
#' or NULL when no template matches. Keys under LAYOUT_PREFIX are matched
#' after removing it. Used to check real listings and access logs.
layout_match <- function(key, layout = layout_config()) {
  root <- layout_root()
  if (nzchar(root)) { if (!startsWith(key, root)) return(NULL); key <- substring(key, nchar(root) + 1L) }
  arts <- layout$artifacts
  hits <- list()
  for (i in seq_len(nrow(arts))) {
    rx <- .layout_regex(arts$template[i], layout, arts$id[i])
    m <- regmatches(key, regexec(rx$regex, key, perl = TRUE))[[1]]
    if (length(m)) {
      vars <- stats::setNames(as.list(m[-1][seq_along(rx$vars)]), rx$vars)
      if (grepl("/$", arts$template[i])) vars$file <- utils::tail(m, 1)
      hits[[length(hits) + 1L]] <- list(artifact = arts$id[i], vars = vars)
    }
  }
  if (!length(hits)) return(NULL)
  # A prefix artifact (e.g. cache/) yields to a file artifact under it.
  files <- Filter(\(h) is.null(h$vars$file), hits)
  if (length(files)) hits <- files
  if (length(hits) > 1)
    stop("Key ", key, " matches several artifacts: ", paste(vapply(hits, `[[`, "", "artifact"), collapse = ", "))
  hits[[1]]
}

#' Vectorised layout_match() for many keys (e.g. a whole bucket listing): the
#' artifact ID of each key, NA where none matches, "<several>" where more than
#' one file artifact does.
layout_classify <- function(keys, layout = layout_config()) {
  root <- layout_root()
  rel <- if (nzchar(root)) ifelse(startsWith(keys, root), substring(keys, nchar(root) + 1L), NA) else keys
  arts <- layout$artifacts
  hit <- vapply(seq_len(nrow(arts)), \(i)
    !is.na(rel) & grepl(.layout_regex(arts$template[i], layout, arts$id[i])$regex, rel, perl = TRUE),
    logical(length(keys)))
  hit <- matrix(hit, nrow = length(keys))
  is_prefix <- grepl("/$", arts$template)
  file_hits <- hit[, !is_prefix, drop = FALSE]
  nf <- rowSums(file_hits)
  out <- rep(NA_character_, length(keys))
  one <- nf == 1L
  out[one] <- arts$id[!is_prefix][max.col(file_hits[one, , drop = FALSE], ties.method = "first")]
  out[nf > 1L] <- "<several>"
  pre <- nf == 0L & rowSums(hit[, is_prefix, drop = FALSE]) > 0
  if (any(pre)) out[pre] <- arts$id[is_prefix][max.col(hit[pre, is_prefix, drop = FALSE], ties.method = "first")]
  out
}

# A template as an anchored regex with one group per variable; a repeated
# variable must repeat its value.
.layout_regex <- function(t, layout, id = NULL) {
  parts <- regmatches(t, gregexpr("\\{[a-z_]+\\}", t), invert = NA)[[1]]
  esc <- function(s) gsub("([.|()\\^{}+$*?\\[\\]\\\\-])", "\\\\\\1", s)
  rx <- ""; vars <- character()
  for (s in parts) {
    if (grepl("^\\{[a-z_]+\\}$", s)) {
      v <- gsub("[{}]", "", s)
      if (v %in% vars) { rx <- paste0(rx, "\\", which(vars == v)[1] * 1L); next }
      pat <- gsub("\\((?!\\?)", "(?:", .layout_pattern(layout, v, id), perl = TRUE)
      rx <- paste0(rx, "(", pat, ")"); vars <- c(vars, v)
    } else rx <- paste0(rx, esc(s))
  }
  if (grepl("/$", t)) rx <- paste0(rx, "(.+)")
  list(regex = paste0("^", rx, "$"), vars = vars)
}


# ── Listing ───────────────────────────────────────────────────────────────────

#' Every artifact: ID, template, the variables it uses, its literal prefix
#' (for listings and CDN rules), whether it is a prefix artifact, and its
#' cache class and mutability (section 6).
layout_artifacts <- function(layout = layout_config()) {
  a <- layout$artifacts
  a$variables <- vapply(a$template, \(t) paste(.layout_vars(t), collapse = ","), "", USE.NAMES = FALSE)
  a$literal_prefix <- vapply(a$template, \(t) {
    open <- regexpr("\\{", t)
    sub("[^/]*$", "", if (open > 0) substr(t, 1, open - 1) else t)
  }, "", USE.NAMES = FALSE)
  a$is_prefix <- grepl("/$", a$template)
  a$layout_version <- rep(layout$layout_version, nrow(a))
  a$bucket <- rep(layout$bucket, nrow(a))
  a[, c("id", "template", "variables", "literal_prefix", "is_prefix", "cache", "mutability",
        "layout_version", "bucket", "note")]
}

#' A key an artifact could have, with example values (for overlap checks).
layout_example_key <- function(id, layout = layout_config()) {
  t <- .layout_artifact(id, layout)$template
  ex <- list(year_type = layout$year_type, subject = "901_MT_SNTL", date = "2027-02-01",
             stat = "mean", var = "swe")
  vals <- lapply(.layout_vars(t), \(v) {
    set <- .layout_value_set(layout, v)
    if (!is.null(set)) return(set[1])
    switch(v,
      period = { r <- names(layout$roles)[1]; if (is.null(r)) paste0(layout$year_type, "2004-2026")
                 else layout_period(r, 2027, layout)$period %||% paste0(layout$year_type, "2004-2026") },
      compact_date = "20270201", wy = "2027", day = "02-01",
      ex[[v]] %||% "x")
  })
  key <- .layout_fill(t, stats::setNames(lapply(vals, as.character), .layout_vars(t)))
  if (grepl("/$", key)) paste0(key, "example") else key
}

#' Artifacts of layout a whose example keys some artifact of layout b would
#' also match, and vice versa: where two layouts (v0 and v1) could collide.
#' A data frame of from, artifact, key, and the other layout's artifact.
layout_overlaps <- function(a, b) {
  one <- function(x, y) do.call(rbind, lapply(x$artifacts$id, \(id) {
    k <- layout_example_key(id, x)
    m <- tryCatch(layout_match(k, y), error = \(e) list(artifact = "<several>"))
    if (!is.null(m)) data.frame(from = paste0("v", x$layout_version), artifact = id, key = k,
                                other = m$artifact, stringsAsFactors = FALSE)
  }))
  rbind(one(a, b), one(b, a))
}
