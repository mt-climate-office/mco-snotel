# Using MCO SNOTEL data in an application

For apps that read these data directly in a browser or service. Each bucket directory's
`README.md` documents its files; this page covers how to use them together.

## Host

Base URL: **`https://data2.climate.umt.edu/snotel/`** (CloudFront in front of the
`mco-snotel` S3 bucket). If its certificate ever lapses, the same paths are served from
`https://d1s8jav5n0eyyf.cloudfront.net/snotel/`.

- CORS: any origin may `GET`; `Content-Range`, `ETag`, `Accept-Ranges` and
  `Content-Length` are exposed, so Parquet range requests work from the browser.
- Responses are cached by CloudFront. `latest/` is cached for up to an hour, other paths
  for up to a day, so read tonight's values from `latest/`.
- Do not read from the raw S3 endpoint; its CORS allows only the CDN.

## Finding the current date

1. `GET latest/manifest.json`. `date` is the newest date with SWE; `water_year` is its
   water year; `updated` is when it was published (UTC); `normals` maps each period to its
   normals folder; `plots`, if present, is that date's plot folder.
2. Read this water year's observed SWE and percentiles from `latest/observed_{period}.parquet`.
   They are rewritten whole each night, since NRCS edits recent values.

The manifest updates after the nightly run (about 10–11 AM Mountain). On Oct 1 the new
water year has no normals until the yearly build finishes that afternoon.

## Paths

`{period}` = `30yr` | `snodas` | `por`, `{flavor}` = `ecdf` | `zig` | `zig_smooth`,
`{YYYY}` = water year, `{station}` = the station triplet with `_` for `:` (e.g.
`901_MT_SNTL`), `{d}` = `YYYY-MM-DD`.

| Data | Path |
|------|------|
| Stations (name, location, elevation, HUC, active) | `stations/stations.parquet` |
| Daily data, every station and element, with flags | `archive/snotel.parquet` |
| Normals, every station, flavor and date of a water year | `normals/{period}/wy{YYYY}/normals.parquet` |
| One station's normals for a water year | `normals/{period}/wy{YYYY}/by_station/{station}.parquet` |
| Observed SWE and percentiles, every station, water year to date | `normals/{period}/observed/wy{YYYY}.parquet` |
| Which reference years were used | `normals/{period}/wy{YYYY}/provenance.json` |
| The record the normals were built from | `normals/reference/wy{YYYY}.parquet` |
| Plots | `plots/{d}/{period}/{flavor}/swe/usdm/{station}.png` |

Tables key stations by `triplet` (`901:MT:SNTL`); file names use `{station}`. Values are
in inches. Normals exist for every day of a water year from Oct 1; observed rows exist only
for dates with SWE.

## Which period and flavor

`snodas` uses the same reference years as the SNODAS normals at
`data2.climate.umt.edu/snodas/`, so it is the one to show beside SNODAS. `30yr` is the
standard 30-year climatology. `por` uses every year the station has. Label the period
wherever values are shown.

`zig_smooth` (Smoothed History) is the default for display: it is stable from day to day
and follows the timing of peak SWE and melt-out. `ecdf` (Empirical) is the most
transparent; `zig` (Fitted) sits between. Label the flavor wherever values are shown.

Normals are rebuilt once a year, on Oct 1, and do not change during a water year (Oct 1–Sep
30, named for the year it ends in, e.g. `wy2027`). A station needs 10 years of record on a
date for a normal; newer stations have empty normals columns.

## One station's season

Read its `by_station/` file (all flavors and dates, about 120 KB) and join the observed
table on `flavor`, `date` and `triplet`. Read only the columns you need with a columnar
reader such as hyparquet or DuckDB-Wasm. The observed table is sorted by flavor, date and
triplet, and each row group holds about a month of one flavor, so a reader that skips row
groups by their `date` statistics (hyparquet's `rowStart`/`rowEnd`, DuckDB) can fetch one
date for every station without the whole year.

## Plots

Before linking to a date's plots, check that `plots/{d}/index.json` exists and lists the
period in `periods`: it is written after the plots, so it marks the date as complete. The
nightly run plots `snodas`; other periods are plotted on request. A station's flavors
share their SWE axis and every plot has the same frame, so swapping the image in place
changes only the data. Plots are 1500 × 1000 px; display them at about
600–1200 CSS px wide. Stations with too short a record show their SWE without normals.

## Colours

Percentile classes follow the US Drought Monitor: D4 ≤ 2, D3 2–5, D2 5–10, D1 10–20,
D0 20–30, normal 30–70, W0 70–80, W1 80–90, W2 90–95, W3 95–98, W4 > 98. The plots use
`#730000 #E60000 #FFAA00 #FCD37F #FFFF00`, white, `#C6F0FF #73B2FF #0070FF #0000C8 #00007D`,
as in mco-snodas.

## Stability

Paths, file names and column names above are stable; changes will be announced in this
repository's commit history first. `cache/` is internal and may change without notice.
