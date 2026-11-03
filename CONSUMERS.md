# Using MCO SNOTEL data in an application

For apps that read these data directly in a browser or service. Each bucket directory's
`README.md` documents its files; this page covers how to use them together.

This page describes bucket layout v1. Layout v0 paths stopped updating on 2026-11-03 and
will be removed; the bucket's root `README.md` maps the old paths to the new ones.
snow.climate.umt.edu already reads layout v1.

## Host

Base URL: **`https://data2.climate.umt.edu/snotel/`** (CloudFront in front of the
`mco-snotel` S3 bucket). If its certificate ever lapses, the same paths are served from
`https://d1s8jav5n0eyyf.cloudfront.net/snotel/`.

- CORS: any origin may `GET`; `Content-Range`, `ETag`, `Accept-Ranges` and
  `Content-Length` are exposed, so Parquet range requests work from the browser.
- Responses are cached by CloudFront, so a file can lag its update. Read today's values
  from `daily/latest/`.
- Do not read from the raw S3 endpoint; its CORS allows only the CDN.

## Finding the current date

1. `GET daily/latest/manifest.json`. `date` is the newest date with SWE; `water_year` is its
   water year; `updated` is when it was published (UTC); `archive` is the water year's daily
   data file; `normals` maps each role to its normals folder; `plots`, if present, maps each
   plotted role to that date's plot folder.
2. Read this water year's observed SWE and percentiles from
   `daily/latest/percentiles_{role}.parquet`. They are rewritten whole each day, since NRCS
   edits recent values.

The manifest updates after the daily run, which starts at 10 AM Mountain. On Oct 1 the new
water year has no normals until the yearly build finishes.

## Paths

`{role}` = `snodas` | `30yr` | `noaa` | `por`, `{period}` = the role's period for the water
year (below), `{flavor}` = `empirical` | `fitted` | `smoothed`, `{YYYY}` = water year,
`{station}` = the station triplet with `_` for `:` (e.g. `901_MT_SNTL`), `{d}` =
`YYYY-MM-DD`.

| Role | Period for water year W | WY2027 |
|------|-------------------------|--------|
| `snodas` | `wy{max(2004, W−30)}-{W−1}` | `wy2004-2026` |
| `30yr` | `wy{W−30}-{W−1}` | `wy1997-2026` |
| `noaa` | `wy1991-2020` through WY2031, then `wy2001-2030` | `wy1991-2020` |
| `por` | `wypor-{W−1}` | `wypor-2026` |

Read the periods from the manifest's `normals` rather than computing them where you can.

| Data | Path |
|------|------|
| Stations (name, location, elevation, HUC, active) | `stations.parquet` |
| Daily data, every station and element of a water year, with flags | `raw/snotel_wy{YYYY}.parquet` |
| Normals, every station, flavor and day | `normals/{period}/normals_{period}.parquet` |
| One station's normals | `normals/{period}/by_station/{station}_{period}.parquet` |
| Observed SWE and percentiles, every station, water year to date | `daily/percentiles/{period}/percentiles_{period}_wy{YYYY}.parquet` |
| The same for the current water year | `daily/latest/percentiles_{role}.parquet` |
| Which reference years were used | `normals/{period}/provenance_{period}.json` |
| The record the normals were built from | `normals/{period}/reference_{period}.parquet` |
| Plots | `daily/plots/{period}/{d}/{flavor}/{station}_swe_{period}_{flavor}_{d}.png` |
| A plot date's completion marker | `daily/plots/{period}/{d}/index_{period}_{d}.json` |

Tables key stations by `triplet` (`901:MT:SNTL`); file names use `{station}`. Values are
in inches. Normals exist for every day of the year; observed rows exist only for dates with
SWE.

## Columns

Column names and types are those of layout v0. Only the `flavor` values changed, from
`ecdf`, `zig` and `zig_smooth` to `empirical`, `fitted` and `smoothed`.

- **Normals** (`normals_`, `by_station/`): `flavor`, `date`, `triplet`, `n_valid`,
  `ref_first_wy`, `ref_last_wy`, `mean`, `zig_shape`, `zig_scale`, `zig_p_zero`, `q0000` …
  `q1000`. `date` is in the water year the period was built for (WY2027 for the folders
  built in 2026); match on month and day.
- **Percentiles** (`percentiles_`): `flavor`, `date`, `triplet`, `swe`, `swe_ptile`,
  `swe_standardized`.
- **Daily data** (`raw/`): `triplet`, `site_id`, `date`, and `wteq`, `snwd`, `prec`,
  `prcp`, `tmax`, `tmin`, `tavg`, each with `_qc` and `_qa` flags.
- **Reference** (`reference_`): `triplet`, `date`, `wteq`.

## Which period and flavor

`snodas` uses the same reference years as the SNODAS normals at
`data2.climate.umt.edu/snodas/`, so it is the one to show beside SNODAS. `30yr` is the
standard 30-year climatology. `noaa` uses the years of NOAA's climate normals. `por` uses
every year the station has. Label the period wherever values are shown.

`smoothed` (Smoothed History) is the default for display: it is stable from day to day and
follows the timing of peak SWE and melt-out. `empirical` (Empirical History) is the most
transparent; `fitted` (Fitted History) sits between. Label the flavor wherever values are
shown.

A period's normals are built once and do not change. A water year runs Oct 1 to Sep 30 and
is named for the year it ends in, e.g. `wy2027`. A station needs 10 years of record on a
day for a normal; newer stations have empty normals columns.

## One station's season

Read its `by_station/` file (all flavors and days, about 120 KB) and join the percentiles
table on `flavor`, `date` and `triplet`. Read only the columns you need with a columnar
reader such as hyparquet or DuckDB-Wasm. The percentiles table is sorted by flavor, date and
triplet, so a reader that skips row groups by their `date` statistics (hyparquet's
`rowStart`/`rowEnd`, DuckDB) can fetch one date for every station without the whole year.

## Plots

Before linking to a date's plots, check that its `index_{period}_{d}.json` exists: it is
written after the plots, so it marks the date as complete. The daily run plots `snodas`;
other roles are plotted on request. Indexes for dates before 2026-11-01 were copied from
layout v0 and carry v0 flavor names and a v0 `path` template; build plot paths from the
table above. A station's flavors share their SWE axis and every plot has the same frame, so
swapping the image in place changes only the data. Plots are 1500 × 1000 px; display them
at about 600–1200 CSS px wide. Stations with too short a record show their SWE without
normals.

## Colours

Percentile classes follow the US Drought Monitor: D4 ≤ 2, D3 2–5, D2 5–10, D1 10–20,
D0 20–30, normal 30–70, W0 70–80, W1 80–90, W2 90–95, W3 95–98, W4 > 98. The plots use
`#730000 #E60000 #FFAA00 #FCD37F #FFFF00`, white, `#C6F0FF #73B2FF #0070FF #0000C8 #00007D`,
as in mco-snodas.

## Stability

Paths, file names and column names above are stable; changes will be announced in this
repository's commit history first. Keys come from
[config/layout-v1.yml](config/layout-v1.yml). Column names will change with normals 2.1,
announced here first. `cache/` is internal and may change without notice.
