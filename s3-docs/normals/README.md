# SNOTEL SWE normals and percentiles

For every station and day, the distribution of snow water equivalent (SWE) on that calendar
day in the reference years, where each day's observed SWE falls in it, and an outlook of
the likely SWE for the rest of the water year. The normals' methods are those of the SNODAS
normals at `data2.climate.umt.edu/snodas/normals/`, applied to each station's own record.

A water year runs Oct 1–Sep 30 and is named for the year it ends in ("WY" in the plots,
`wy2027` in file names). A water year's normals are built once, on Oct 1, and do not change
during that year.

## Periods

| `<period>` | Reference water years | WY2027 |
|------------|-----------------------|--------|
| `30yr` | The 30 before the water year | 1997–2026 |
| `snodas` | Those the SNODAS normals use: from WY2004 or 30 back, whichever is later | 2004–2026 |
| `por` | The station's whole record before the water year | varies |

A day's reference values are the same calendar day in each reference year (Feb 29 uses Feb
28). Years without a value are skipped. A day needs at least 10 valid years (every year, in
a period shorter than 10), so stations with a short record have empty normals.

## Layout

| Path | Contents |
|------|----------|
| `<period>/wy<YYYY>/normals.parquet` | Every station, flavor and day of the water year |
| `<period>/wy<YYYY>/by_station/<station>.parquet` | The same, one file per station (`901_MT_SNTL`) |
| `<period>/wy<YYYY>/provenance.json` | Reference years, station counts, build time |
| `<period>/wy<YYYY>/zig_smooth_coef.parquet` | `zig_smooth` spline coefficients per station: `nu_01`–`nu_24`, `l1_01`–`l1_24`, `lcv_01`–`lcv_24` |
| `<period>/wy<YYYY>/zig_smooth_diagnostics.parquet` | Fit status, λ and effective degrees of freedom per station |
| `<period>/wy<YYYY>/zig_smooth_basis.csv`, `zig_smooth_model.json` | The spline basis (cycle days 1–365, Oct 1 = 1) and how to rebuild the curves |
| `<period>/observed/wy<YYYY>.parquet` | Every station's observed SWE and percentiles for the water year, to date, rewritten daily |
| `<period>/outlook/wy<YYYY>/<YYYY-MM-DD>.parquet` | The outlook issued on that date, to Sep 30, every station and flavor; one file per day, all kept |
| `reference/wy<YYYY>.parquet` | The SWE record (`triplet`, `date`, `wteq`) the water year's normals were built from, frozen on Oct 1 |

Daily percentiles are computed against the frozen `reference/` record, so NRCS edits to
past years do not move a water year's normals.

## Flavors

All three treat SWE as zero-inflated: P(SWE = 0) = p0, and for SWE > 0 the CDF is
p0 + (1 − p0)·F(SWE).

| `<flavor>` | Name | F |
|------------|------|---|
| `ecdf` | Empirical | Empirical CDF of the positive reference values (type 7). |
| `zig` | Fitted | Gamma fit by L-moments; empirical where a day has fewer than 4 positive values. |
| `zig_smooth` | Smoothed | The `zig` fit smoothed through the year: each day's zero fraction and L-moments are fit with cyclic P-splines in day of water year, then converted to gamma parameters as in `zig`. |

## Columns

| Column | Contents |
|--------|----------|
| `flavor` | `ecdf`, `zig` or `zig_smooth` |
| `date` | Normals date |
| `triplet` | Station |
| `n_valid` | Reference years with a value on this date |
| `ref_first_wy`, `ref_last_wy` | First and last of those years |
| `mean` | Mean SWE of the distribution, in |
| `zig_shape`, `zig_scale`, `zig_p_zero` | Gamma parameters and P(SWE = 0) (`zig`, `zig_smooth`) |
| `q0000` … `q1000` | SWE quantiles, in |
| `outlook_length`, `outlook_alpha` | The outlook's persistence for an outlook issued on this date (see Outlook) |
| `swe` | Observed SWE, in (`observed/` only) |
| `swe_ptile` | Observed SWE's percentile, 0–100, to 0.01 (`observed/` only) |
| `swe_standardized` | Standardized anomaly, z (`observed/` only) |

- **Percentile:** the observed SWE's CDF value × 100. Zero SWE maps to p0 / 2 × 100, the
  middle of the zero mass, so a station that is always bare on that date reads 50.
- **Standardized anomaly:** the standard normal quantile of the percentile, clamped to ±4.
- **Quantiles** at probabilities 0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5,
  0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1. `q0000` is 0; `q1000` is empty wherever
  SWE can be positive.
- **Percent of median** is `100 × swe / q0500` (undefined where `q0500` is 0).

## Outlook

Each day's outlook gives, for every date from the next day to Sep 30, the likely range of
SWE at each station, read from the flavor's own normals. It is statistical: it carries
today's percentile forward, fading toward normal, and does not use weather forecasts.

- Today's SWE is placed in the flavor's distribution for today: z = Φ⁻¹(percentile),
  clamped to ±4, as `swe_standardized`.
- h days ahead, z is expected to be ρ·z, with spread √(1 − ρ²), where
  ρ = exp(−(h / `outlook_length`)^`outlook_alpha`).
- Each quantile is the flavor's quantile on the target date at the matching probability,
  so the outlook keeps the normals' shape and melts out with them.
- When today's SWE is beyond what the distribution holds (above the reference years'
  maximum for `ecdf`, or past z = ±4), the quantiles are scaled so the range starts at
  today's SWE and relaxes to the normals as ρ fades. With `ecdf` the range is then narrow
  until it does, since no reference year is higher.

`outlook_length` (days) is fitted per station from how its reference years' percentiles
persist. `outlook_alpha` sets how the range widens: near 1 it opens quickly (early winter,
when one storm can change the season), near 2 it starts narrow and fans out (spring
melt). It is calibrated by period, flavor and day of the year, so the outlook's 80% and
50% ranges hold the outcome about 80% and 50% of the time. In a hindcast of 117 stations
over WY2016–2026, built only from the record before each year, they did so at every lead
from 7 to 120 days.

| Column | Contents |
|--------|----------|
| `flavor`, `triplet` | As in the normals |
| `date` | The date the row forecasts |
| `q0000` … `q1000` | SWE quantiles of the outlook, in, to 0.1; `q0000` and `q1000` are read at z = ±4; empty where the date has no normals |
| `p_snow_free` | Chance of no snow on that date |

The plots' likely range is `q0100`–`q0900`. Rows are sorted by station, flavor and date,
about 50 stations per row group. The issue date is in the file name.

## Access

```python
import pandas as pd
base = "https://data2.climate.umt.edu/snotel/normals/snodas/"
n = pd.read_parquet(base + "wy2027/by_station/901_MT_SNTL.parquet")
obs = pd.read_parquet(base + "observed/wy2027.parquet").query("triplet == '901:MT:SNTL'")
season = n.merge(obs, on=["flavor", "date", "triplet"], how="left")
outlook = pd.read_parquet("https://data2.climate.umt.edu/snotel/latest/outlook_snodas.parquet",
                          filters=[("triplet", "==", "901:MT:SNTL")])
```
