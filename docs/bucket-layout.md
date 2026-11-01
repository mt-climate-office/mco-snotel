# Bucket layout and normals architecture: mco-snotel and mco-snodas

**Status:** draft spec, 2026-11-01. Not implemented. Both buckets migrate to it together.

**Scope:** `s3://mco-snotel` and `s3://mco-snodas`, served at `https://data2.climate.umt.edu/snotel/`
and `…/snodas/`, and the code that writes them. mco-gridmet is out of scope for now, but this spec
is written so it can adopt the same rules later (see [gridMET](#14-gridmet)).

**How to read this.** Sections 2–9 are **normative**: code and configuration must follow them. The
words *must*, *must not* and *should* carry their usual weight. Sections 10–15 are informative:
examples, history and plans. Each bucket's actual paths are **configuration**
(`config/layout.yml`, §7), not code. The trees in §10 are examples of what that configuration
produces.

## Contents

1. [Architecture](#1-architecture)
2. [Rules](#2-rules)
3. [Vocabulary](#3-vocabulary)
4. [Path templates](#4-path-templates)
5. [Periods and roles](#5-periods-and-roles)
6. [Artifacts](#6-artifacts)
7. [Layout configuration](#7-layout-configuration)
8. [Table schemas](#8-table-schemas)
9. [Lifecycle and caching](#9-lifecycle-and-caching)
10. [Resulting layouts (examples)](#10-resulting-layouts-examples)
11. [The normals package](#11-the-normals-package)
12. [Conformance and tests](#12-conformance-and-tests)
13. [Migration](#13-migration)
14. [gridMET](#14-gridmet)
15. [Open items](#15-open-items)

---

## 1. Architecture

There are three parts, each with one job:

| Part | Lives in | Does | Knows nothing about |
|---|---|---|---|
| **The `normals` package** (2.0) | `mt-climate-office/normals`, a rewrite of the existing package | Methods: empirical / fitted / smoothed normals, distribution families, percentiles and anomalies, the outlook (persistence, calibration), and the shared plot helpers | Buckets, paths, AWS, stations vs zones vs pixels |
| **Layout configuration and resolver** | Each pipeline repo: `config/layout.yml` plus a small resolver kept identical in both repos | Where every artifact goes and what it is called; which periods and roles exist | How anything is computed |
| **Pipelines** | `mco-snotel`, `mco-snodas` | Fetch source data, call the package, ask the resolver for keys, write, publish | Path strings |

Data flows one way: pipeline → package (computation) → pipeline → resolver (keys) → storage.

## 2. Rules

1. Pipeline code **must not** contain bucket paths, path fragments or file names. It refers to
   outputs by **artifact ID** (§6) and supplies **variables** (§3). Only the resolver turns those
   into keys.
2. Every published object **must** be an artifact listed in the bucket's `config/layout.yml`.
3. The `normals` package **must not** read or write storage, build paths, or depend on AWS. Its
   inputs and outputs are in-memory arrays and tables whose schemas are given in §8.
4. Periods and roles **must** come from configuration (§5), not from code.
5. Every `provenance` file and every `manifest` **must** record the `layout_version` and the
   `normals` package version that produced them.
6. Pipelines **must** pin the `normals` package to an exact released version or commit.
7. Published names **must** use the vocabulary in §3. Internal names (e.g. the vendored `zig_*`
   functions) are mapped at the edges.
8. Normals folders **must not** change once written (§9). Only `daily/latest/` and the artifacts
   marked "rewritten" in §6 may be overwritten.

## 3. Vocabulary

These are the template variables and their formats. A value must match its format exactly.

| Variable | Format | Examples |
|---|---|---|
| `year_type` | `wy` (water year, Oct 1–Sep 30, named for the year it ends in) or `cy` (calendar year) | `wy` |
| `period` | `{year_type}{first}-{last}`; `{year_type}por-{last}` for a period of record | `wy2004-2026`, `wy1991-2020`, `wypor-2026`, `cy1996-2025` |
| `role` | A configured role name (§5) | `snodas`, `30yr`, `noaa`, `por` |
| `flavor` | `empirical`, `fitted`, `smoothed` | `smoothed` |
| `subject` | A station, zone or other unit, file-safe | `901_MT_SNTL`, `01010002` |
| `type` | A subject's measurement type, where there is more than one | `swe`, `hypsomeswe` |
| `date` | `YYYY-MM-DD`, a calendar date | `2027-02-01` |
| `compact_date` | `YYYYMMDD`, only where a source names files this way | `20270201` |
| `wy` | Water year, `YYYY` | `2027` |
| `day` | Day of year, `MM-DD`, `02-29` included | `02-01` |
| `stat` | A statistic of a gridded normal or percentile | `mean`, `median`, `quantiles`, `params`, `ptile`, `standardized` |
| `var` | A source variable | `swe`, `snow_depth` |

- **Inclusive years.** Periods name both ends. WY2004–2026 runs from 2003-10-01 to 2026-09-30.
- **Hyphens, not dashes.** Keys use ASCII hyphens and lower case. The en dash is for text people
  read: "WY2004–2026" in plot legends and docs.
- **Flavors** describe how a distribution is estimated, not the family:

  | Flavor | Plot caption | Meaning |
  |---|---|---|
  | `empirical` | Empirical History | Empirical CDF of the reference values |
  | `fitted` | Fitted History | A parametric family, fitted for each day |
  | `smoothed` | Smoothed History | The same family, with its parameters smoothed through the year |

  The family is recorded separately, in provenance and in a per-row `distribution` column (§8).

## 4. Path templates

- **Templates** are strings with variables in braces: `normals/{period}/normals_{period}.parquet`.
- **Separators.** `/` separates path levels. `_` separates elements of a file name. `-` belongs
  inside values (`wy2004-2026`, `2027-02-01`).
- **File names** join the applicable elements in this order:
  `{subject}_{type}_{period}_{flavor}_{date | day | wy}_{stat}`, leaving out any that don't apply. A
  file must still say what it is once downloaded.
- **Literal prefixes** may be added where a bare value would be unclear, e.g. `wy{wy}` for a water
  year or `normals_` / `percentiles_` for a table.
- **Path levels.** A level must not have only one possible value.
- **Prefix override.** The resolver accepts a bucket name and a key prefix at run time (for test
  buckets, local runs and migrations). Templates are relative to that prefix.

## 5. Periods and roles

A **period** is a set of reference years, named by its key. A **role** is a stable name for a kind of
period ("the rolling 30 years"); each role resolves to one period for each water year. Roles are
defined per bucket in `config/layout.yml`:

```yaml
year_type: wy
roles:
  snodas: {rule: rolling, length: 30, earliest: 2004}   # max(2004, W-30) .. W-1
  30yr:   {rule: rolling, length: 30}                   # W-30 .. W-1
  noaa:   {rule: fixed, periods: [[1991, 2020], [2001, 2030], [2011, 2040]], publish_lag: 1}
  por:    {rule: por}                                    # each subject's first year .. W-1
```

| Rule | Period for water year W |
|---|---|
| `rolling` | `length` years ending W−1, starting no earlier than `earliest` (if set) |
| `fixed` | The latest listed period whose last year + `publish_lag` < W |
| `por` | `{year_type}por-{W−1}`; the first year varies by subject |

- A role whose rule yields fewer than the minimum years for every subject is absent for that W, e.g.
  `noaa` in mco-snodas before WY2042.
- **Two roles can share a period.** In WY2035, `snodas` and `30yr` both resolve to `wy2005-2034`.
  The folder is built once and both roles point to it.

## 6. Artifacts

Each artifact has an ID used in code, a template per bucket (§7), and these attributes:

| Artifact ID | What | Cadence | Mutability | Cache |
|---|---|---|---|---|
| `subjects` | Station metadata / zone boundaries | daily / rarely | rewritten | short |
| `raw` | Source data (SNOTEL water-year table; SNODAS tar and COGs) | daily | rewritten (current year only) / once | short / long |
| `normals_table` | Every subject × flavor × day for a period | once per period | frozen | long |
| `normals_by_subject` | One subject's normals | once per period | frozen | long |
| `normals_grid` | One flavor × day × stat grid (gridded) | once per period | frozen | long |
| `reference` | The record a period's normals were built from | once per period | frozen | long |
| `provenance` | A period's provenance | once per period | frozen | long |
| `means` | Observed zonal means, season table (SNODAS) | daily | rewritten during its water year | short |
| `percentiles` | Observed values and percentiles, season table | daily | rewritten during its water year | short |
| `percentile_grid` | One flavor × date × stat percentile grid (gridded) | daily | frozen | long |
| `outlook` | The outlook from an issue date | daily | frozen | long |
| `plot` | One subject × type × period × flavor × date plot | daily | frozen | long |
| `plot_index` | Completeness marker for one period × date | daily, written last | frozen | long |
| `animation` | One subject × period × flavor × water year animation (SNODAS) | daily during the season | rewritten during its water year | short |
| `latest_copy` | A stable-named copy of a current artifact, by role | daily | rewritten | short |
| `latest_manifest` | The manifest (§8) | daily | rewritten | short |
| `cache` | Internal state | any | any | none (not public) |

The CDN cache rules (§9) are generated from the Cache column; nothing else decides them.

## 7. Layout configuration

Each pipeline repo has a `config/layout.yml`: `layout_version`, `bucket`, `year_type`, `roles`
(§5), `flavors`, and `artifacts`, a map from artifact ID to template. An artifact a bucket doesn't
produce is left out.

### mco-snotel (`layout_version: 1`)

```yaml
layout_version: 1
bucket: mco-snotel
year_type: wy
roles:
  snodas: {rule: rolling, length: 30, earliest: 2004}
  30yr:   {rule: rolling, length: 30}
  noaa:   {rule: fixed, periods: [[1991, 2020], [2001, 2030]], publish_lag: 1}
  por:    {rule: por}
flavors: [empirical, fitted, smoothed]
types: [swe]
artifacts:
  subjects:           "stations.parquet"
  raw:                "raw/snotel_wy{wy}.parquet"
  normals_table:      "normals/{period}/normals_{period}.parquet"
  normals_by_subject: "normals/{period}/by_station/{subject}_{period}.parquet"
  reference:          "normals/{period}/reference_{period}.parquet"
  provenance:         "normals/{period}/provenance_{period}.json"
  percentiles:        "daily/percentiles/{period}/percentiles_{period}_wy{wy}.parquet"
  outlook:            "daily/outlook/{period}/outlook_{period}_{date}.parquet"
  plot:               "daily/plots/{period}/{date}/{flavor}/{subject}_{type}_{period}_{flavor}_{date}.png"
  plot_index:         "daily/plots/{period}/{date}/index_{period}_{date}.json"
  latest_copy:        "daily/latest/{artifact}_{role}.parquet"
  latest_manifest:    "daily/latest/manifest.json"
  cache:              "cache/"
```

### mco-snodas (`layout_version: 1`, to be confirmed in mco-snodas)

```yaml
layout_version: 1
bucket: mco-snodas
year_type: wy
roles:
  snodas: {rule: rolling, length: 30, earliest: 2004}   # also SNODAS's period of record
  30yr:   {rule: rolling, length: 30}                   # differs from snodas from WY2035
  noaa:   {rule: fixed, periods: [[2011, 2040]], publish_lag: 1}   # from WY2042
flavors: [empirical, fitted, smoothed]
types: [swe, hypsomeswe]
artifacts:
  raw_tar:            "raw/tar/SNODAS_{compact_date}.tar"
  raw_cog:            "raw/cog/{date}/snodas_{var}_{date}.tif"
  subjects:           "zonal/zones.fgb"
  normals_grid:       "gridded/normals/{period}/{flavor}/{flavor}_{period}_{day}_{stat}.tif"
  provenance_grid:    "gridded/normals/{period}/provenance_{period}.json"
  percentile_grid:    "gridded/daily/percentiles/{period}/{date}/{flavor}_{period}_{date}_{stat}.tif"
  latest_grid:        "gridded/daily/latest/{flavor}_{role}_{stat}.tif"
  latest_manifest_grid: "gridded/daily/latest/manifest.json"
  normals_table:      "zonal/normals/{period}/normals_{type}_{period}.parquet"
  normals_by_subject: "zonal/normals/{period}/by_zone/{subject}_{type}_{period}.parquet"
  reference:          "zonal/normals/{period}/reference_{type}_{period}.parquet"
  provenance:         "zonal/normals/{period}/provenance_{period}.json"
  means:              "zonal/daily/means/means_{type}_wy{wy}.parquet"
  percentiles:        "zonal/daily/percentiles/{period}/percentiles_{type}_{period}_wy{wy}.parquet"
  outlook:            "zonal/daily/outlook/{period}/outlook_{type}_{period}_{date}.parquet"
  plot:               "zonal/daily/plots/{period}/{date}/{flavor}/{subject}_{type}_{period}_{flavor}_{date}.png"
  plot_index:         "zonal/daily/plots/{period}/{date}/index_{period}_{date}.json"
  animation:          "zonal/animations/{period}/wy{wy}/{flavor}/{subject}_{type}_{period}_{flavor}_wy{wy}.mp4"
  latest_copy:        "zonal/daily/latest/{artifact}_{type}_{role}.parquet"
  latest_manifest:    "zonal/daily/latest/manifest.json"
  cache:              "cache/"
```

- **Bucket-specific IDs.** An artifact that only one bucket has (`raw_tar`, `normals_grid`) is fine.
- **Shared IDs must mean the same thing in both buckets.** mco-snotel's `normals_table` and
  mco-snodas's are the same kind of object with the same schema (§8), which is what keeps the two
  "schematically close".

## 8. Table schemas

The `normals` package produces these tables; pipelines write them as they are. Parquet uses zstd
compression. Values are in the source's units: SWE in inches for SNOTEL, mm for SNODAS, as now.
`{subject}` columns are `triplet` (SNOTEL) or `huc` plus `band` for `hypsomeswe` (SNODAS).

### `normals_table`, `normals_by_subject`

One row per subject × flavor × day.

| Column | Contents |
|---|---|
| `flavor` | `empirical`, `fitted`, `smoothed` |
| `day` | `MM-DD`, `02-29` included (it uses Feb 28's reference dates) |
| subject columns | |
| `distribution` | Family used for this row: e.g. `zero_inflated_gamma`, or `empirical` for the empirical flavor and for fallback rows |
| `n_valid` | Reference years with a value on this day |
| `ref_first_wy`, `ref_last_wy` | First and last of those years |
| `mean` | Mean of the distribution |
| family parameters | Named by family: `shape`, `scale`, `p_zero` for `zero_inflated_gamma`; empty for `empirical` |
| `fit_status` | `smoothed` only: `ok`, `no_snow`, `p_zero_only`, `no_data`, `p_zero_not_converged`, `constant` |
| `q0000` … `q1000` | Quantiles at 0, .01, .02, .025, .05, .1, .2, .25, .3, .5, .7, .75, .8, .9, .95, .975, .98, .99, 1 |
| `outlook_length`, `outlook_alpha` | `smoothed` rows, where the bucket publishes an outlook: the outlook's persistence |

### `reference`

The values the normals were built from, covering the reference years only: subject columns, `date`,
`value` (SWE).

### `percentiles`

A season table, rewritten whole every day so NRCS edits carry through: `flavor`, `date`, subject
columns, `value` (observed SWE), `ptile` (0–100, to 0.01), and `standardized` (the standard normal
quantile of the percentile, clamped to ±4). It is sorted by flavor, date and subject, with about a
month of one flavor per row group.

*Change from today:* `swe`, `swe_ptile` and `swe_standardized` become `value`, `ptile` and
`standardized`. The variable is named in provenance, which is what lets gridMET reuse the schema.

### `means` (SNODAS)

Observed zonal means: `date`, subject columns, `value`. A season table.

### `outlook`

The likely value from the day after the issue date to the end of the water year, from the
`smoothed` normals: subject columns, `date`, `q0000` … `q1000` (float32, to 0.1; `q0000` and `q1000`
are read at z = ±4), and `p_zero` (the chance of exactly zero, shown as "chance of no snow" for SWE).
Sorted by subject and date, about 50 subjects per row group.

*Change from PR #6:* `p_snow_free` becomes `p_zero`, for the same reason as above.

### `provenance`

```json
{
  "layout_version": 1, "normals_version": "2.0.0",
  "period": "wy2004-2026", "year_type": "water", "first_year": 2004, "last_year": 2026,
  "roles": ["snodas"], "variable": "swe", "units": "in",
  "built_at": "2026-10-01T20:00:00Z",
  "n_subjects": 890, "n_subjects_with_normals": 829, "min_valid_years": 10,
  "flavors": {
    "empirical": {"distribution": "empirical", "method": "type-7 ECDF of positive values, zero-inflated"},
    "fitted":    {"distribution": "zero_inflated_gamma", "method": "L-moments (PELGAM) per day; empirical fallback with < 4 positive values"},
    "smoothed":  {"distribution": "zero_inflated_gamma", "method": "cyclic cubic P-splines (k = 24) on logit(p_zero), log(l1), log(L-CV); lambda 100, 1000, 1000"}
  },
  "outlook": {"alpha_table": "config/outlook_alpha.csv", "alpha_md5": "…", "spread_beta": 0.25},
  "source": "NRCS AWDB REST API, daily WTEQ",
  "pipeline": "mco-snotel@<commit>"
}
```

`roles` lists the roles this folder served when it was built; later years' roles may point
elsewhere.

### `latest_manifest`

```json
{
  "layout_version": 1, "normals_version": "2.0.0",
  "date": "2027-02-01", "water_year": 2027, "updated": "2027-02-01T17:20:00Z",
  "roles": {
    "snodas": {"period": "wy2004-2026", "first_year": 2004, "last_year": 2026},
    "30yr":   {"period": "wy1997-2026", "first_year": 1997, "last_year": 2026},
    "noaa":   {"period": "wy1991-2020", "first_year": 1991, "last_year": 2020},
    "por":    {"period": "wypor-2026",  "first_year": null, "last_year": 2026}
  },
  "artifacts": {
    "percentiles": {"snodas": {"latest": "daily/latest/percentiles_snodas.parquet",
                               "dated":  "daily/percentiles/wy2004-2026/percentiles_wy2004-2026_wy2027.parquet"}},
    "outlook":     {"snodas": {"latest": "daily/latest/outlook_snodas.parquet",
                               "dated":  "daily/outlook/wy2004-2026/outlook_wy2004-2026_2027-02-01.parquet"}},
    "normals_table": {"snodas": {"dated": "normals/wy2004-2026/normals_wy2004-2026.parquet"}},
    "plot_index":    {"snodas": {"dated": "daily/plots/wy2004-2026/2027-02-01/index_wy2004-2026_2027-02-01.json"}}
  },
  "subjects": "stations.parquet"
}
```

A role or artifact is absent when there is nothing for the date (e.g. no outlook on Sep 30).

### `plot_index`

Written last in its folder. If it exists, that period's plots for that date are complete. It lists
the flavors, types, subjects, the plot template, reference years, and any subjects that failed.

## 9. Lifecycle and caching

**Yearly build (Oct 1, after the daily run has ingested Sep 30).** For the new water year W, every
role is resolved (§5):
- A period whose folder doesn't exist yet is built: normals, reference, provenance, and the outlook
  persistence.
- A period whose folder exists is not rebuilt. Its record was frozen when it was first built, so for
  a fixed period like `wy1991-2020` later NRCS edits to those years never reach it. That is
  intended.

**Daily run.** For each role's current period:
1. Refresh `raw`.
2. Rewrite the `percentiles` season table (and `means` for SNODAS).
3. Write the `outlook` (and `percentile_grid` for SNODAS).
4. Plot every flavor and type, then write the `plot_index`.
5. Write the `latest_copy` files and the `latest_manifest`.

Every role is plotted daily.

**Retention.** Nothing published is deleted:
- Frozen normals are what past percentiles, outlooks and plots refer to.
- Dated outlooks are the record of what was forecast, for later verification.
- Plots are the record of what was shown.

**Caching** (mco-data-cdn), generated from §6:

| Cache | TTL | Artifacts |
|---|---|---|
| short | 1 hour | `subjects`, current-year `raw`, `means`, `percentiles`, `animation`, `latest_copy`, `latest_manifest` |
| long | 1 day (default) | everything frozen |

The buckets should expire noncurrent object versions (e.g. after 30 days), since rewritten
artifacts otherwise accumulate old versions daily.

## 10. Resulting layouts (examples)

These trees are what the §7 configurations produce for WY2027. They are not normative.

### mco-snotel

```
stations.parquet
raw/snotel_wy2027.parquet
normals/
  wy2004-2026/
    normals_wy2004-2026.parquet
    reference_wy2004-2026.parquet
    provenance_wy2004-2026.json
    by_station/901_MT_SNTL_wy2004-2026.parquet
  wy1997-2026/  wy1991-2020/  wypor-2026/
daily/
  percentiles/wy2004-2026/percentiles_wy2004-2026_wy2027.parquet
  outlook/wy2004-2026/outlook_wy2004-2026_2027-02-01.parquet
  plots/wy2004-2026/2027-02-01/
    index_wy2004-2026_2027-02-01.json
    smoothed/901_MT_SNTL_swe_wy2004-2026_smoothed_2027-02-01.png
  latest/
    manifest.json
    percentiles_snodas.parquet  percentiles_30yr.parquet  percentiles_noaa.parquet  percentiles_por.parquet
    outlook_snodas.parquet  …
cache/
```

### mco-snodas

```
raw/tar/SNODAS_20270201.tar
raw/cog/2027-02-01/snodas_swe_2027-02-01.tif
gridded/
  normals/wy2004-2026/smoothed/smoothed_wy2004-2026_02-01_quantiles.tif
  daily/percentiles/wy2004-2026/2027-02-01/smoothed_wy2004-2026_2027-02-01_ptile.tif
  daily/latest/manifest.json
zonal/
  zones.fgb
  normals/wy2004-2026/
    normals_swe_wy2004-2026.parquet  normals_hypsomeswe_wy2004-2026.parquet
    reference_swe_wy2004-2026.parquet  provenance_wy2004-2026.json
    by_zone/01010002_swe_wy2004-2026.parquet
  daily/
    means/means_swe_wy2027.parquet
    percentiles/wy2004-2026/percentiles_swe_wy2004-2026_wy2027.parquet
    plots/wy2004-2026/2027-02-01/smoothed/01010002_swe_wy2004-2026_smoothed_2027-02-01.png
    latest/manifest.json
  animations/wy2004-2026/wy2027/smoothed/01010002_hypsomeswe_wy2004-2026_smoothed_wy2027.mp4
cache/
```

mco-snotel's `normals/` and `daily/` line up with mco-snodas's `zonal/normals/` and `zonal/daily/`.

## 11. The normals package

`mt-climate-office/normals` becomes the home of the methods: a ground-up rewrite and generalization
released as **2.0.0**. The 1.x line (gamma normals from gridMET, cited by DOI) stays available at its
tags.

**Scope**
- **Normals:** `empirical`, `fitted`, `smoothed`, for any subject set. Input is a reference matrix
  (subjects × years) per day; output is §8's normals table. The same code serves stations, zones
  and pixels; the gridded case works in blocks.
- **Distribution families as plug-ins.** A family provides:
  - a fit (per day);
  - a smoothing transform (which parameters are smoothed, on what scale);
  - a CDF and a quantile function;
  - whether it has a zero mass.

  The first family is `zero_inflated_gamma` (today's ZIG). Others, such as a normal for
  temperature, can be added without touching pipelines.
- **Percentiles and anomalies:** CDF value, standardized anomaly, and the zero-mass conventions
  (a zero maps to p0/2).
- **Outlook:**
  - percentile-space persistence;
  - persistence-length fitting;
  - the out-of-range anchor;
  - the spread factor;
  - the hindcast and calibration functions.

  The calibration *tables* (α, β) are per dataset and stay in each pipeline's `config/`. Zero-mass
  handling (`p_zero`, the half-a-year floor) applies only to families with a zero mass.
- **Plot helpers:** the shared frame, palette, USDM classes, legends and logos now vendored from
  mco-snodas (`plot.R`, `plot_palette.png`, logos). Captions come from the flavor names. Per-dataset
  plot functions (a station's seasonal plot, a watershed's hypsomeSWE plot) can stay in each
  pipeline, built on these helpers.

**Not in scope:** storage, paths, AWS, fetching source data, scheduling.

**Releases and pinning** follow the office's shared-module rules:
- Releases are semantic versions.
- Pipelines pin an exact version or commit (no unpinned dependencies).
- A change ships as its own release, with the pipeline PRs ready.
- Both pipelines move together when a change affects published output.

**Parity.** A fixture set (a few stations and zones, with known outputs) is tested in the package
and in each pipeline's CI, so a pipeline can't drift from the package it pins.

**Existing 1.x users** stay on 1.x until they choose to move. Nothing that writes `mco-gridmet` uses
the package; mt-gridmet and mco-drought-conus compute their own.

| Repo | Uses | Pinned |
|---|---|---|
| `gridmet-normals` | `gamma_from_rast()`, `write_as_cog()` (output local and to Actions artifacts, not S3) | `normals@562af10` (gridmet-normals#7, 2026-11-01) |
| `mt-normals` | `examples/` call `aggregate_daily()`, `gamma_from_rast()`, `fetch_gridmet()`, `write_as_cog()` | README install line → `normals@562af10` (mt-normals#1, 2026-11-01) |
| `normal-explorer` | None found | — |

`562af10` is the head of `normals`'s default branch on 2026-11-01, after `v1.0.1`. 2.0 is developed on a
branch and reaches the default branch only once every 1.x user is pinned.

## 12. Conformance and tests

- **Resolver tests:** every example path in this spec must resolve exactly from the §7
  configuration. The examples are the test cases.
- **Configuration check:** each `layout.yml` is validated against §3–§7:
  - every template uses only known variables;
  - file names follow the element order;
  - shared artifact IDs keep their meaning in both buckets;
  - roles use known rules.
- **No hard-coded paths:** a CI check fails if pipeline code contains a bucket path or one of the
  configured file-name prefixes outside the resolver and `config/`.
- **Schema checks:** written tables are checked against §8 before upload.
- **Parity tests:** see §11.
- **Generated outputs:** the CDN cache rules (§9) are generated from §6, and bucket READMEs
  generated in part from `layout.yml`, so neither can disagree with the configuration.

## 13. Migration

The order is chosen so that each step can be checked on its own:

1. **Package.** Write `normals` 2.0 (methods, percentiles, outlook, plot helpers) and switch both
   pipelines to it with **no change to published output**. Parity tests against today's outputs
   prove it. PR #6's outlook work is reworked into the package here.
2. **Resolver.** Add `config/layout.yml` and the resolver to both pipelines, describing **today's**
   layout as `layout_version: 0`. Remove hard-coded paths. Published output still doesn't change.
3. **Layout.** Switch both buckets to `layout_version: 1`:
   - build the new normals folders (including `wy1991-2020` for SNOTEL);
   - recompute WY2025–2027 percentiles and outlooks;
   - redraw plots from 2024-10-01 for every role;
   - optionally write both layouts for a transition so consumers (the snowpack explorer first) can
     move;
   - update CONSUMERS.md and the bucket READMEs;
   - point the CDN rules at the new paths;
   - delete the old paths once nothing reads them.

### What moves (mco-snotel)

| Now | `layout_version: 1` |
|---|---|
| `archive/snotel.parquet` | `raw/snotel_wy{YYYY}.parquet` |
| `stations/stations.parquet` | `stations.parquet` |
| `normals/{30yr,snodas,por}/wy{W}/normals.parquet` | `normals/{period}/normals_{period}.parquet` |
| `normals/…/wy{W}/by_station/{station}.parquet` | `normals/{period}/by_station/{station}_{period}.parquet` |
| `normals/…/wy{W}/provenance.json` | `normals/{period}/provenance_{period}.json` |
| `normals/…/wy{W}/zig_smooth_{coef,diagnostics}.parquet`, `zig_smooth_basis.csv`, `zig_smooth_model.json` | dropped (`fit_status` column; λ in provenance) |
| `normals/reference/wy{W}.parquet` | `normals/{period}/reference_{period}.parquet` (that period's years only) |
| `normals/{…}/observed/wy{W}.parquet` | `daily/percentiles/{period}/percentiles_{period}_wy{W}.parquet` |
| `plots/{date}/{period}/{flavor}/swe/usdm/{station}.png` | `daily/plots/{period}/{date}/{flavor}/{station}_swe_{period}_{flavor}_{date}.png` |
| `plots/{date}/index.json` | `daily/plots/{period}/{date}/index_{period}_{date}.json` |
| `latest/*` | `daily/latest/*` (role names) |

### What moves (mco-snodas; to be confirmed there)

| Now | `layout_version: 1` |
|---|---|
| `raw/SNODAS_{YYYYMMDD}.tar` | `raw/tar/SNODAS_{YYYYMMDD}.tar` |
| `cogs/{date}/snodas_{var}_{YYYYMMDD}.tif` | `raw/cog/{date}/snodas_{var}_{date}.tif` |
| `normals/gridded/{flavor}/{date}/{date}_{flavor}_{mean,median,quantiles,params}.tif` | `gridded/normals/{period}/{flavor}/{flavor}_{period}_{day}_{stat}.tif` |
| `normals/gridded/{flavor}/{date}/{date}_{flavor}_swe_{ptile,standardized}.tif` | `gridded/daily/percentiles/{period}/{date}/{flavor}_{period}_{date}_{ptile,standardized}.tif` |
| `normals/gridded/{flavor}/{date}/{date}_{flavor}_provenance.json` | `gridded/normals/{period}/provenance_{period}.json` (one) |
| `normals/zonal/wbd/{flavor}/{date}/{date}_{flavor}_{type}_normals.parquet` | `zonal/normals/{period}/normals_{type}_{period}.parquet` |
| `normals/zonal/wbd/by_zone/wy{W}/{huc}_{type}.parquet` | `zonal/normals/{period}/by_zone/{huc}_{type}_{period}.parquet` |
| `normals/zonal/wbd/raw/{date}/{date}_raw_{type}_means.parquet` | `zonal/daily/means/means_{type}_wy{W}.parquet` |
| `normals/zonal/wbd/observed/wy{W}_swe.parquet` | `zonal/daily/percentiles/{period}/percentiles_swe_{period}_wy{W}.parquet` |
| `plots/{date}/{flavor}/{type}/usdm/{huc}.png` | `zonal/daily/plots/{period}/{date}/{flavor}/{huc}_{type}_{period}_{flavor}_{date}.png` |
| `animations/sy{YYYY}/{flavor}/hypsomeswe/usdm/{huc}.mp4` | `zonal/animations/{period}/wy{YYYY}/{flavor}/{huc}_hypsomeswe_{period}_{flavor}_wy{YYYY}.mp4` |
| `latest/cogs/*`, `latest/zonal/*`, `latest/manifest.json` | `gridded/daily/latest/`, `zonal/daily/latest/` |
| `normals/build/current/*` | `cache/build/` |
| HUC boundaries in `cache/data/` | also published as `zonal/zones.fgb` |

## 14. gridMET

Not migrated now. When mco-gridmet adopts this spec:
- Its `{product}/normals/1996-2025/` becomes a `cy1996-2025` period under a `layout.yml`.
- Its rolling normals are kept rather than deleted when the period rolls, if percentiles are
  published against them.
- Its variables use `normals` 2.0's families (for example, zero-inflated gamma for precipitation,
  normal for temperature) under the same three flavors.

## 15. Open items

1. **Gridded SNODAS parameters.** Each day's `smoothed` parameter grid is about 115 MB, roughly
   40 GB per period. One stack of spline coefficients per period would replace all 366, but
   consumers would need the package to evaluate them. For mco-snodas to decide.
2. **Gridded reference.** The zonal `reference` holds the zonal means. For the grid, the reference
   is the SNODAS grids of the reference years (`raw/cog/`). Decide whether provenance should list
   those dates or an index artifact should.
3. **mco-snodas leftovers:**
   - the root `manifest.parquet`: what reads it, and does it duplicate `latest/`?
   - the partial gridded `zig` run (from 2026-04-21 only);
   - `animations/sy2026`, still using the old snow-year naming.
4. **`noaa` outlook calibration.** Use the `30yr` α and β until enough out-of-sample years exist.
5. **The resolver's home.** Kept identical in both pipelines for now. It could join the package
   later as a separate, storage-free module if gridMET adopts the spec.
6. **Consumers.** The snowpack explorer and anything else reading current paths must move before the
   old paths are deleted (§13 step 3).
7. **PR #6** (the outlook on today's layout) is not merged. Its method moves into `normals` 2.0
   (step 1) and its paths into `layout.yml` (step 2).
