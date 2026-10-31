# Vendored from mco-snodas@62fe19a R/calc_snodas_zig_spline_normals.R. Do not edit
# here: change it upstream, then copy it back (see README, "Vendored code").

# ZIG-smooth normals: the daily ZIG (zero-inflated gamma fit by L-moments,
# src/zig.cpp) smoothed over the year with cyclic P-splines in day of snow
# year, per pixel or zone (src/zig_spline.cpp):
#   logit(p_zero) = s(day)   binomial on the daily zero counts (smoothed z / n)
#   log(l1)       = s(day)   mean of positive SWE        } weighted least squares
#   log(L-CV)     = s(day)   L-CV (l2 / l1) of positive  } on the daily L-moments
# shape = Hosking's approximation from L-CV (as zig_fit()) and scale = l1 /
# shape, so the parameters work in zig_p(), zig_q() and zig_mean() unchanged.
#
# Each day enters through the daily ZIG's own statistics, zig_lmom(): n (years
# observed), z (zeros), l1 and lcv (NA with fewer than 4 positive years).
#
# Smoothing parameters are fixed and global (ZIG_SMOOTH_LAMBDA). l1 and L-CV
# share lambda = 1e3 (~6 EDF each). Leave-one-year-out CV on 800 HUC8
# series (2026-10-26) found held-out log score nearly flat across lambda_lcv
# 1e3–1e5, while heavier L-CV smoothing delays the normal's melt-out (zones
# >7 days late: 3.9% at 1e3, 6.3% at 1e4, 13.6% at 1e5); timing of peak SWE
# and melt-out decided it. lambda_nu = 100 is from the earlier CV of the
# binomial curve.
#
# Built yearly by R/normals_annual.R. Requires src/zig.cpp and src/zig_spline.cpp.

ZIG_SMOOTH_K          <- 24L                                    # basis functions (knots ~15 days apart)
ZIG_SMOOTH_LAMBDA     <- c(nu = 100, l1 = 1e3, lcv = 1e3)       # fixed smoothing parameters
ZIG_SMOOTH_LCV_RANGE  <- c(1e-3, 0.999)                         # fitted L-CV clamp (curves bridge gaps freely)
ZIG_SMOOTH_BLOCK_ROWS <- 64L                                    # raster rows per AWS fit task

#' Cyclic cubic B-spline basis and difference penalty on the 365-day cycle.
#'
#' @param k  Number of basis functions.
#' @param at Cycle positions to evaluate (see normals_cycle_day()); fractional
#'           positions (Feb 29 = 151.5) are fine.
#' @return list(X = length(at) x k basis, S = k x k penalty, k)
zig_spline_basis <- function(k = ZIG_SMOOTH_K, at = 1:365) {
  # Knots depend only on the cycle range, so the basis does not depend on
  # `at`; mgcv's warning when `at` covers little of the cycle is harmless.
  sm <- suppressWarnings(mgcv::smoothCon(
    mgcv::s(day, bs = "cp", k = k),
    data  = data.frame(day = as.numeric(at)),
    knots = list(day = c(0.5, 365.5)),   # day 365 wraps to day 1
    absorb.cons = FALSE
  ))[[1]]
  list(X = sm$X, S = sm$S[[1]], k = k)
}

#' One day's reference stack as the daily ZIG's statistics.
#'
#' @param mat n_pix x n_years SWE for one calendar day (NA = missing).
#' @return n_pix x 4 matrix: n, z, l1, lcv (see zig_lmom() in src/zig.cpp).
zig_spline_suffstats <- function(mat) {
  zig_lmom(as.matrix(mat))
}

#' Fit ZIG splines to daily statistics.
#'
#' @param stats  list(n, z, l1, lcv), each n_pix x n_day.
#' @param basis  zig_spline_basis() evaluated at the n_day cycle positions.
#' @param lambda Smoothing parameters (nu, l1, lcv).
#' @return The list from zig_spline_fit(): coef, edf, iter, status.
zig_spline_fit_stats <- function(stats, basis, lambda = ZIG_SMOOTH_LAMBDA,
                                 min_pos = 10L, min_days = 30L) {
  zig_spline_fit(
    n_obs = stats$n, n_zero = stats$z, l1 = stats$l1, lcv = stats$lcv,
    basis = basis$X, penalty = basis$S, lambda = unname(lambda[c("nu", "l1", "lcv")]),
    min_pos = min_pos, min_days = min_days
  )
}

#' Split daily statistics into contiguous row chunks (one per worker).
#'
#' @param stats list(n, z, l1, lcv), each n_pix x n_day.
#' @return A list of chunks, each list(n, z, l1, lcv) for a block of rows.
zig_spline_chunk_stats <- function(stats, n_chunks) {
  n_pix <- nrow(stats$n)
  k     <- max(1L, min(n_chunks, n_pix))
  # cut() can't make one interval from one value, so one chunk is built directly.
  rows  <- if (k == 1L) list(seq_len(n_pix)) else split(seq_len(n_pix), cut(seq_len(n_pix), k, labels = FALSE))
  lapply(rows, \(r) lapply(stats, \(m) m[r, , drop = FALSE]))
}

#' Fit chunks of series in parallel with forked workers.
#'
#' Forked workers (parallel::mclapply) inherit the loaded R functions and
#' compiled code and share the parent's memory, so chunks are not copied.
#'
#' @param chunks List of list(n, z, l1, lcv) (see zig_spline_chunk_stats()).
#' @return list(coef, edf, iter, status) for all rows, in chunk order.
zig_spline_fit_parallel <- function(chunks, basis, cores = 1L) {
  fit_one <- \(chunk) zig_spline_fit_stats(chunk, basis)
  fits <- if (cores <= 1L || length(chunks) == 1L) lapply(chunks, fit_one)
          else parallel::mclapply(chunks, fit_one, mc.cores = cores, mc.preschedule = FALSE)
  bad <- vapply(fits, \(f) is.null(f) || inherits(f, "try-error"), logical(1))
  if (any(bad))
    stop("ZIG-smooth fit failed in ", sum(bad), " worker(s)",
         if (inherits(fits[[which(bad)[1]]], "try-error")) paste0(": ", fits[[which(bad)[1]]]) else
           " (killed — likely out of memory)")
  list(
    coef   = do.call(rbind, purrr::map(fits, "coef")),
    edf    = do.call(rbind, purrr::map(fits, "edf")),
    iter   = unlist(purrr::map(fits, "iter")),
    status = unlist(purrr::map(fits, "status"))
  )
}

#' Evaluate fitted splines as ZIG parameters.
#'
#' The daily ZIG's last link (zig_params_from_lmom()) on the smoothed curves:
#' shape from L-CV by Hosking's approximation, scale = l1 / shape.
#'
#' @param coefs  n_pix x 3k coefficient matrix ($coef from the fit).
#' @param basis  zig_spline_basis(), or a matrix of basis rows (X).
#' @param status Optional fit status; status 1 (no snow on record) → p_zero 1.
#' @return list(shape, scale, p_zero), each n_pix x nrow(X). Column j, bound
#'   as cbind(shape, scale, p_zero), matches zig_fit()'s layout for that day.
zig_spline_params <- function(coefs, basis, status = NULL) {
  X <- if (is.list(basis)) basis$X else basis
  k <- ncol(X)
  eta <- \(cols) coefs[, cols, drop = FALSE] %*% t(X)
  p_zero <- stats::plogis(eta(seq_len(k)))
  l1     <- exp(eta(k + seq_len(k)))
  lcv    <- pmin(pmax(exp(eta(2L * k + seq_len(k))), ZIG_SMOOTH_LCV_RANGE[1]), ZIG_SMOOTH_LCV_RANGE[2])
  shape  <- matrix(zig_shape_from_lcv(as.vector(lcv)), nrow(lcv))
  if (!is.null(status))
    p_zero[status == 1L, ] <- 1
  list(shape = shape, scale = l1 / shape, p_zero = p_zero)
}

#' Quantiles and mean of ZIG parameters with no raw record for the ECDF fallback.
#'
#' Matches zig_q() / zig_mean() where shape and scale exist. Where they do not
#' (fit status 2: too few positive values, or no day with L-moments)
#' quantiles above p_zero and the mean are NA. p_zero = 1 (no snow on record) gives 0.
#'
#' @param params n x 3 matrix (shape, scale, p_zero).
zig_smooth_q <- function(params, probs = unname(SNODAS_QUANTILES)) {
  shape <- params[, 1]; scale <- params[, 2]; p0 <- params[, 3]
  out <- vapply(probs, \(p) {
    p_adj <- (p - p0) / (1 - p0)
    q <- suppressWarnings(stats::qgamma(pmin(pmax(p_adj, 0), 1), shape = shape, scale = scale))
    q[p_adj <= 0] <- 0
    q[p_adj >= 1] <- NA_real_
    q[p0 >= 1]    <- 0          # no snow on record
    q[is.na(p0)]  <- NA_real_
    q
  }, numeric(nrow(params)))
  matrix(out, nrow(params), dimnames = list(NULL, names(SNODAS_QUANTILES)[match(probs, unname(SNODAS_QUANTILES))]))
}

zig_smooth_mean <- function(params) {
  ifelse(params[, 3] >= 1, 0, (1 - params[, 3]) * params[, 1] * params[, 2])
}
