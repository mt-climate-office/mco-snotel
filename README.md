# MCO SNOTEL

Daily snow water equivalent (SWE), snow depth, precipitation and air temperature from
every NRCS [SNOTEL](https://www.nrcs.usda.gov/resources/data-and-reports/snow-and-water-interactive-map)
station, active and retired, with SWE normals, percentiles and per-station plots, built
by the Montana Climate Office. The normals and plots use the methods and design of
[mco-snodas](https://github.com/mt-climate-office/mco-snodas), applied to each station's
own record. It runs daily at 10:00 AM Mountain on AWS.

- **Data:** <https://data2.climate.umt.edu/snotel/>. Each directory has a `README.md`
  (sources in [`s3-docs/`](s3-docs/)).
- **Using the data in an app:** [CONSUMERS.md](CONSUMERS.md).

## Pipeline

```
Daily (mco-snotel.R, ECS Fargate, 10:00 AM Mountain)
  1  station metadata from AWDB                                     stations/
  2  refetch the water year to date from AWDB and replace those
     rows of the archive (NRCS edits recent values)                 archive/snotel.parquet
  3  SWE percentiles against the frozen normals, every period       normals/{period}/observed/
  4  outlook from the newest date to Sep 30, every period           normals/{period}/outlook/
  5  per-station seasonal SWE plots (snodas period)                 plots/{date}/
  6  copy the current tables to latest/, write manifest             latest/

Yearly, Oct 1 at 2 PM (normals-annual.R, the same task)
  refetch every station's whole record from AWDB
  freeze the record before the new water year                       normals/reference/wy{YYYY}.parquet
  build ECDF, ZIG and ZIG-smooth normals for every station, day
  and period of the new water year, with the outlook's persistence  normals/{period}/wy{YYYY}/
```

Data come from the NRCS [AWDB REST API](https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html)
in its stored units (inches, °F) with each value's QC and QA flags. AWDB leaves out values
NRCS has marked suspect, so the archive never holds them, and a value NRCS flags later
drops out at the next refetch that covers its date.

## Normals

The method is mco-snodas's, unchanged; its code is vendored (see below). A station's daily
SWE series takes the place of a watershed's.

**Water year.** Years run Oct 1–Sep 30 and are named for the year they end in (2027 is
2026-10-01 to 2027-09-30). Plot legends label it "WY"; code and file paths use
`water_year()` and `wy2027/`.

**Reference periods.** Each water year's normals are built for three periods:

| Period | Reference water years | WY2027 |
|--------|-----------------------|--------|
| `30yr` | The 30 before the water year | 1997–2026 |
| `snodas` | Those the SNODAS normals use: from WY2004 (SNODAS's first complete year) or 30 back, whichever is later | 2004–2026 |
| `por` | The station's whole record before the water year | varies |

`snodas` matches mco-snodas year for year, so a station can be compared with the SNODAS
pixel or watershed around it. It is shorter than 30 years until WY2034.

A day's reference values are the same calendar day in each reference year (Feb 29 uses
Feb 28). Years without a value are skipped. A day needs at least 10 valid years (or every
year, in a period shorter than 10), so a station with a short record has no normals until
it has 10 years. Normals are built once a year, on Oct 1, and frozen for that water year,
together with the record they were built from (`normals/reference/wy{YYYY}.parquet`). Each
day's percentiles are computed against that frozen record, so NRCS edits to past years do
not move the normals mid-year.

**Model.** Every flavor uses the same zero-inflated form, since SWE is often exactly zero:

```
P(X = 0) = p0
P(X ≤ x) = p0 + (1 − p0) · F(x),   x > 0
```

| Flavor | Plot caption | `F(x)` |
|--------|--------------|--------|
| `ecdf` | Empirical History | Type-7 empirical CDF of the positive reference values (R's default `quantile()`). |
| `zig` | Fitted History | Gamma fit by L-moments (Hosking 1990). Days with fewer than 4 positive values fall back to the ECDF. |
| `zig_smooth` | Smoothed History | The `zig` fit smoothed over the year: each day's zero fraction and L-moments of positive SWE (l1 and L-CV) are fit with cyclic P-splines in day of water year (24 basis functions; fixed λ = 100, 10³, 10³). Gamma shape and scale follow from the smoothed L-moments as in `zig`. |

The fit behind `zig_smooth` has no minimum record of its own. A station-day with fewer
than 10 valid years gets no `zig_smooth` normal, as for `ecdf` and `zig`. mco-snodas never
meets this case, since every SNODAS pixel has a full record.

**Percentiles.** An observation's percentile is its CDF value × 100, stored to 0.01. A zero maps to p0 / 2,
the middle of the zero mass, so a station that is always bare on that date reads 50. The
standardized anomaly is the normal quantile of the percentile, clamped to ±4. Negative SWE
readings are treated as missing.

**Quantiles** are columns `q0000`, `q0010`, …, `q1000` (19 probabilities,
`SNODAS_QUANTILES` in `R/utils.R`). `q0000` is 0; `q1000` is NA wherever SWE can be
positive.

## Outlook

Each day, `stage_outlook()` writes the likely SWE for the rest of the water year at every
station, for every period, from the smoothed normals (`zig_smooth`; `R/outlook.R`). Every
flavor's plot shows that one outlook. It is statistical and reads the normals directly:
today's SWE is placed in the smoothed distribution for today (z = Φ⁻¹(percentile), clamped
to ±4), z is carried forward and fades toward normal, and each target date's quantiles are
read from that date's normals at the matching probabilities:

```
rho(h) = exp(-(h / l)^alpha)
k      = exp(-beta rho min(z, 0))               at most 3
q_p    = Q_target(Phi(rho z + Phi^-1(p) k sqrt(1 - rho^2)))
```

It uses the vendored `zig_p`/`zig_q`, ECDF fallback included, so the outlook keeps the
normals' shape and melts out with them. The empirical and fitted flavors were tried and
dropped: the empirical one cannot reach past the reference years, so a record-setting
station's range collapsed to a line. For a station with snow on the ground, a fitted chance
of no snow below half a reference year is taken as zero; otherwise a record-low station
would be read as bare. A station that is bare today keeps the fitted chance, so its outlook
starts at zero. When today's SWE is past z = ±4, the quantiles are scaled by `(swe / Q_today(Phi(z)))^rho`,
so the range starts at today's SWE and relaxes to the normals.

- **`l` (persistence length)** is calculated in the annual build for every station, period
  and issue date, from the reference years: each year's z, and how z correlates
  across years from a date to 3–120 days later (issue dates within ±15 days pooled), fitted
  by `rho(h)`. It is stored on the normals' `zig_smooth` rows as `outlook_length`.
- **`alpha` (persistence shape)** is calibrated, not calculated: one value per period and
  day of the year in `config/outlook_alpha.csv`, a smooth yearly curve (two Fourier
  harmonics) fitted so the outlook's 80% and 50% ranges hold the outcome 80% and 50% of the
  time. It is lowest in early winter (about 0.5–0.8: the range opens fast) and highest in
  April (about 1.8: it starts narrow and fans out). It is stored with `outlook_length` as
  `outlook_alpha`.
- **`beta` (spread)** widens the range for stations starting below normal: a station with
  little snow moves through more percentiles per storm or warm spell. Stations above normal
  keep the base spread. It fades with `rho`, so long leads keep the normals' spread. One value per period
  in `config/outlook_spread.csv`, calibrated so coverage is even across starting classes
  (bare, D4 … W4). Without it, a station starting in D4 landed inside its 80% range only
  about half the time a week later.

`scripts/outlook-hindcast.R` and `scripts/outlook-calibrate.R` regenerate both tables: an
out-of-sample hindcast of 120 sampled stations (about 117 with enough record) over the last
11 water years, with the normals and lengths for each test year built only from the record
before it, scored by coverage and CRPS against the normals alone. The calibration report
checks the curve leaving each year out. Rerun them after a change to the method, and every
few years:

```bash
# archive.parquet and stations.parquet: local copies of archive/snotel.parquet and stations/stations.parquet
for p in 30yr snodas por; do Rscript scripts/outlook-hindcast.R archive.parquet stations.parquet cal1/ $p 120 8 beta; done
Rscript scripts/outlook-calibrate.R cal1/ beta      # writes config/outlook_spread.csv
for p in 30yr snodas por; do Rscript scripts/outlook-hindcast.R archive.parquet stations.parquet cal2/ $p 120 8 alpha; done
Rscript scripts/outlook-calibrate.R cal2/ alpha     # writes config/outlook_alpha.csv
for p in 30yr snodas por; do Rscript scripts/outlook-hindcast.R archive.parquet stations.parquet cal3/ $p 120 8 beta; done
Rscript scripts/outlook-calibrate.R cal3/ beta      # check coverage by starting class (rewrites the spread table)
```

## Figures

`stage_viz()` draws one seasonal SWE plot per station and flavor: the water year's normal
classes in the USDM drought (D4–D0) and pluvial (W0–W4) percentiles, the median dashed,
this year's SWE, and the outlook's likely range (10th–90th percentile of the smoothed
outlook, the same on every flavor's plot; gray with dotted edges, keyed with the current
conditions). For a date without a stored outlook (a
backfill), the range is computed from the observed table. It is `plot_snodas()` from mco-snodas with SWE in inches
(`R/plot_snotel.R`). The frame, legend, logos and fixed 256-colour palette are mco-snodas's
(`R/plot.R`, `plot_palette.png`), so the two products' plots match. A station's three
flavors share their SWE axis. Files are 1500 × 1000 px, 8-bit PNGs.
`scripts/check-plot-palette.R` measures how well the shared palette fits station plots
(mean error 0.16 of 255 against 0.13 for a palette fitted to station plots alone, on
2026-10-29); the palette is only ever rebuilt upstream.

The daily run plots the `snodas` period. To plot other periods or past dates, use
`viz.R` (or `scripts/backfill-figures.sh` on Fargate), not `mco-snotel.R`:

```bash
VIZ_DATES=2026-10-01:2026-10-30 VIZ_PERIODS=snodas,30yr Rscript viz.R
VIZ_PERIODS=30yr,por ./scripts/backfill-figures.sh 2026-10-01 2026-10-30 5 4
./scripts/backfill-figures.sh 2024-10-01 2026-10-29 auto 3
```

Backfill tasks run at 16 vCPU (the Fargate maximum) and plot 16 stations at once,
because the shared subnets have only a few free addresses and each task takes one.
A date takes about 12 minutes. `auto` splits the dates evenly across the tasks, so every
task starts at once and runs to the end even if the machine that launched it sleeps.

## Vendored code

The distribution code and the plot helpers are copied from mco-snodas at commit `62fe19a`,
unchanged:

| Here | mco-snodas |
|------|------------|
| `src/*.cpp`, `src/ecdf_impl.h` | the same |
| `R/zig_spline_normals.R` | `R/calc_snodas_zig_spline_normals.R` |
| `R/plot.R` | `R/plot.R`, through `snodas_conditions()` |
| `R/utils.R` | `R/utils.R`, from `SNODAS_QUANTILES` on |
| `R/s3.R`, `R/s3_sync.R` | `R/s3.R`; `s3_list_prefix()`, `aws_s3()` from `R/pipeline_sync.R`; `s3_exists()` from `R/normals_annual.R` |
| `scripts/test_distributions.R` | the same |
| `mco_logo.png`, `umt_logo.png`, `plot_palette.png` | the same |

Do not edit them here. Change mco-snodas, then copy the files back with their headers and
update the commit in the headers, in `scripts/check-vendored.sh` and in the table above.
`scripts/check-vendored.sh [path/to/mco-snodas]` fails if any file differs from its source
at the recorded commit.

## Repository

```
mco-snotel.R           daily pipeline
normals-annual.R       yearly normals build
viz.R                  plots only, for past dates or other periods
R/
  pipeline_setup.R     configuration, S3 keys; sources R/ and compiles src/
  awdb.R               AWDB REST API: stations and daily data, batched
  archive.R            the archive: full and water-year refetches, state, SWE
  normals.R            periods, reference records, station normals and percentiles
  outlook.R            the outlook: persistence lengths and daily quantiles
  stages.R             stage functions
  plot_snotel.R        the station plot
  plot.R, utils.R, s3.R, s3_sync.R, zig_spline_normals.R   vendored from mco-snodas
src/                   Rcpp, vendored from mco-snodas
config/                outlook_alpha.csv, the outlook's calibrated persistence shape
scripts/               test_distributions.R, test_stations.R, check-vendored.sh,
                       check-plot-palette.R, backfill-figures.sh,
                       publish-bucket-readmes.sh, run_local.sh, ecr-push.sh,
                       outlook-hindcast.R, outlook-calibrate.R
s3-docs/               README.md for each bucket directory
terraform/             AWS infrastructure
.github/workflows/     image build (docker-publish.yml)
```

## Running

Requirements: R 4.5 with the packages in the `Dockerfile`, and the AWS CLI with an `mco`
profile (`aws sso login --profile mco`).

```bash
Rscript mco-snotel.R                       # daily run
Rscript normals-annual.R                   # yearly build (refetches the whole archive)
WATER_YEAR=2027 SKIP_REFRESH=true Rscript normals-annual.R
Rscript scripts/test_distributions.R       # ECDF and ZIG tests (vendored)
Rscript scripts/test_stations.R            # station normals on live AWDB data
./scripts/check-vendored.sh                # vendored code still matches mco-snodas
./scripts/run_local.sh                     # daily run in Docker, refreshing SSO credentials
docker compose run --rm mco-snotel normals-annual.R
```

The plotting workers fork, which crashes on macOS once Arrow or the graphics device has
started. Run with `CORES=1` outside Docker on a Mac.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SNOTEL_DATE` | newest date with SWE | Date to plot and publish. |
| `CALC_FIGURES` | `FALSE` | Plot. The ECS task definition sets `TRUE`. |
| `WATER_YEAR` | current | `normals-annual.R`: water year to build. |
| `SKIP_REFRESH` | `FALSE` | `normals-annual.R`: build from the archive as it is. |
| `PERIODS` | all | `normals-annual.R`: periods to build, comma-separated. |
| `VIZ_DATES` | — | `viz.R`: dates and `START:END` ranges, comma-separated. |
| `VIZ_PERIODS` | `snodas` | `viz.R`: periods to plot. |
| `VIZ_STATIONS` | all with SWE | `viz.R`: triplets to plot (for tests). |
| `AWDB_CONCURRENCY` | `4` | Parallel AWDB requests. |
| `S3_BUCKET` | `mco-snotel` | Bucket. |
| `WORK_DIR` | `s3` | Local working directory. |
| `KEEP_LOCAL` | `TRUE` | Keep local copies (`FALSE` in ECS). |
| `CORES` | `1` | Plotting and fitting workers. |

The first deploy needs the whole record and the current water year's normals before the
daily run can work: run `normals-annual.R` once (it refetches the archive), then
`scripts/backfill-figures.sh` from Oct 1 to the day before.

## Infrastructure

Terraform in `terraform/` (state in S3): ECR repository, ECS cluster and task (4 vCPU,
16 GB), the daily and yearly EventBridge schedules (the yearly one runs the same task with
`normals-annual.R`), the public bucket (public list, CORS for `data2.climate.umt.edu`),
CloudWatch logs.

The bucket is served at `data2.climate.umt.edu/snotel/` by the shared data CDN, defined in
[mco-data-cdn](https://github.com/mt-climate-office/mco-data-cdn) (`origin_buckets` in its
`terraform.tfvars`).

The image is built and pushed to ECR by `.github/workflows/docker-publish.yml` on pushes
to `main`, or by `scripts/ecr-push.sh`. The base image is pinned by digest, and its CRAN
snapshot (2026-04-23) pins every R package.

## Data source

USDA Natural Resources Conservation Service, National Water and Climate Center. SNOTEL
daily data, from the Air and Water Database REST API,
<https://wcc.sc.egov.usda.gov/awdbRestApi/>.

Hosking, J. R. M. (1990). L-moments: analysis and estimation of distributions using linear
combinations of order statistics. *Journal of the Royal Statistical Society B* 52:105–124.
