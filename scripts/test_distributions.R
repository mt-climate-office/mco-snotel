#!/usr/bin/env Rscript
# Vendored from mco-snodas@62fe19a scripts/test_distributions.R; the only change
# is the path of R/zig_spline_normals.R (R/calc_snodas_zig_spline_normals.R
# upstream). Do not edit here: change it upstream, then copy it back.
# Tests for the zero-inflated ECDF and ZIG implementations.
#
# Part 1 — ECDF  (src/ecdf.cpp)
#   1-1. ecdf_stats quantiles vs type-7     [double output]
#   1-2. ecdf_p  vs type-7 CDF              [double output]
#   1-3. Round-trip: ecdf_p(x) → ecdf_q = x [exact]
#   1-4. All-zeros edge case
#   1-5. Integer vs double input equivalence
#   1-6. Diagnostic: ecdf_p(0) = p_zero/2 as p_zero → 1
#
# Part 2 — ZIG   (src/zig.cpp)
#   2-1. zig_p  vs direct R formula / gamlss.dist::ZAGA  [double output]
#   2-2. zig_q  vs direct R formula / gamlss.dist::ZAGA  [double output]
#   2-3. Round-trip: zig_p(x) → zig_q ≈ x               [machine precision]
#   2-4. ZAGA equivalence (parametric path, representative scenario)
#   2-5. All-zeros edge case
#   2-6. Integer vs double input equivalence
#   2-7. Diagnostic: zig_p(0) = p_zero/2 as p_zero → 1
#   2-8. Boundary quantiles: q0000=0; q1000=NA (has positives) or 0 (all-zeros)
#
# Part 3 — NA years (both)
#   3-1. A row with NA years equals the same row with those years dropped
#   3-2. Too few valid years → NA; a complete short record is still used
#
# Part 4 — ZIG chain and ZIG-smooth  (src/zig.cpp, src/zig_spline.cpp)
#   4-1. zig_lmom vs R reference L-moments (and lmom::samlmu if installed)
#   4-2. zig_fit == zig_params_from_lmom(zig_lmom); shape == zig_shape_from_lcv
#   4-3. Smooth fit on a stationary record: constant curves at the pooled values
#   4-4. Smooth fit recovers known seasonal l1 and L-CV curves
#   4-5. Fit status codes on edge cases
#   4-6. zig_spline_params: Hosking shape, scale = l1 / shape, status 1 → p_zero 1
#
# Usage: Rscript scripts/test_distributions.R
#        or source("scripts/test_distributions.R") interactively

library(Rcpp)
sourceCpp("src/ecdf.cpp")
sourceCpp("src/zig.cpp")
sourceCpp("src/zig_spline.cpp")
source("R/zig_spline_normals.R")

HAS_ZAGA <- requireNamespace("gamlss.dist", quietly = TRUE)

# ── Shared helpers ─────────────────────────────────────────────────────────────
pass_fail <- function(ok) if (isTRUE(ok)) "[PASS]" else "[FAIL]"

section <- function(title) cat(sprintf("\n\n══%s\n", title))
rule     <- function(n = 104) cat(strrep("-", n), "\n")

TOL <- 1e-10   # machine-precision threshold for double comparisons

# ═══════════════════════════════════════════════════════════════════════════════
# Part 1 — ECDF
# ═══════════════════════════════════════════════════════════════════════════════
cat("╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║  Part 1 — ECDF  (src/ecdf.cpp)                                     ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n")

# ── R reference implementations ────────────────────────────────────────────────

# Forward CDF: zero-inflated type-7, matching C++ ecdf_p().
#   v == 0               → p_zero / 2
#   v >= max(positives)  → p_zero + (1-p_zero) * 1.0 = 1.0
#   v < min(positives)   → p_zero + (1-p_zero) * 0.0 = p_zero
#   v > 0 (interior)     → p_zero + (1-p_zero) * rank_float / (n_pos - 1)
r_ecdf_p <- function(hist_mat, obs) {
  vapply(seq_len(nrow(hist_mat)), function(i) {
    x      <- hist_mat[i, ]
    v      <- obs[i]
    if (is.na(v) || sum(!is.na(x)) < min(10L, length(x))) return(NA_real_)
    x      <- x[!is.na(x)]
    n      <- length(x)
    pos    <- sort(x[x > 0])
    n_pos  <- length(pos)
    p_zero <- sum(x == 0) / n
    if (v == 0)     return(p_zero / 2)
    if (n_pos == 0) return(1.0)
    lo    <- findInterval(v, pos)    # last 1-based index where pos[lo] <= v
    p_adj <- if (lo == 0L) {
      0.0
    } else if (lo >= n_pos) {
      1.0
    } else {
      span <- pos[lo + 1L] - pos[lo]
      frac <- if (span > 0) (v - pos[lo]) / span else 0
      ((lo - 1L) + frac) / (n_pos - 1)
    }
    p_zero + (1 - p_zero) * p_adj
  }, numeric(1))
}

# Inverse CDF: zero-inflated type-7, matching C++ ecdf_q().
r_ecdf_q <- function(hist_mat, probs) {
  t(apply(hist_mat, 1, function(x) {
    n      <- length(x)
    pos    <- sort(x[x > 0])
    n_pos  <- length(pos)
    p_zero <- sum(x == 0) / n
    if (n_pos == 0L) return(ifelse(probs <= 1, 0, NA_real_))
    vapply(probs, function(p) {
      p_adj <- (p - p_zero) / (1 - p_zero)
      if (p_adj < 0) return(0)
      if (p_adj > 1) return(NA_real_)
      quantile(pos, p_adj, type = 7, names = FALSE)
    }, numeric(1))
  }))
}

# ── Configuration ──────────────────────────────────────────────────────────────
ECDF_PROBS  <- c(0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3,
                 0.5, 0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1.0)
ECDF_QNAMES <- sprintf("q%04d", round(ECDF_PROBS * 1000))
SAMPLE_SIZES <- c(5L, 10L, 22L, 50L, 100L)
ZERO_FRACS   <- c(0, 0.1, 0.25, 0.5, 0.75, 0.9)

set.seed(42)
ECDF_POOL_DBL <- sort(round(rgamma(max(SAMPLE_SIZES), shape = 4, rate = 0.2), 4))
ECDF_POOL_INT <- as.integer(round(ECDF_POOL_DBL * 25.4))   # inches → mm

pool_ecdf <- function(dt) if (dt == "double") ECDF_POOL_DBL else ECDF_POOL_INT

make_raw_ecdf <- function(n_zero, pool) {
  c(rep(pool[1L] * 0L, n_zero), pool)
}

# ── Scenario runner (sections 1-1 through 1-3) ─────────────────────────────────
run_ecdf_scenario <- function(n, fz, dt) {
  pool   <- pool_ecdf(dt)[seq_len(n)]
  n_zero <- min(round(fz * n), n)
  n_pos  <- n - n_zero
  raw    <- if (n_pos == 0L) rep(pool[1L] * 0L, n) else make_raw_ecdf(n_zero, pool[seq_len(n_pos)])
  mat    <- matrix(raw, nrow = 1L)

  # 1-1: q
  cpp_q <- ecdf_stats(mat)$quantiles[1L, ]
  r_q   <- r_ecdf_q(mat, ECDF_PROBS)[1L, ]
  max_q <- max(abs(cpp_q - r_q), na.rm = TRUE)

  # 1-2: p
  positives <- sort(unique(raw[raw > 0]))
  above_max <- if (length(positives)) max(positives) * 2 else
    if (dt == "integer") 1L else 1.0
  obs_vals  <- if (dt == "integer") as.integer(c(0, positives, above_max)) else
                                    as.double( c(0, positives, above_max))
  mat_rep   <- mat[rep(1L, length(obs_vals)), , drop = FALSE]
  cpp_p     <- ecdf_p(mat_rep, obs_vals)
  r_p       <- r_ecdf_p(mat_rep, obs_vals)
  max_p     <- max(abs(cpp_p - r_p), na.rm = TRUE)

  # 1-3: round-trip
  if (length(positives) == 0L) {
    max_rt <- NA_real_; pass_rt <- NA
  } else {
    obs_rt <- if (dt == "integer") as.integer(positives) else as.double(positives)
    mat_rt <- mat[rep(1L, length(positives)), , drop = FALSE]
    p_vals <- ecdf_p(mat_rt, obs_rt)
    q_vals <- vapply(p_vals, function(p) ecdf_q(mat, p)[1L, 1L], numeric(1))
    max_rt <- max(abs(q_vals - as.double(positives)), na.rm = TRUE)
    pass_rt <- max_rt < TOL
  }

  list(max_q = max_q, pass_q = max_q < TOL,
       max_p = max_p, pass_p = max_p < TOL,
       max_rt = max_rt, pass_rt = pass_rt)
}

# ── Sections 1-1 through 1-3: sweep ───────────────────────────────────────────
section(" 1-1. ecdf_q  1-2. ecdf_p  1-3. Round-trip ══════════════════════════")
cat(sprintf("%-6s  %-5s  %-7s  %-22s  %-22s  %-24s\n",
            "n", "fz", "type", "1-1. q max|diff|", "1-2. p max|diff|", "1-3. rt max|diff|"))
rule()

ecdf_grand <- TRUE
for (n in SAMPLE_SIZES) {
  for (fz in ZERO_FRACS) {
    for (dt in c("double", "integer")) {
      res <- run_ecdf_scenario(n, fz, dt)
      rt  <- if (is.na(res$max_rt)) "  ------  (no pos)" else
             sprintf("  %.2e  %s", res$max_rt, pass_fail(res$pass_rt))
      cat(sprintf("n=%3d  fz=%3.0f%%  %-7s  %.2e  %s  %.2e  %s  %s\n",
                  n, fz * 100, dt,
                  res$max_q, pass_fail(res$pass_q),
                  res$max_p, pass_fail(res$pass_p), rt))
      ecdf_grand <- ecdf_grand && isTRUE(res$pass_q) && isTRUE(res$pass_p) &&
                   (is.na(res$pass_rt) || isTRUE(res$pass_rt))
    }
  }
  rule()
}
cat(sprintf("Sections 1-1 to 1-3: %s\n", if (ecdf_grand) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 1-4: All-zeros ─────────────────────────────────────────────────────
section(" 1-4. All-zeros edge case ═══════════════════════════════════════════════")
cat("   ecdf_q: p in [0,1] → 0;  p > 1 → NA\n")
cat("   ecdf_p(0) = 0.5;  ecdf_p(pos) = 1.0;  ecdf_mean = 0\n\n")

ecdf_zeros_pass <- TRUE
for (n in SAMPLE_SIZES) {
  for (dt in c("double", "integer")) {
    raw  <- if (dt == "integer") integer(n) else double(n)
    mat  <- matrix(raw, nrow = 1L)
    q_ok <- all(ecdf_stats(mat)$quantiles[1L, ] == 0, na.rm = TRUE)
    na_ok <- is.na(ecdf_q(mat, 1.5)[1L, 1L])
    p0_ok <- isTRUE(all.equal(ecdf_p(mat, if (dt == "integer") 0L else 0.0), 0.5))
    pp_ok <- isTRUE(all.equal(ecdf_p(mat, if (dt == "integer") 100L else 10.0), 1.0))
    mn_ok <- isTRUE(all.equal(ecdf_mean(mat), 0.0))
    ok    <- q_ok && na_ok && p0_ok && pp_ok && mn_ok
    ecdf_zeros_pass <- ecdf_zeros_pass && ok
    cat(sprintf("  n=%3d %-7s: q→0 %s  q(p>1)→NA %s  p(0)=0.5 %s  p(pos)=1 %s  mean=0 %s\n",
                n, dt, pass_fail(q_ok), pass_fail(na_ok), pass_fail(p0_ok),
                pass_fail(pp_ok), pass_fail(mn_ok)))
  }
}
cat(sprintf("Section 1-4: %s\n", if (ecdf_zeros_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 1-5: Integer vs double input equivalence ──────────────────────────
section(" 1-5. Integer vs double input equivalence ══════════════════════════════")
cat("   Integer-valued data passed as integer vs double storage → identical output.\n\n")

ecdf_equiv_pass <- TRUE
for (n in SAMPLE_SIZES) {
  for (fz in ZERO_FRACS) {
    n_zero <- min(round(fz * n), n)
    n_pos  <- n - n_zero
    pool   <- ECDF_POOL_INT[seq_len(n)]   # integer mm values
    raw_i  <- if (n_pos == 0L) integer(n) else
              as.integer(make_raw_ecdf(n_zero, pool[seq_len(n_pos)]))
    raw_d  <- as.double(raw_i)
    mat_i  <- matrix(raw_i, nrow = 1L)
    mat_d  <- matrix(raw_d, nrow = 1L)

    # ecdf_stats quantiles
    dq <- max(abs(ecdf_stats(mat_d)$quantiles - ecdf_stats(mat_i)$quantiles), na.rm = TRUE)
    # ecdf_p (with obs as both types)
    pos  <- sort(unique(raw_i[raw_i > 0]))
    obs_i <- c(0L, as.integer(pos))
    obs_d <- as.double(obs_i)
    dp  <- if (length(obs_i) == 0L) 0 else {
      nr <- length(obs_i)
      max(abs(ecdf_p(mat_d[rep(1L,nr),,drop=FALSE], obs_d) -
              ecdf_p(mat_i[rep(1L,nr),,drop=FALSE], obs_i)), na.rm = TRUE)
    }

    ok <- dq == 0 && dp == 0
    ecdf_equiv_pass <- ecdf_equiv_pass && ok
    cat(sprintf("  n=%3d  fz=%3.0f%%:  ecdf_stats diff=%.2e %s  ecdf_p diff=%.2e %s\n",
                n, fz*100, dq, pass_fail(dq==0), dp, pass_fail(dp==0)))
  }
}
cat(sprintf("Section 1-5: %s\n", if (ecdf_equiv_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 1-6: Diagnostic: ecdf_p(0) = p_zero/2 ─────────────────────────────
section(" 1-6. ecdf_p(0) = p_zero / 2 as p_zero → 1 ════════════════════════════")
cat("   n=100, one fixed positive value, sweeping n_zero 0 → 100.\n\n")
cat(sprintf("  %-8s  %-8s  %-10s  %-12s  %-10s\n",
            "n_zero", "p_zero", "expected", "ecdf_p(0)", "diff"))
cat(sprintf("  %s\n", strrep("-", 54)))

ecdf_diag_pass <- TRUE
for (nz in c(seq(0L, 90L, 10L), 95L, 99L, 100L)) {
  np   <- 100L - nz
  raw  <- c(rep(0.0, nz), rep(10.0, np))
  mat  <- matrix(raw, nrow = 1L)
  pz   <- nz / 100
  exp  <- pz / 2
  act  <- ecdf_p(mat, 0.0)
  diff <- act - exp
  ok   <- isTRUE(all.equal(act, exp))
  ecdf_diag_pass <- ecdf_diag_pass && ok
  cat(sprintf("  %-8d  %-8.4f  %-10.6f  %-12.6f  %-10.2e  %s\n",
              nz, pz, exp, act, diff, pass_fail(ok)))
}
cat(sprintf("Section 1-6: %s\n", if (ecdf_diag_pass) "ALL PASS" else "ONE OR MORE FAIL"))

ecdf_all_pass <- ecdf_grand && ecdf_zeros_pass && ecdf_equiv_pass && ecdf_diag_pass
cat(sprintf("\n▶ Part 1 (ECDF): %s\n", if (ecdf_all_pass) "ALL PASS" else "ONE OR MORE FAIL"))


# ═══════════════════════════════════════════════════════════════════════════════
# Part 2 — ZIG
# ═══════════════════════════════════════════════════════════════════════════════
cat("\n\n╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║  Part 2 — ZIG  (src/zig.cpp)                                       ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n")

if (HAS_ZAGA) cat("gamlss.dist available — ZAGA equivalence enabled\n")

# ── R reference implementations ────────────────────────────────────────────────
r_zig_p_param <- function(shape, scale, p_zero, v)
  p_zero + (1 - p_zero) * pgamma(v, shape = shape, scale = scale)

r_zig_q <- function(shape, scale, p_zero, probs)
  vapply(probs, function(p) {
    p_adj <- (p - p_zero) / (1 - p_zero)
    if (p_adj <= 0) return(0.0)
    if (p_adj >= 1) return(NA_real_)
    qgamma(p_adj, shape = shape, scale = scale)
  }, numeric(1))

r_zig_p_fallback <- function(raw, obs)
  vapply(obs, function(v) {
    mat <- matrix(raw, nrow = 1L)
    r_ecdf_p(mat, v)
  }, numeric(1))

r_zig_q_fallback <- function(raw, probs) {
  # Matches zig_q convention: p_adj <= 0 (inclusive) maps to 0.
  # r_ecdf_q uses strict p_adj < 0, so we handle the boundary here.
  n <- length(raw); pos <- sort(raw[raw > 0]); n_pos <- length(pos)
  p_zero <- sum(raw == 0) / n
  vapply(probs, function(p) {
    if (n_pos == 0) return(if (p <= 1) 0.0 else NA_real_)
    p_adj <- (p - p_zero) / (1 - p_zero)
    if (p_adj <= 0) return(0.0)
    if (p_adj >= 1) return(NA_real_)
    quantile(pos, p_adj, type = 7, names = FALSE)
  }, numeric(1))
}

# ── Configuration ──────────────────────────────────────────────────────────────
ZIG_PROBS  <- c(0.0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3,
                0.5, 0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1.0)
ZIG_QNAMES <- sprintf("q%04d", round(ZIG_PROBS * 1000))
ZIG_SIZES  <- c(10L, 22L, 50L, 100L)

set.seed(42)
ZIG_POOL <- sort(round(rgamma(max(ZIG_SIZES), shape = 3, scale = 10), 2))  # mm

run_zig_scenario <- function(n, fz) {
  n_zero <- min(round(fz * n), n)
  n_pos  <- n - n_zero
  raw    <- c(rep(0.0, n_zero), ZIG_POOL[seq_len(max(n_pos, 0L))])
  mat    <- matrix(raw, nrow = 1L)
  params <- zig_fit(mat)
  shape  <- params[1L, 1L]; scale <- params[1L, 2L]; pz <- params[1L, 3L]
  param  <- !is.na(shape) && !is.na(scale)
  pos    <- sort(unique(raw[raw > 0]))

  # 2-1: zig_p
  above  <- if (length(pos)) max(pos) * 2 else 100.0
  obs    <- c(0.0, pos, above)
  nr     <- length(obs)
  pr     <- params[rep(1L, nr), , drop = FALSE]
  mr     <- mat[rep(1L, nr), , drop = FALSE]
  cpp_p  <- zig_p(pr, obs, mr)
  r_p    <- if (param) vapply(obs, function(v) {
    if (v == 0) pz / 2 else r_zig_p_param(shape, scale, pz, v)
  }, numeric(1)) else r_zig_p_fallback(raw, obs)
  max_p  <- max(abs(cpp_p - r_p), na.rm = TRUE)

  # 2-2: zig_q
  cpp_q    <- zig_q(params, ZIG_PROBS, mat)[1L, ]
  r_q      <- if (param) r_zig_q(shape, scale, pz, ZIG_PROBS) else
                         r_zig_q_fallback(raw, ZIG_PROBS)
  max_q    <- max(abs(cpp_q - r_q), na.rm = TRUE)
  na_match <- identical(is.na(cpp_q), is.na(r_q))

  # 2-3: round-trip (parametric fits only)
  if (!param || length(pos) == 0L) {
    max_rt <- NA_real_; pass_rt <- NA
  } else {
    p_rt   <- zig_p(params[rep(1L, length(pos)), , drop=FALSE], pos,
                    mat[rep(1L, length(pos)), , drop=FALSE])
    q_rt   <- vapply(p_rt, function(p) zig_q(params, p, mat)[1L, 1L], numeric(1))
    max_rt <- max(abs(q_rt - pos), na.rm = TRUE)
    pass_rt <- max_rt < TOL
  }

  list(param = param, n_zero = n_zero, n_pos = n_pos,
       max_p = max_p, pass_p = max_p < TOL,
       max_q = max_q, pass_q = max_q < TOL,
       na_match = na_match, pass_na = isTRUE(na_match),
       max_rt = max_rt, pass_rt = pass_rt)
}

# ── Sections 2-1 through 2-3: sweep ───────────────────────────────────────────
section(" 2-1. zig_p  2-2. zig_q  2-3. Round-trip ════════════════════════════")
cat(sprintf("%-6s  %-5s  %-10s  %-22s  %-22s  %-26s\n",
            "n", "fz", "path", "2-1. p max|diff|", "2-2. q max|diff|", "2-3. rt max|diff|"))
rule()

zig_grand <- TRUE
for (n in ZIG_SIZES) {
  for (fz in ZERO_FRACS) {
    res  <- run_zig_scenario(n, fz)
    path <- if (res$param) "parametric" else "fallback  "
    rt   <- if (is.na(res$max_rt)) "  ------  (no pos/fallback)" else
            sprintf("  %.2e  %s", res$max_rt, pass_fail(res$pass_rt))
    cat(sprintf("n=%3d  fz=%3.0f%%  %s  %.2e  %s  %.2e  %s  NA-match %s%s\n",
                n, fz*100, path,
                res$max_p, pass_fail(res$pass_p),
                res$max_q, pass_fail(res$pass_q),
                pass_fail(res$pass_na), rt))
    zig_grand <- zig_grand && isTRUE(res$pass_p) && isTRUE(res$pass_q) &&
                isTRUE(res$pass_na) &&
                (is.na(res$pass_rt) || isTRUE(res$pass_rt))
  }
  rule()
}
cat(sprintf("Sections 2-1 to 2-3: %s\n", if (zig_grand) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 2-4: ZAGA equivalence ─────────────────────────────────────────────
section(" 2-4. ZAGA equivalence (gamlss.dist::ZAGA) ══════════════════════════════")
if (!HAS_ZAGA) {
  cat("   gamlss.dist not installed — skipped.\n")
  zig_zaga_pass <- TRUE
} else {
  raw_z  <- c(rep(0.0, 6), ZIG_POOL[seq_len(16)])   # n=22, fz≈0.27
  mat_z  <- matrix(raw_z, nrow = 1L)
  par_z  <- zig_fit(mat_z)
  sh     <- par_z[1L,1L]; sc <- par_z[1L,2L]; pz_z <- par_z[1L,3L]
  mu_z   <- sh * sc; sig_z <- 1 / sqrt(sh)

  cat(sprintf("\n  Fitted: shape=%.4f scale=%.4f p_zero=%.4f\n", sh, sc, pz_z))
  cat(sprintf("  ZAGA:   mu=%.4f  sigma=%.4f  nu=%.4f\n\n", mu_z, sig_z, pz_z))

  pos_z  <- sort(unique(raw_z[raw_z > 0]))
  r_pf   <- vapply(pos_z, function(v) r_zig_p_param(sh, sc, pz_z, v), numeric(1))
  za_pf  <- gamlss.dist::pZAGA(pos_z, mu=mu_z, sigma=sig_z, nu=pz_z)
  diff_pz <- max(abs(r_pf - za_pf), na.rm=TRUE)

  probs_pos <- ZIG_PROBS[ZIG_PROBS > pz_z & ZIG_PROBS < 1.0]
  r_qf   <- r_zig_q(sh, sc, pz_z, probs_pos)
  za_qf  <- vapply(probs_pos, function(p)
    gamlss.dist::qZAGA(p, mu=mu_z, sigma=sig_z, nu=pz_z), numeric(1))
  diff_qz <- max(abs(r_qf - za_qf), na.rm=TRUE)

  cat(sprintf("  pZAGA vs R formula (%d positive obs): max|diff|=%.2e  %s\n",
              length(pos_z), diff_pz, pass_fail(diff_pz < TOL)))
  cat(sprintf("  qZAGA vs R formula (%d probs>p_zero): max|diff|=%.2e  %s\n",
              length(probs_pos), diff_qz, pass_fail(diff_qz < TOL)))
  cat(sprintf("  Note: pZAGA(0)=%.4f (=nu), zig_p(0)=%.4f (=nu/2, mid-prob)\n",
              pz_z, pz_z/2))
  zig_zaga_pass <- diff_pz < TOL && diff_qz < TOL
  cat(sprintf("Section 2-4: %s\n", if (zig_zaga_pass) "ALL PASS" else "ONE OR MORE FAIL"))
}

# ── Section 2-5: All-zeros ─────────────────────────────────────────────────────
section(" 2-5. All-zeros edge case ═══════════════════════════════════════════════")
cat("   zig_p(0)=0.5;  zig_p(pos)=1.0\n")
cat("   zig_q(0)=0;    zig_q(p in (0,1))=0;  zig_q(1)=0\n\n")

zig_zeros_pass <- TRUE
for (n in ZIG_SIZES) {
  raw  <- rep(0.0, n); mat <- matrix(raw, nrow=1L)
  par  <- zig_fit(mat)
  p0   <- zig_p(par, 0.0, mat);  ok_p0 <- isTRUE(all.equal(p0, 0.5))
  pp   <- zig_p(par, 10.0, mat); ok_pp <- isTRUE(all.equal(pp, 1.0))
  q0   <- zig_q(par, 0.0, mat)[1L,1L]; ok_q0 <- isTRUE(q0 == 0)
  qm   <- zig_q(par, 0.5, mat)[1L,1L]; ok_qm <- isTRUE(qm == 0)
  q1   <- zig_q(par, 1.0, mat)[1L,1L]; ok_q1 <- isTRUE(q1 == 0)
  ok   <- ok_p0 && ok_pp && ok_q0 && ok_qm && ok_q1
  zig_zeros_pass <- zig_zeros_pass && ok
  cat(sprintf("  n=%3d: p(0)=0.5 %s  p(pos)=1 %s  q(0)=0 %s  q(0.5)=0 %s  q(1)=0 %s\n",
              n, pass_fail(ok_p0), pass_fail(ok_pp), pass_fail(ok_q0),
              pass_fail(ok_qm), pass_fail(ok_q1)))
}
cat(sprintf("Section 2-5: %s\n", if (zig_zeros_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 2-6: Integer vs double input equivalence ──────────────────────────
section(" 2-6. Integer vs double input equivalence ══════════════════════════════")
cat("   Integer mm input vs equivalent double input → identical output.\n\n")

zig_equiv_pass <- TRUE
for (n in ZIG_SIZES) {
  for (fz in ZERO_FRACS) {
    n_zero <- min(round(fz * n), n)
    n_pos  <- n - n_zero
    # Use integer mm values directly
    pool_i <- as.integer(round(ZIG_POOL[seq_len(n)] * 1))   # already ~mm scale
    raw_i  <- if (n_pos == 0L) integer(n) else
              as.integer(c(rep(0L, n_zero), pool_i[seq_len(n_pos)]))
    raw_d  <- as.double(raw_i)
    mat_i  <- matrix(raw_i, nrow = 1L)
    mat_d  <- matrix(raw_d, nrow = 1L)

    par_i  <- zig_fit(mat_i)
    par_d  <- zig_fit(mat_d)
    d_fit  <- max(abs(par_i - par_d), na.rm = TRUE)

    pos    <- sort(unique(raw_i[raw_i > 0]))
    obs_i  <- c(0L, as.integer(pos))
    obs_d  <- as.double(obs_i)
    nr     <- length(obs_i)
    d_p    <- if (nr == 0L) 0 else
      max(abs(zig_p(par_d[rep(1L,nr),,drop=FALSE], obs_d, mat_d[rep(1L,nr),,drop=FALSE]) -
              zig_p(par_i[rep(1L,nr),,drop=FALSE], obs_i, mat_i[rep(1L,nr),,drop=FALSE])),
          na.rm = TRUE)
    d_q    <- max(abs(zig_q(par_d, ZIG_PROBS, mat_d) -
                      zig_q(par_i, ZIG_PROBS, mat_i)), na.rm = TRUE)

    ok <- d_fit == 0 && d_p == 0 && d_q == 0
    zig_equiv_pass <- zig_equiv_pass && ok
    cat(sprintf("  n=%3d  fz=%3.0f%%:  fit diff=%.2e %s  zig_p diff=%.2e %s  zig_q diff=%.2e %s\n",
                n, fz*100, d_fit, pass_fail(d_fit==0),
                d_p, pass_fail(d_p==0), d_q, pass_fail(d_q==0)))
  }
}
cat(sprintf("Section 2-6: %s\n", if (zig_equiv_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 2-7: Diagnostic: zig_p(0) = p_zero/2 ──────────────────────────────
section(" 2-7. zig_p(0) = p_zero / 2 as p_zero → 1 ══════════════════════════════")
cat("   n=100, one fixed positive value, sweeping n_zero 0 → 100.\n\n")
cat(sprintf("  %-8s  %-8s  %-10s  %-12s  %-10s\n",
            "n_zero", "p_zero", "expected", "zig_p(0)", "diff"))
cat(sprintf("  %s\n", strrep("-", 54)))

zig_diag_pass <- TRUE
for (nz in c(seq(0L, 90L, 10L), 95L, 99L, 100L)) {
  np   <- 100L - nz
  raw  <- c(rep(0.0, nz), rep(30.0, np))
  mat  <- matrix(raw, nrow = 1L)
  par  <- zig_fit(mat)
  pz   <- par[1L, 3L]
  exp  <- pz / 2
  act  <- zig_p(par, 0.0, mat)
  diff <- act - exp
  ok   <- isTRUE(all.equal(act, exp))
  zig_diag_pass <- zig_diag_pass && ok
  cat(sprintf("  %-8d  %-8.4f  %-10.6f  %-12.6f  %-10.2e  %s\n",
              nz, pz, exp, act, diff, pass_fail(ok)))
}
cat(sprintf("Section 2-7: %s\n", if (zig_diag_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 2-8: Boundary quantiles ───────────────────────────────────────────
section(" 2-8. Boundary quantiles: q0000 (p=0) and q1000 (p=1) ══════════════════")
cat("   q0000 = 0 always (lower bound of gamma support / point mass)\n")
cat("   q1000 = NA when positives present (infinite upper tail)\n")
cat("   q1000 = 0  when all-zeros (point mass at 0)\n\n")

zig_boundary_pass <- TRUE
for (n in ZIG_SIZES) {
  for (fz in ZERO_FRACS) {
    n_zero <- min(round(fz * n), n)
    n_pos  <- n - n_zero
    raw    <- c(rep(0.0, n_zero), ZIG_POOL[seq_len(max(n_pos, 0L))])
    mat    <- matrix(raw, nrow = 1L)
    par    <- zig_fit(mat)

    q0 <- zig_q(par, 0.0, mat)[1L, 1L]
    q1 <- zig_q(par, 1.0, mat)[1L, 1L]

    ok_q0 <- isTRUE(q0 == 0.0)
    ok_q1 <- if (n_pos == 0L) isTRUE(q1 == 0.0) else is.na(q1)
    ok    <- ok_q0 && ok_q1
    zig_boundary_pass <- zig_boundary_pass && ok

    q1_label <- if (n_pos == 0L) sprintf("%.4g (all-zeros)", q1) else
                if (is.na(q1))   "NA (has pos)" else
                                  sprintf("%.4g (!= NA)", q1)
    cat(sprintf("  n=%3d  fz=%3.0f%%  n_pos=%3d  q0000=%.4g %s  q1000=%s %s\n",
                n, fz*100, n_pos, q0, pass_fail(ok_q0), q1_label, pass_fail(ok_q1)))
  }
  rule()
}
cat(sprintf("Section 2-8: %s\n", if (zig_boundary_pass) "ALL PASS" else "ONE OR MORE FAIL"))

zig_all_pass <- zig_grand && zig_zaga_pass && zig_zeros_pass && zig_equiv_pass &&
                zig_diag_pass && zig_boundary_pass
cat(sprintf("\n▶ Part 2 (ZIG): %s\n", if (zig_all_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ═══════════════════════════════════════════════════════════════════════════════
# Part 3 — NA years
# ═══════════════════════════════════════════════════════════════════════════════
cat("\n╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║  Part 3 — NA years  (src/ecdf_impl.h, both distributions)            ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n")

# Every function on a row, so a row with NA years can be compared with the
# same row with those years dropped.
all_outputs <- function(x, obs) {
  mat <- matrix(x, nrow = 1L)
  par <- zig_fit(mat)
  list(ecdf_q = ecdf_q(mat, ZIG_PROBS), ecdf_p = ecdf_p(mat, obs), ecdf_mean = ecdf_mean(mat),
       zig_fit = par, zig_q = zig_q(par, ZIG_PROBS, mat), zig_p = zig_p(par, obs, mat),
       zig_mean = zig_mean(par, mat))
}
is_all_na <- function(out) all(vapply(out, \(v) all(is.na(v)), logical(1)))

# ── Section 3-1: NA years are dropped ─────────────────────────────────────────
section(" 3-1. Row with NA years == row with those years dropped ═══════════════")
na_drop_pass <- TRUE
for (n in c(22L, 30L)) {
  for (fz in c(0, 0.3, 0.9)) {          # 0.9 leaves < 4 positives: ZIG fallback
    for (n_na in c(1L, 5L)) {
      n_zero <- round(fz * n)
      x      <- sample(c(rep(0.0, n_zero), ZIG_POOL[seq_len(n - n_zero)]))
      na_at  <- sample(n, n_na)
      x_na   <- replace(x, na_at, NA_real_)
      obs    <- c(0, median(ZIG_POOL))
      ok     <- isTRUE(all.equal(all_outputs(x_na, obs[1]), all_outputs(x[-na_at], obs[1]))) &&
                isTRUE(all.equal(all_outputs(x_na, obs[2]), all_outputs(x[-na_at], obs[2])))
      na_drop_pass <- na_drop_pass && ok
      cat(sprintf("  n=%3d  fz=%3.0f%%  NA years=%d  %s\n", n, fz * 100, n_na, pass_fail(ok)))
    }
  }
}
cat(sprintf("Section 3-1: %s\n", if (na_drop_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 3-2: Minimum valid years ──────────────────────────────────────────
section(" 3-2. Minimum valid years: min(10, record length) ══════════════════════")
x22 <- ZIG_POOL[seq_len(22)]
cases <- list(
  list(label = "22 years, 10 valid  → used", x = replace(x22, 1:12, NA), na = FALSE),
  list(label = "22 years,  9 valid  → NA  ", x = replace(x22, 1:13, NA), na = TRUE),
  list(label = " 5 years,  5 valid  → used", x = x22[1:5],               na = FALSE),
  list(label = " 5 years,  4 valid  → NA  ", x = replace(x22[1:5], 1, NA), na = TRUE),
  list(label = "22 years,  0 valid  → NA  ", x = rep(NA_real_, 22),       na = TRUE)
)
na_min_pass <- TRUE
for (cs in cases) {
  out <- all_outputs(cs$x, 10)
  ok  <- if (cs$na) is_all_na(out) else !anyNA(c(out$ecdf_mean, out$zig_fit[1L, 3L], out$ecdf_q[1L, 10L]))
  na_min_pass <- na_min_pass && ok
  cat(sprintf("  %s  %s\n", cs$label, pass_fail(ok)))
}
cat(sprintf("Section 3-2: %s\n", if (na_min_pass) "ALL PASS" else "ONE OR MORE FAIL"))

na_all_pass <- na_drop_pass && na_min_pass
cat(sprintf("\n▶ Part 3 (NA years): %s\n", if (na_all_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ═══════════════════════════════════════════════════════════════════════════════
# Part 4 — ZIG chain and ZIG-smooth
# ═══════════════════════════════════════════════════════════════════════════════
cat("\n╔══════════════════════════════════════════════════════════════════════╗\n")
cat("║  Part 4 — ZIG chain and ZIG-smooth  (zig.cpp, zig_spline.cpp)       ║\n")
cat("╚══════════════════════════════════════════════════════════════════════╝\n")

# Unbiased sample L-moments of the positive values (Hosking 1990, PWM form).
r_lmom <- function(x) {
  v <- sort(x[!is.na(x) & x > 0]); n <- length(v)
  out <- c(n = sum(!is.na(x)), z = sum(x == 0, na.rm = TRUE), l1 = NA, lcv = NA)
  if (n < 4) return(out)
  b0 <- mean(v); b1 <- sum((seq_len(n) - 1) / (n - 1) * v) / n
  l2 <- 2 * b1 - b0
  if (l2 > 0 && b0 > 0) out[c("l1", "lcv")] <- c(b0, l2 / b0)
  out
}

# ── Section 4-1: zig_lmom ─────────────────────────────────────────────────────
section(" 4-1. zig_lmom vs R reference L-moments ════════════════════════════════")
rows <- list(ZIG_POOL[1:22], c(0, 0, ZIG_POOL[1:20]), replace(ZIG_POOL[1:22], c(3, 9), NA),
             c(rep(0, 19), ZIG_POOL[1:3]), rep(0, 22), c(rep(0, 18), 5, 5, 5, 5))
mat4 <- do.call(rbind, rows)
lm4  <- zig_lmom(mat4)
ref4 <- t(vapply(rows, r_lmom, numeric(4)))
lmom_pass <- isTRUE(all.equal(unname(lm4), unname(ref4), tolerance = TOL)) &&
             identical(colnames(lm4), c("n", "z", "l1", "lcv"))
cat(sprintf("  R reference (6 rows: zeros, NA years, <4 positives, all zero, ties)  %s\n", pass_fail(lmom_pass)))
if (requireNamespace("lmom", quietly = TRUE)) {
  L <- lmom::samlmu(ZIG_POOL[1:22])
  ok <- isTRUE(all.equal(unname(lm4[1, 3:4]), unname(c(L[[1]], L[[2]] / L[[1]])), tolerance = TOL))
  lmom_pass <- lmom_pass && ok
  cat(sprintf("  lmom::samlmu                                                       %s\n", pass_fail(ok)))
}
cat(sprintf("Section 4-1: %s\n", if (lmom_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 4-2: the chain ────────────────────────────────────────────────────
section(" 4-2. zig_fit == zig_params_from_lmom(zig_lmom) ═════════════════════════")
mat42 <- t(replicate(200, {
  x <- sample(c(rep(0, sample(0:20, 1)), ZIG_POOL))[1:22]
  replace(x, sample(22, sample(0:14, 1)), NA)
}))
chain <- zig_params_from_lmom(zig_lmom(mat42), ncol(mat42))
chain_pass <- identical(chain, zig_fit(mat42))
cat(sprintf("  200 random rows (zeros, NA years, too few valid)  %s\n", pass_fail(chain_pass)))
lm42 <- zig_lmom(mat42); has <- !is.na(chain[, 1])
ok <- identical(zig_shape_from_lcv(lm42[has, "lcv"]), chain[has, 1]) &&
      isTRUE(all.equal(chain[has, 1] * chain[has, 2], lm42[has, "l1"], tolerance = TOL))
chain_pass <- chain_pass && ok
cat(sprintf("  shape == zig_shape_from_lcv(lcv); shape * scale == l1  %s\n", pass_fail(ok)))
cat(sprintf("Section 4-2: %s\n", if (chain_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Smooth-fit helpers ────────────────────────────────────────────────────────
SPLINE_B <- zig_spline_basis()
day_stats <- function(arr) {          # arr: n_pix x 365 x n_years
  ss <- lapply(seq_len(dim(arr)[2]), \(d) zig_spline_suffstats(arr[, d, , drop = TRUE] |> matrix(dim(arr)[1])))
  lapply(c(n = "n", z = "z", l1 = "l1", lcv = "lcv"), \(v) matrix(sapply(ss, \(m) m[, v]), dim(arr)[1]))
}
curve <- \(fit, part, i = 1) drop(SPLINE_B$X %*% fit$coef[i, (part - 1) * SPLINE_B$k + seq_len(SPLINE_B$k)])

# ── Section 4-3: stationary record ────────────────────────────────────────────
section(" 4-3. Stationary record → constant curves at the pooled values ═══════════")
arr <- array(rep(ZIG_POOL[1:22], each = 365), c(1, 365, 22))     # same 22 values every day
st  <- day_stats(arr); fit <- zig_spline_fit_stats(st, SPLINE_B)
l   <- r_lmom(ZIG_POOL[1:22])
ok_l1  <- isTRUE(all.equal(exp(curve(fit, 2)), rep(l[["l1"]], 365), tolerance = 1e-8))
ok_lcv <- isTRUE(all.equal(exp(curve(fit, 3)), rep(l[["lcv"]], 365), tolerance = 1e-8))
ok_st  <- fit$status == 0L && plogis(max(curve(fit, 1))) < 1e-3
stat_pass <- ok_l1 && ok_lcv && ok_st
cat(sprintf("  l1 constant at sample l1    %s\n", pass_fail(ok_l1)))
cat(sprintf("  L-CV constant at sample L-CV %s\n", pass_fail(ok_lcv)))
cat(sprintf("  status 0, p_zero ~ 0        %s\n", pass_fail(ok_st)))
cat(sprintf("Section 4-3: %s\n", if (stat_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 4-4: seasonal recovery ────────────────────────────────────────────
section(" 4-4. Recovers known seasonal l1 and L-CV (gamma, 60 years) ═════════════")
set.seed(4)
day <- 1:365
true_l1  <- 200 + 150 * sin(2 * pi * day / 365)
true_lcv <- 0.25 + 0.1 * cos(2 * pi * day / 365)
true_sh  <- zig_shape_from_lcv(true_lcv)
arr <- array(NA_real_, c(1, 365, 60))
for (d in day) arr[1, d, ] <- rgamma(60, shape = true_sh[d], scale = true_l1[d] / true_sh[d])
fit <- zig_spline_fit_stats(day_stats(arr), SPLINE_B)
err_l1  <- max(abs(exp(curve(fit, 2)) / true_l1 - 1))
err_lcv <- max(abs(exp(curve(fit, 3)) / true_lcv - 1))
rec_pass <- fit$status == 0L && err_l1 < 0.05 && err_lcv < 0.08
cat(sprintf("  max relative error: l1 %.3f (< 0.05), L-CV %.3f (< 0.08)  %s\n", err_l1, err_lcv, pass_fail(rec_pass)))
cat(sprintf("Section 4-4: %s\n", if (rec_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 4-5: status codes ─────────────────────────────────────────────────
section(" 4-5. Fit status codes ═══════════════════════════════════════════════════")
mk <- function(f) { a <- array(0, c(1, 365, 22)); for (d in 1:365) a[1, d, ] <- f(d); a }
seasonal  <- mk(\(d) if (d > 60 && d < 270) ZIG_POOL[1:22] else rep(0, 22))      # snow 209 days
few_pos   <- mk(\(d) if (d == 150) c(ZIG_POOL[1:3], rep(0, 19)) else rep(0, 22)) # 3 positives
no_lmom   <- mk(\(d) if (d %% 30 == 0) c(ZIG_POOL[1:3], rep(0, 19)) else rep(0, 22)) # 36 positives, never 4 a day
few_days  <- mk(\(d) if (d >= 150 && d < 160) ZIG_POOL[1:22] else rep(0, 22))   # 10 days with L-moments
cases <- list(
  list(label = "seasonal snowpack            → 0", arr = seasonal,                 status = 0L),
  list(label = "no snow on record            → 1", arr = mk(\(d) rep(0, 22)),      status = 1L),
  list(label = "fewer than 10 positives      → 2", arr = few_pos,                  status = 2L),
  list(label = "no day with 4 positive years → 2", arr = no_lmom,                  status = 2L),
  list(label = "no valid years               → 3", arr = mk(\(d) rep(NA, 22)),     status = 3L),
  list(label = "10 days with L-moments       → 5", arr = few_days,                 status = 5L)
)
status_pass <- TRUE
for (cs in cases) {
  st <- day_stats(cs$arr); st$n[is.na(st$n)] <- 0
  fit <- zig_spline_fit_stats(st, SPLINE_B)
  ok  <- fit$status == cs$status
  if (cs$status == 5L) ok <- ok && diff(range(curve(fit, 2))) < 1e-10 && diff(range(curve(fit, 3))) < 1e-10
  if (cs$status %in% c(1L, 2L, 3L)) ok <- ok && all(is.na(fit$coef[1, SPLINE_B$k + 1:(2 * SPLINE_B$k)]))
  status_pass <- status_pass && ok
  cat(sprintf("  %s  (got %d)  %s\n", cs$label, fit$status, pass_fail(ok)))
}
cat(sprintf("Section 4-5: %s\n", if (status_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Section 4-6: zig_spline_params ────────────────────────────────────────────
section(" 4-6. zig_spline_params ═════════════════════════════════════════════════")
k <- SPLINE_B$k
coefs <- rbind(c(rep(-3, k), rep(log(300), k), rep(log(0.2), k)),
               c(rep(-3, k), rep(log(50), k),  rep(log(5), k)),         # L-CV above range: clamped
               c(rep(0, k),  rep(NA, 2 * k)))                           # no snow on record
pr <- zig_spline_params(coefs, SPLINE_B, status = c(0L, 0L, 1L))
ok1 <- isTRUE(all.equal(pr$shape[1, ], rep(zig_shape_from_lcv(0.2), 365))) &&
       isTRUE(all.equal(pr$shape[1, ] * pr$scale[1, ], rep(300, 365))) &&
       isTRUE(all.equal(pr$p_zero[1, ], rep(plogis(-3), 365)))
ok2 <- isTRUE(all.equal(pr$shape[2, ], rep(zig_shape_from_lcv(ZIG_SMOOTH_LCV_RANGE[2]), 365)))
ok3 <- all(pr$p_zero[3, ] == 1)
params_pass <- ok1 && ok2 && ok3
cat(sprintf("  shape = Hosking(L-CV), shape * scale = l1, p_zero = plogis  %s\n", pass_fail(ok1)))
cat(sprintf("  L-CV clamped to ZIG_SMOOTH_LCV_RANGE                       %s\n", pass_fail(ok2)))
cat(sprintf("  status 1 → p_zero 1                                        %s\n", pass_fail(ok3)))
cat(sprintf("Section 4-6: %s\n", if (params_pass) "ALL PASS" else "ONE OR MORE FAIL"))

smooth_all_pass <- lmom_pass && chain_pass && stat_pass && rec_pass && status_pass && params_pass
cat(sprintf("\n▶ Part 4 (ZIG chain and ZIG-smooth): %s\n", if (smooth_all_pass) "ALL PASS" else "ONE OR MORE FAIL"))

# ── Grand summary ──────────────────────────────────────────────────────────────
cat(sprintf("\n%s\n",
            if (ecdf_all_pass && zig_all_pass && na_all_pass && smooth_all_pass) "═══ ALL TESTS PASS ═══" else
              "═══ ONE OR MORE TESTS FAILED ═══"))
