# SNOTEL SWE normals

For every station and day of the year, the distribution of snow water equivalent (SWE) on
that calendar day in the reference years. The methods are those of the SNODAS normals
(<https://data2.climate.umt.edu/snodas/gridded/normals/README.md>), applied to each station's own
record. Observed SWE and percentiles against these normals are in `../daily/percentiles/`.

`<period>` names the reference water years by both ends: `wy2004-2026` is WY2004 through
WY2026. A water year runs Oct 1 to Sep 30 and is named for the year it ends in. A period's
normals are built once, when a water year first needs them, and do not change.

## Periods

Each role resolves to one period per water year (see `../README.md`).

| Role | Reference water years | WY2027 |
|------|-----------------------|--------|
| `snodas` | Those the SNODAS normals use: the 30 before, from WY2004 at the earliest | `wy2004-2026` |
| `30yr` | The 30 before the water year | `wy1997-2026` |
| `noaa` | 1991–2020 through WY2031, then 2001–2030 | `wy1991-2020` |
| `por` | The station's whole record before the water year | `wypor-2026` |

A day's reference values are the same calendar day in each reference year (Feb 29 uses Feb
28). Years without a value are skipped. A day needs at least 10 valid years (every year, in
a period shorter than 10), so stations with a short record have empty normals.

## Layout

| Path | Contents |
|------|----------|
| `<period>/normals_<period>.parquet` | Every station, flavor and day |
| `<period>/by_station/<station>_<period>.parquet` | The same, one file per station (`901_MT_SNTL`) |
| `<period>/provenance_<period>.json` | Reference years, station counts, versions, build time |
| `<period>/reference_<period>.parquet` | The SWE record (`triplet`, `date`, `wteq`) the normals were built from, frozen when they were built |

The normals are built from the frozen reference record, so NRCS edits to past years do not
move them.

`provenance_<period>.json` has `layout_version`, `water_year` (the water year it was built
for), `period` (the role it was built for), `reference_water_years`, `reference_record`,
`n_stations`, `n_stations_with_normals`, `min_valid_years`, `flavors`, `units`, `source`,
`methods`, `normals_version` and `built_at`.

## Flavors

All three treat SWE as zero-inflated: P(SWE = 0) = p0, and for SWE > 0 the CDF is
p0 + (1 − p0)·F(SWE).

| `<flavor>` | Plot caption | F |
|------------|--------------|---|
| `empirical` | Empirical History | Empirical CDF of the positive reference values (type 7). |
| `fitted` | Fitted History | Gamma fit by L-moments; empirical where a day has fewer than 4 positive values. |
| `smoothed` | Smoothed History | The `fitted` gamma, smoothed through the year: each day's zero fraction and L-moments are fit with cyclic P-splines in day of water year, then converted to gamma parameters as in `fitted`. |

## Columns

| Column | Contents |
|--------|----------|
| `flavor` | `empirical`, `fitted` or `smoothed` |
| `date` | Normals date, in the water year the period was built for (WY2027 for the folders built in 2026). Match on month and day. |
| `triplet` | Station |
| `n_valid` | Reference years with a value on this day |
| `ref_first_wy`, `ref_last_wy` | First and last of those years |
| `mean` | Mean SWE of the distribution, in |
| `zig_shape`, `zig_scale`, `zig_p_zero` | Gamma shape, scale (in) and P(SWE = 0) (`fitted`, `smoothed`) |
| `q0000` … `q1000` | SWE quantiles, in |

- **Percentile:** the observed SWE's CDF value × 100. Zero SWE maps to p0 / 2 × 100, the
  middle of the zero mass, so a station that is always bare on that date reads 50.
- **Standardized anomaly:** the standard normal quantile of the percentile, clamped to ±4.
- **Quantiles** at probabilities 0, 0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.3, 0.5,
  0.7, 0.75, 0.8, 0.9, 0.95, 0.975, 0.98, 0.99, 1. `q0000` is 0; `q1000` is empty wherever
  SWE can be positive.
- **Percent of median** is `100 × swe / q0500` (undefined where `q0500` is 0).

## Access

```python
import pandas as pd
base = "https://data2.climate.umt.edu/snotel/"
n = pd.read_parquet(base + "normals/wy2004-2026/by_station/901_MT_SNTL_wy2004-2026.parquet")
obs = pd.read_parquet(base + "daily/percentiles/wy2004-2026/percentiles_wy2004-2026_wy2027.parquet")
season = n.merge(obs.query("triplet == '901:MT:SNTL'"), on=["flavor", "date", "triplet"], how="left")
```
