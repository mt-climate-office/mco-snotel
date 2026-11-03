# SNOTEL daily station data, SWE normals and percentiles

Daily data from every NRCS SNOTEL station, active and retired, with SWE normals,
percentiles and plots, processed by the Montana Climate Office. Updated daily by a run that
starts at 10 AM Mountain. Values are in inches and °F, as NRCS stores them.
Source and methods: [github.com/mt-climate-office/mco-snotel](https://github.com/mt-climate-office/mco-snotel).
Building an app on these data: see
[CONSUMERS.md](https://github.com/mt-climate-office/mco-snotel/blob/main/CONSUMERS.md).

This is bucket layout v1. Layout v0 was retired on 2026-11-03 (see below).

## Layout

| Path | Contents |
|------|----------|
| `daily/latest/` | This water year's observed SWE and percentiles for each period, with `manifest.json`. Start here. |
| `stations.parquet` | Station metadata (below). |
| `raw/snotel_wy<YYYY>.parquet` | Daily SWE, snow depth, precipitation and air temperature for every station and day of a water year, with NRCS flags. |
| `normals/<period>/` | A period's SWE normals for every station and day. |
| `daily/percentiles/<period>/` | Each water year's observed SWE and percentiles. |
| `daily/plots/<period>/<YYYY-MM-DD>/` | Per-station seasonal SWE plots (PNG). |
| `cache/v1/` | Pipeline state. Not for use. |

Each folder's `README.md` has the details.

## Periods and roles

`<period>` is the set of reference water years the normals use, named by both ends:
`wy2004-2026` is WY2004 through WY2026. A water year runs Oct 1 to Sep 30 and is named for
the year it ends in. A role names a kind of period; each water year's role resolves to one
period. File names under `daily/latest/` use the role.

| Role | Reference water years | WY2027 |
|------|-----------------------|--------|
| `snodas` | Those the SNODAS normals at `data2.climate.umt.edu/snodas/` use: the 30 before, from WY2004 at the earliest | `wy2004-2026` |
| `30yr` | The 30 before the water year | `wy1997-2026` |
| `noaa` | The years of NOAA's climate normals: 1991–2020 through WY2031, then 2001–2030 | `wy1991-2020` |
| `por` | Each station's whole record before the water year | `wypor-2026` |

`<flavor>` is how a day's distribution is estimated: `empirical` (Empirical History),
`fitted` (Fitted History) or `smoothed` (Smoothed History). See `normals/README.md`.

## Stations

`stations.parquet`: one row per SNOTEL station in NRCS's Air and Water Database, active and
retired, refreshed daily.

| Column | Contents |
|--------|----------|
| `triplet` | NRCS station triplet, e.g. `901:MT:SNTL`. Tables elsewhere in the bucket key stations by it. |
| `station` | The triplet with `_` for `:`, as in file names (`901_MT_SNTL`) |
| `site_id` | NRCS station number |
| `state`, `network`, `name`, `county` | As NRCS lists them |
| `huc` | 12-digit HUC the station is in |
| `elevation_ft` | Elevation, feet |
| `latitude`, `longitude` | Decimal degrees |
| `begin_date`, `end_date` | Station record dates. Active stations have an end date of 2100-01-01. |
| `active` | Still reporting |

## Access

```python
import pandas as pd
base = "https://data2.climate.umt.edu/snotel/"
stations = pd.read_parquet(base + "stations.parquet")
obs = pd.read_parquet(base + "daily/latest/percentiles_snodas.parquet")
obs[(obs.triplet == "901:MT:SNTL") & (obs.flavor == "smoothed")].tail()   # Stuart Mountain
```

```r
x <- arrow::read_parquet("https://data2.climate.umt.edu/snotel/daily/latest/percentiles_30yr.parquet")
```

## Layout v0 retired

Layout v0 paths stopped updating on 2026-11-03 and will be removed. Flavors are renamed:
`ecdf` is `empirical`, `zig` is `fitted`, `zig_smooth` is `smoothed`. v0 folders were named
by role and water year; v1 folders are named by period. `{d}` is `YYYY-MM-DD`; WY2027's
`snodas` role is the period `wy2004-2026`.

| Layout v0 | Layout v1 |
|-----------|-----------|
| `latest/manifest.json` | `daily/latest/manifest.json` |
| `latest/observed_{role}.parquet` | `daily/latest/percentiles_{role}.parquet` |
| `stations/stations.parquet`, `latest/stations.parquet` | `stations.parquet` |
| `archive/snotel.parquet` | `raw/snotel_wy{YYYY}.parquet`, one file per water year |
| `normals/snodas/wy2027/normals.parquet` | `normals/wy2004-2026/normals_wy2004-2026.parquet` |
| `normals/snodas/wy2027/by_station/{station}.parquet` | `normals/wy2004-2026/by_station/{station}_wy2004-2026.parquet` |
| `normals/snodas/wy2027/provenance.json` | `normals/wy2004-2026/provenance_wy2004-2026.json` |
| `normals/reference/wy2027.parquet` | `normals/wy2004-2026/reference_wy2004-2026.parquet` |
| `normals/snodas/observed/wy2027.parquet` | `daily/percentiles/wy2004-2026/percentiles_wy2004-2026_wy2027.parquet` |
| `plots/{d}/snodas/{flavor}/swe/usdm/{station}.png` | `daily/plots/wy2004-2026/{d}/{flavor}/{station}_swe_wy2004-2026_{flavor}_{d}.png` |
| `plots/{d}/index.json` | `daily/plots/wy2004-2026/{d}/index_wy2004-2026_{d}.json` |

The `smoothed` model files of v0 (`zig_smooth_coef.parquet`, `zig_smooth_diagnostics.parquet`,
`zig_smooth_basis.csv`, `zig_smooth_model.json`) are not published in layout v1. The layout
is specified in [docs/bucket-layout.md](https://github.com/mt-climate-office/mco-snotel/blob/main/docs/bucket-layout.md);
each key is in [config/layout-v1.yml](https://github.com/mt-climate-office/mco-snotel/blob/main/config/layout-v1.yml).

## Citation

USDA Natural Resources Conservation Service, National Water and Climate Center. SNOTEL
daily data, from the Air and Water Database REST API,
<https://wcc.sc.egov.usda.gov/awdbRestApi/>.
