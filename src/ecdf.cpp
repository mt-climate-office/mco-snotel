// Vendored from mco-snodas@62fe19a src/ecdf.cpp. Do not edit here: change it
// upstream, then copy it back (see README, "Vendored code").

#include "ecdf_impl.h"

// Zero-inflated empirical distribution, one row per pixel or zone:
//   P(X = 0)  = p_zero                            (fraction of zero years)
//   P(X <= x) = p_zero + (1 - p_zero) * F(x),     x > 0
// where F is the type-7 ECDF of the positive values (R's default quantile()).
// A zero observation maps to the mid-probability p_zero / 2, as in zig_p.
// ecdf_p and ecdf_q are inverses on the positive support; p < p_zero maps to 0.
// NA years are skipped (see build_ecdf_buf). Outputs are doubles.


// [[Rcpp::export]]
NumericVector ecdf_p(NumericMatrix raw, NumericVector obs) {
  // raw: n_pix x n_time reference record; obs: n_pix observed values.

  int n_pix  = raw.nrow();
  int n_time = raw.ncol();

  NumericVector out(n_pix);
  std::vector<double> sorted_pos;
  sorted_pos.reserve(n_time);

  for (int i = 0; i < n_pix; i++) {
    double v = obs[i];
    if (ISNAN(v)) { out[i] = NA_REAL; continue; }

    int n_zero, n_valid;
    if (!build_ecdf_buf(raw, i, sorted_pos, n_zero, n_valid)) { out[i] = NA_REAL; continue; }

    out[i] = ecdf_p_pixel(sorted_pos, n_zero, n_valid, v);
  }

  return out;
}


// [[Rcpp::export]]
NumericMatrix ecdf_q(NumericMatrix raw, NumericVector probs) {
  // raw: n_pix x n_time reference record; probs: requested probabilities.

  int n_pix   = raw.nrow();
  int n_time  = raw.ncol();
  int n_probs = probs.size();

  NumericMatrix out(n_pix, n_probs);
  std::vector<double> sorted_pos;
  sorted_pos.reserve(n_time);

  for (int i = 0; i < n_pix; i++) {
    int n_zero, n_valid;
    if (!build_ecdf_buf(raw, i, sorted_pos, n_zero, n_valid)) {
      for (int k = 0; k < n_probs; k++) out(i, k) = NA_REAL;
      continue;
    }
    for (int k = 0; k < n_probs; k++)
      out(i, k) = ecdf_q_pixel(sorted_pos, n_zero, n_valid, probs[k]);
  }

  return out;
}


// [[Rcpp::export]]
NumericVector ecdf_mean(NumericMatrix raw) {
  // Mean of the valid years, zeros included; NA if too few are valid.

  int n_pix  = raw.nrow();
  int n_time = raw.ncol();
  NumericVector out(n_pix);

  for (int i = 0; i < n_pix; i++) {
    double sum  = 0.0;
    int n_valid = 0;
    for (int j = 0; j < n_time; j++) {
      double h = raw(i, j);
      if (ISNAN(h)) continue;
      sum += h;
      n_valid++;
    }
    out[i] = n_valid < min_valid_years(n_time) ? NA_REAL : sum / n_valid;
  }

  return out;
}


// [[Rcpp::export]]
List ecdf_stats(NumericMatrix raw) {
  // list(mean = n_pix vector, quantiles = n_pix x 19 matrix), in mm.

  NumericVector mean_out = ecdf_mean(raw);
  NumericMatrix quantiles = ecdf_q(
    raw,
    NumericVector::create(0.0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5, 0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1.0)
  );
  colnames(quantiles) = CharacterVector::create(
    "q0000", "q0010", "q0020", "q0025", "q0050", "q0100", "q0200", "q0250", "q0300", "q0500",
    "q0700", "q0750", "q0800", "q0900", "q0950", "q0975", "q0980", "q0990", "q1000"
  );

  return List::create(
    Named("mean")      = mean_out,
    Named("quantiles") = quantiles
  );
}
