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
  4  per-station seasonal SWE plots (snodas period)                 plots/{date}/
  5  copy the current tables to latest/, write manifest             latest/

Yearly, Oct 1 at 2 PM (normals-annual.R, the same task)
  refetch every station's whole record from AWDB
  freeze the record before the new water year                       normals/reference/wy{YYYY}.parquet
  build ECDF, ZIG and ZIG-smooth normals for every station, day
  and period of the new water year                                  normals/{period}/wy{YYYY}/
```

Data come from the NRCS [AWDB REST API](https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html)
in its stored units (inches, °F) with each value's QC and QA flags. AWDB leaves out values
NRCS has marked suspect, so the archive never holds them, and a value NRCS flags later
drops out at the next refetch that covers its date.

## Normals

The method is mco-snodas's, unchanged. Its code is the
[`normals`](https://github.com/mt-climate-office/normals) R package, shared with mco-snodas
(see [Normals package](#normals-package) below). A station's daily SWE series takes the place
of a watershed's.

**Water year.** Years run Oct 1–Sep 30 and are named for the year they end in (2027 is
2026-10-01 to 2027-09-30). Plot legends label it "WY"; code and file paths use
`normals::year_of(date, "wy")` and `wy2027/`.

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
`normals::NORMALS_QUANTILES`). `q0000` is 0; `q1000` is NA wherever SWE can be
positive.

## Figures

`stage_viz()` draws one seasonal SWE plot per station and flavor: the water year's normal
classes in the USDM drought (D4–D0) and pluvial (W0–W4) percentiles, the median dashed, and
this year's SWE. It is `plot_snodas()` from mco-snodas with SWE in inches
(`R/plot_snotel.R`). The frame, legend, logos and fixed 256-colour palette are the normals
package's `plot_*()` helpers, shared with mco-snodas, so the two products' plots match. A station's three
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

## Normals package

The distributions (ECDF, zero-inflated gamma, the smoothed fit), percentiles, calendar
helpers and the shared plot helpers, logos and palette are the
[`normals`](https://github.com/mt-climate-office/normals) package, installed in the image at
one commit (`NORMALS_SHA` in the `Dockerfile`). `R/normals.R` calls it with the arguments
that reproduce this pipeline's results (normals `docs/API.md`, sections 5 and 6.3) and maps
its names to the published ones (`ecdf` / `zig` / `zig_smooth`, `zig_shape`, `swe_ptile`, …).
`provenance.json` records the version as `normals_version`.

The image runs OpenBLAS single-threaded with a fixed kernel (`OPENBLAS_CORETYPE=Nehalem`),
so the smoothed fits do not depend on the host's CPU.

`R/s3.R` and `R/s3_sync.R` are copied from mco-snodas at `62fe19a`; the package does no
storage.

## Repository

```
mco-snotel.R           daily pipeline
normals-annual.R       yearly normals build
viz.R                  plots only, for past dates or other periods
R/
  pipeline_setup.R     configuration, S3 keys; sources R/, registers fonts
  awdb.R               AWDB REST API: stations and daily data, batched
  archive.R            the archive: full and water-year refetches, state, SWE
  normals.R            periods, reference records, station normals and percentiles
  stages.R             stage functions
  plot_snotel.R        the station plot
  s3.R, s3_sync.R      S3 helpers, copied from mco-snodas
scripts/               test_stations.R, check-plot-palette.R, backfill-figures.sh,
                       publish-bucket-readmes.sh, run_local.sh, ecr-push.sh
scripts/parity/        shadow runs: seed.sh, diff.R, check-identical.sh
s3-docs/               README.md for each bucket directory
terraform/             AWS infrastructure
.github/workflows/     image build (docker-publish.yml)
```

## Running

Requirements: R 4.5 with the packages in the `Dockerfile` (normals at `NORMALS_SHA`), and the AWS CLI with an `mco`
profile (`aws sso login --profile mco`).

```bash
Rscript mco-snotel.R                       # daily run
Rscript normals-annual.R                   # yearly build (refetches the whole archive)
WATER_YEAR=2027 SKIP_REFRESH=true Rscript normals-annual.R
Rscript scripts/test_stations.R            # station normals on live AWDB data
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
to `main`, or by `scripts/ecr-push.sh`, which prints the commit and digest. The base image
is pinned by digest, and its CRAN snapshot (2026-04-23) pins every R package.

Builds are tagged `sha-<short commit>` and never `latest`. Every task (daily and annual)
runs the digest in `terraform/image.auto.tfvars`, so pushing an image deploys nothing. To
deploy, tag the image `prod-<yyyymmdd>` (the ECR lifecycle policy never expires `prod-*`),
set `image_digest` to its digest, and `terraform apply`.

## Shadow runs

A shadow run shows that a change leaves the outputs as they are before it reaches
production: the pipeline runs against the private bucket `mco-snotel-test`, seeded from
production, and `scripts/parity/diff.R` compares its outputs with production's.
`terraform/shadow.tf` defines:

- the test bucket: private, versioned, noncurrent versions expire after 30 days;
- two roles with the same S3 permissions: read production, read and write the test bucket,
  and an explicit deny on writes and deletes in production. `mco-snotel-shadow-task` is the
  shadow task's role; `mco-shadow-snotel` is for local work, assumed from the SSO admin role;
- the task definition `mco-snotel-shadow`: the daily task on Fargate Spot with
  `S3_BUCKET=mco-snotel-test`, running the image `shadow_image_digest` (production's when unset);
- the schedule `mco-snotel-shadow`, 13:00 America/Denver, created disabled.

The local profile, in `~/.aws/config` (`role_arn` is the `shadow_local_role_arn` output):

```ini
[profile mco-shadow-snotel]
source_profile = mco
role_arn       = arn:aws:iam::202533506375:role/mco-shadow-snotel
region         = us-west-2
```

```bash
scripts/parity/seed.sh --dry-run 2026-10-30   # the objects a run for the date reads, and their size
scripts/parity/seed.sh --wipe 2026-10-30      # copy them (server-side); prints the time for --newer-than
aws ecs run-task --profile mco --cluster mco-snotel --task-definition mco-snotel-shadow \
  --capacity-provider-strategy capacityProvider=FARGATE_SPOT,weight=1 \
  --network-configuration 'awsvpcConfiguration={subnets=[subnet-0b687da7eda8bef8f,subnet-09a22817da9991c3c],securityGroups=[sg-0939029739ce88636],assignPublicIp=ENABLED}' \
  --overrides '{"containerOverrides":[{"name":"snotel-pipeline","environment":[{"name":"SNOTEL_DATE","value":"2026-10-30"}]}]}'
scripts/parity/diff.R --ref s3://mco-snotel/<prefix> --cand s3://mco-snotel-test/<prefix> --newer-than <seed time>
scripts/parity/check-identical.sh             # scripts/parity/ matches the other repository's
```

`seed.sh` (its header lists every key) copies the archive, the water year's frozen
normals and reference record, and the date's plot index. The run refetches the water year
from AWDB itself, so compare it with a production run of the same day.
`diff.R` compares COGs (georeferencing, types, nodata, bands and overviews; integer
pixels exactly, floating-point pixels to 1e-6 relative), Parquet (schema, row order and keys;
floating-point columns to 1e-9 relative, exactly where rounded), JSON (ignoring `updated`, `created`,
`built_at`, `normals_version`, `pipeline`) and PNG (decoded RGBA), reports missing and extra
keys, and exits 0 only if everything passes. `--newer-than` fails any candidate object the run
did not rewrite, so point it at outputs, not at the seeded inputs.

`SNOTEL_DATE` sets the date plotted and published; the water year refetched is always the
current one.

The scripts in `scripts/parity/` are kept byte-identical in mco-snodas and mco-snotel.

## Data source

USDA Natural Resources Conservation Service, National Water and Climate Center. SNOTEL
daily data, from the Air and Water Database REST API,
<https://wcc.sc.egov.usda.gov/awdbRestApi/>.

Hosking, J. R. M. (1990). L-moments: analysis and estimation of distributions using linear
combinations of order statistics. *Journal of the Royal Statistical Society B* 52:105–124.
